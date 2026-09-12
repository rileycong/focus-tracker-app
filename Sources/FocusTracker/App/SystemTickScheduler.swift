import Foundation

/// The production `ActiveSessionTickScheduler` (issue #14's wiring of the #13
/// seam): a `DispatchSourceTimer` on a private serial queue, so autosave
/// ticks (which perform file I/O) never run on the main thread and never
/// block the UI.
///
/// Contract honored (documented on the protocol): `schedule` replaces any
/// previously scheduled, still-pending tick (the coordinator re-arms after
/// every save), and the timer never calls back synchronously from inside
/// `schedule` — the source fires asynchronously on its own queue.
///
/// Lock-guarded for `Sendable`: `schedule` may be called from within the
/// coordinator's lock scope (a different lock — never nested) while a pending
/// source exists. Tests never use this type; they inject a manual scheduler
/// and fire ticks themselves (issue #13 criterion 7).
public final class SystemTickScheduler: ActiveSessionTickScheduler, @unchecked Sendable {

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "com.chauanhcong.FocusTracker.autosave", qos: .utility)
    private var source: DispatchSourceTimer?

    public init() {}

    public func schedule(after interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) {
        cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval)
        source.setEventHandler(handler: tick)
        source.resume()
        lock.withLock { self.source = source }
    }

    public func cancel() {
        lock.withLock {
            source?.cancel()
            source = nil
        }
    }
}
