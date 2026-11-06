import Darwin
import Foundation

struct NetworkCounters: Equatable, Sendable {
    var receivedBytes: UInt64 = 0
    var sentBytes: UInt64 = 0

    static func rates(
        from previous: NetworkCounters,
        to current: NetworkCounters,
        elapsedSeconds: Double
    ) -> (uploadBytesPerSec: UInt64, downloadBytesPerSec: UInt64) {
        guard elapsedSeconds > 0,
              current.receivedBytes >= previous.receivedBytes,
              current.sentBytes >= previous.sentBytes
        else { return (0, 0) }
        let downDelta = current.receivedBytes - previous.receivedBytes
        let upDelta = current.sentBytes - previous.sentBytes
        return (
            uploadBytesPerSec: UInt64((Double(upDelta) / elapsedSeconds).rounded()),
            downloadBytesPerSec: UInt64((Double(downDelta) / elapsedSeconds).rounded())
        )
    }
}

final class NetworkSampler {
    private var previousCounters: NetworkCounters?
    private var previousInstant: ContinuousClock.Instant?
    private var cachedRates: (uploadBytesPerSec: UInt64, downloadBytesPerSec: UInt64) = (0, 0)

    func sample(now: ContinuousClock.Instant = .now) -> (uploadBytesPerSec: UInt64, downloadBytesPerSec: UInt64) {
        let current = Self.readCounters()
        guard let prevCounters = previousCounters, let prevInstant = previousInstant else {
            previousCounters = current
            previousInstant = now
            return (0, 0)
        }
        let elapsed = prevInstant.duration(to: now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        guard seconds >= 0.25 else {
            return cachedRates
        }
        previousCounters = current
        previousInstant = now
        cachedRates = NetworkCounters.rates(from: prevCounters, to: current, elapsedSeconds: seconds)
        return cachedRates
    }

    static func isPhysicalInterfaceName(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip") || name.hasPrefix("bridge")
    }

    private static func readCounters() -> NetworkCounters {
        var firstAddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddr) == 0, let head = firstAddr else {
            return NetworkCounters()
        }
        defer { freeifaddrs(head) }

        var total = NetworkCounters()
        var seenInterfaces = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let addr = cursor {
            defer { cursor = addr.pointee.ifa_next }
            let flags = Int32(addr.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let sa = addr.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_LINK),
                  let data = addr.pointee.ifa_data
            else { continue }

            let name = String(cString: addr.pointee.ifa_name)
            guard isPhysicalInterfaceName(name), seenInterfaces.insert(name).inserted else { continue }

            let networkData = data.assumingMemoryBound(to: if_data.self).pointee
            total.receivedBytes &+= UInt64(networkData.ifi_ibytes)
            total.sentBytes &+= UInt64(networkData.ifi_obytes)
        }
        return total
    }
}
