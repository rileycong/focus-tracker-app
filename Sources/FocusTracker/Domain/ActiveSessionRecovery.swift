import Foundation

/// The pure recovery decision over an `ActiveSessionPersistence.load()`
/// outcome (issue #13 criterion 4). No I/O inside — the caller performs the
/// `load()` and feeds the `Result` in; what to *offer* the user (Resume vs
/// End-with-logging) and the rehydrate call itself are #14/#22's wiring.
///
/// Mapping (pinned):
/// - snapshot present → **resume** (rehydrate the engine to its exact state
///   via `FocusSessionEngine.restore(from:)`),
/// - `nil` → normal idle start,
/// - corrupt → the typed error is surfaced and the snapshot is treated as
///   absent (the corrupt file was already quarantined by the persistence
///   layer, per criterion 2 — the decision itself does no I/O).
public enum ActiveSessionRecovery {

    /// The three recovery outcomes. `Equatable` for exact-case test
    /// assertions, matching the house error/decision style.
    public enum Decision: Equatable, Sendable {
        /// A snapshot was loaded — rehydrate and resume.
        case resume(ActiveSessionSnapshot)
        /// No snapshot on disk — normal idle start.
        case idle
        /// The load failed. The snapshot is treated as absent. `path` is the
        /// quarantine path when the error is the persistence layer's typed
        /// `.corruptSnapshot` (nil for any other I/O failure, which is still
        /// surfaced here rather than silently swallowed).
        case corruptSnapshot(path: String?)
    }

    /// Pure decision over the `load()` outcome — no filesystem, no clock.
    public static func decide(
        _ outcome: Result<ActiveSessionSnapshot?, Error>
    ) -> Decision {
        switch outcome {
        case .success(.some(let snapshot)):
            return .resume(snapshot)
        case .success(.none):
            return .idle
        case .failure(let error):
            if case ActiveSessionPersistenceError.corruptSnapshot(let path) = error {
                return .corruptSnapshot(path: path)
            }
            return .corruptSnapshot(path: nil)
        }
    }
}
