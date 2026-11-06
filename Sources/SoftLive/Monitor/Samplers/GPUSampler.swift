import Foundation
import IOKit

final class GPUSampler {
    private var service: io_service_t = 0

    init() {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
    }

    isolated deinit {
        if service != 0 {
            IOObjectRelease(service)
        }
    }

    func sampleUtilization() -> Double {
        guard service != 0,
              let prop = IORegistryEntryCreateCFProperty(
                  service,
                  "PerformanceStatistics" as CFString,
                  kCFAllocatorDefault,
                  0
              )?.takeRetainedValue() as? NSDictionary,
              let util = prop["Device Utilization %"] as? Int
        else { return 0 }
        return min(max(Double(util) / 100.0, 0), 1)
    }
}
