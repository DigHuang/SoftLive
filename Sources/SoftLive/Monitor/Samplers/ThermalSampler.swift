import Darwin
import Foundation

final class ThermalSampler {
    private typealias CreateClientFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatValueFn = @convention(c) (CFTypeRef, Int32) -> Double

    private static let temperatureEventType: Int64 = 15
    private static let temperatureLevelField: Int32 = 15 << 16
    private static let sampleStride = 3

    private struct NamedSensor {
        let name: String
        let label: String
        let order: Int
        let service: CFTypeRef
    }

    private let client: CFTypeRef?
    private let copyEvent: CopyEventFn?
    private let getFloatValue: GetFloatValueFn?
    private let smcSampler = SMCSampler()
    private var primarySensor: CFTypeRef?
    private var dieSensors: [NamedSensor] = []
    private var nandSensor: CFTypeRef?
    private var batterySensor: CFTypeRef?
    private var boardSensors: [CFTypeRef] = []
    private var cachedTemperature: Double?
    private var cachedDetails = ThermalDetails()
    private var tickCount = 0

    init() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let createSym = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let matchSym = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let servicesSym = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let propSym = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let eventSym = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let floatSym = dlsym(handle, "IOHIDEventGetFloatValue")
        else {
            client = nil
            copyEvent = nil
            getFloatValue = nil
            return
        }

        let create = unsafeBitCast(createSym, to: CreateClientFn.self)
        let setMatching = unsafeBitCast(matchSym, to: SetMatchingFn.self)
        let copyServices = unsafeBitCast(servicesSym, to: CopyServicesFn.self)
        let copyProperty = unsafeBitCast(propSym, to: CopyPropertyFn.self)
        let copyEventFn = unsafeBitCast(eventSym, to: CopyEventFn.self)
        let getFloatFn = unsafeBitCast(floatSym, to: GetFloatValueFn.self)

        self.copyEvent = copyEventFn
        self.getFloatValue = getFloatFn

        guard let created = create(kCFAllocatorDefault)?.takeRetainedValue() else {
            client = nil
            return
        }
        client = created

        let matching: [String: Int] = [
            "PrimaryUsagePage": 0xFF00,
            "PrimaryUsage": 0x0005,
        ]
        setMatching(created, matching as CFDictionary)

        guard let services = copyServices(created)?.takeRetainedValue() as? [AnyObject] else { return }
        var seenDieNames = Set<String>()
        for service in services {
            let serviceRef = service as CFTypeRef
            guard let nameRef = copyProperty(serviceRef, "Product" as CFString)?.takeRetainedValue(),
                  let name = nameRef as? String,
                  !name.contains("tcal")
            else { continue }

            if Self.isCoreSensorName(name) {
                guard readCelsius(from: serviceRef) != nil else { continue }
                if primarySensor == nil {
                    primarySensor = serviceRef
                }
                if name.hasPrefix("PMU tdie"), seenDieNames.insert(name).inserted {
                    let digits = Int(name.dropFirst("PMU tdie".count)) ?? 99
                    dieSensors.append(
                        NamedSensor(
                            name: name,
                            label: "核心 #\(digits)",
                            order: digits,
                            service: serviceRef
                        )
                    )
                }
            } else if name.hasPrefix("NAND"), nandSensor == nil, readCelsius(from: serviceRef) != nil {
                nandSensor = serviceRef
            } else if name == "gas gauge battery", batterySensor == nil, readCelsius(from: serviceRef) != nil {
                batterySensor = serviceRef
            } else if name.contains("tdev"), readCelsius(from: serviceRef) != nil {
                boardSensors.append(serviceRef)
            }
        }
        dieSensors.sort { $0.order < $1.order }
        if let firstDie = dieSensors.first?.service {
            primarySensor = firstDie
        }
    }

    func sample(includeDetails: Bool = false, advanceTick: Bool = true) -> (celsius: Double?, details: ThermalDetails) {
        if includeDetails {
            return sampleDetailed()
        }
        guard let primarySensor else { return (nil, cachedDetails) }
        if cachedTemperature == nil || (advanceTick && tickCount.isMultiple(of: Self.sampleStride)) {
            cachedTemperature = readCelsius(from: primarySensor)
        }
        if advanceTick {
            tickCount &+= 1
        }
        return (cachedTemperature, cachedDetails)
    }

    private func sampleDetailed() -> (celsius: Double?, details: ThermalDetails) {
        let dieValues = dieSensors.compactMap { readCelsius(from: $0.service) }
        let avgDie = dieValues.isEmpty
            ? primarySensor.flatMap(readCelsius(from:))
            : dieValues.reduce(0, +) / Double(dieValues.count)
        let maxDie = dieValues.max() ?? avgDie
        let minDie = dieValues.min() ?? avgDie

        let nand = nandSensor.flatMap(readCelsius(from:))
        let battery = batterySensor.flatMap(readCelsius(from:))
        let boardValues = boardSensors.compactMap(readCelsius(from:))
        let boardAvg = boardValues.isEmpty ? nil : boardValues.reduce(0, +) / Double(boardValues.count)
        let smc = smcSampler.sample()

        cachedTemperature = avgDie
        cachedDetails = ThermalDetails(
            maxDieCelsius: maxDie,
            minDieCelsius: minDie,
            nandCelsius: nand,
            batteryCelsius: battery,
            boardAverageCelsius: boardAvg,
            systemPowerWatts: smc.systemWatts,
            fanRPM: smc.fanRPM,
            fanMaxRPM: smc.fanMax
        )
        return (avgDie, cachedDetails)
    }

    private func readCelsius(from service: CFTypeRef) -> Double? {
        guard let copyEvent, let getFloatValue,
              let event = copyEvent(service, Self.temperatureEventType, 0, 0)?.takeRetainedValue()
        else { return nil }
        let celsius = getFloatValue(event, Self.temperatureLevelField)
        guard celsius >= 10, celsius <= 130 else { return nil }
        return celsius
    }

    static func isCoreSensorName(_ name: String) -> Bool {
        if name.contains("tcal") { return false }
        return name.hasPrefix("PMU tdie")
            || name.hasPrefix("PMU2 tdie")
            || name.hasPrefix("eACC MTR Temp Sensor")
            || name.hasPrefix("pACC MTR Temp Sensor")
    }
}
