import Foundation

extension Timer {
    /// Schedules a main-thread timer in `.common` run-loop mode, so it keeps firing while a menu is open.
    @MainActor
    @discardableResult
    static func onMain(after interval: TimeInterval, repeats: Bool = false, _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in MainActor.assumeIsolated(action) }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
