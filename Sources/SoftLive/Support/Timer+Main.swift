import Foundation

extension Timer {
    /// Schedules a main-thread timer in `.common` run-loop mode, so it keeps firing while a menu is open.
    /// Sets a tolerance for battery-friendly kernel timer coalescing.
    @discardableResult
    static func onMain(
        after interval: TimeInterval,
        repeats: Bool = false,
        tolerance: TimeInterval = 0.1,
        _ action: @escaping @MainActor () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in MainActor.assumeIsolated(action) }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
