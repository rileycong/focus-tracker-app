import Foundation

/// Backing store for the collapsible section state of the Tasks view
/// (issue #15): whether each project/No Project section and status sub-group
/// is expanded. Chosen mechanism (documented per the issue): **`UserDefaults`**
/// — one boolean per stable collapse key (`TasksGrouping`'s keys), prefixed so
/// the value lives harmlessly inside the app's standard suite and persists
/// across relaunches. The store is injected everywhere (the seam
/// `UserDefaults` itself cannot offer), so tests use isolated suites and round
/// -trip the persistence by constructing a *new* store over the same suite —
/// the relaunch path.
@MainActor
public protocol CollapseStateStoring: AnyObject {
    /// Whether the section identified by `key` is expanded. A never-touched
    /// key is expanded (new sections start open).
    func isExpanded(forKey key: String) -> Bool
    /// Persists the expanded state for `key` immediately.
    func setExpanded(_ expanded: Bool, forKey key: String)
}

/// The production `UserDefaults`-backed store (see the protocol
/// documentation for the rationale and the test seam).
@MainActor
public final class UserDefaultsCollapseStateStore: CollapseStateStoring {

    private let defaults: UserDefaults
    private let keyPrefix: String

    /// - Parameters:
    ///   - defaults: The suite to persist into (production: `.standard`;
    ///     tests: an isolated injected suite).
    ///   - keyPrefix: Namespacing prefix for the stored booleans.
    public init(defaults: UserDefaults, keyPrefix: String = "tasks.collapse") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func isExpanded(forKey key: String) -> Bool {
        let storageKey = keyPrefix + "." + key
        // Distinguish "never stored" (→ expanded) from an explicit `false`.
        return defaults.object(forKey: storageKey) == nil
            ? true
            : defaults.bool(forKey: storageKey)
    }

    public func setExpanded(_ expanded: Bool, forKey key: String) {
        defaults.set(expanded, forKey: keyPrefix + "." + key)
    }
}
