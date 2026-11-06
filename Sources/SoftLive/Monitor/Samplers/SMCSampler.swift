import Foundation
import IOKit

final class SMCSampler {
    private struct SMCKeyData {
        var key: UInt32 = 0
        var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var pLimitData: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var keyInfoDataSize: UInt32 = 0
        var keyInfoDataType: UInt32 = 0
        var keyInfoDataAttributes: UInt8 = 0
        var keyInfoPad: (UInt8, UInt8, UInt8) = (0, 0, 0)
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var pad2: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    private var connection: io_connect_t = 0
    private var fanMaxRPM: Int?

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if service != 0 {
            _ = IOServiceOpen(service, mach_task_self_, 0, &connection)
            IOObjectRelease(service)
        }
        fanMaxRPM = readFloat("F0Mx").map { Int($0.rounded()) }
    }

    isolated deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func sample() -> (systemWatts: Double?, fanRPM: Int?, fanMax: Int?) {
        guard connection != 0 else { return (nil, nil, nil) }
        let sysW = readFloat("PSTR").map { Double($0) }
        let rpm = readFloat("F0Ac").map { max(0, Int($0.rounded())) }
        return (sysW, rpm, fanMaxRPM)
    }

    private func readFloat(_ key: String) -> Float? {
        guard connection != 0 else { return nil }
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
        input.data8 = 9 // kSMCGetKeyInfo
        var outSize = MemoryLayout<SMCKeyData>.size
        guard IOConnectCallStructMethod(
            connection, 2, &input, MemoryLayout<SMCKeyData>.size, &output, &outSize
        ) == KERN_SUCCESS, output.keyInfoDataSize == 4 else {
            return nil
        }
        input.keyInfoDataSize = 4
        input.data8 = 5 // kSMCReadKey
        guard IOConnectCallStructMethod(
            connection, 2, &input, MemoryLayout<SMCKeyData>.size, &output, &outSize
        ) == KERN_SUCCESS else {
            return nil
        }
        return withUnsafeBytes(of: &output.bytes) { $0.load(as: Float.self) }
    }
}
