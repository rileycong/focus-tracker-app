import Foundation

/// The settings layer for the user-configurable vault location (issue #14,
/// PRD §5.1 "vault anywhere, path configurable"): a thin wrapper over
/// `UserDefaults` storing exactly one value — the vault path string.
///
/// **Injected suite (pinned for testability, issue #14):** the suite name is
/// a required constructor parameter, so tests can use an isolated, disposable
/// `UserDefaults` suite; production passes `AppSettings.defaultSuiteName`.
/// Save→reload across *instances* is part of the contract: a relaunch (or a
/// freshly constructed wrapper over the same suite) reads the same path.
///
/// **The user-facing vault-path contract lives here (binding, issue #14):**
/// - The chosen vault path persists across app relaunches (stored in
///   `UserDefaults`).
/// - The path changes only via the in-app Settings picker; first launch with
///   no stored path shows the onboarding picker (`vaultPath == nil` is the
///   state that flow keys off). The picker UI itself is #15+ — this type
///   exposes exactly the get/set API that flow will call.
/// - If the stored vault folder becomes unavailable (moved/deleted), the
///   stored path is **retained** and a degraded state is surfaced (that
///   handling lives in `AppModel`); this type never clears the value on its
///   own — the choice is never silently cleared (PRD §18: no silent data
///   loss). Only an explicit `vaultPath = nil` removes the stored value.
public struct AppSettings {

    /// The `UserDefaults` key under which the vault path is stored.
    public static let vaultPathKey = "vaultPath"

    /// The suite name production uses (the app's bundle identifier). Tests
    /// inject their own unique suite name instead (pinned seam, issue #14).
    public static let defaultSuiteName = "com.chauanhcong.FocusTracker"

    /// Typed init failure (house style: typed outcomes over force-unwraps):
    /// `UserDefaults(suiteName:)` returns nil for an invalid suite name.
    public enum SettingsError: Error, Equatable {
        case suiteUnavailable(String)
    }

    private let defaults: UserDefaults

    /// Creates a settings wrapper over the given suite — the injected-suite
    /// seam that keeps tests isolated from real user preferences.
    public init(suiteName: String) throws {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SettingsError.suiteUnavailable(suiteName)
        }
        self.defaults = defaults
    }

    /// Creates a settings wrapper over an explicit `UserDefaults` instance —
    /// the fallback for the (practically unreachable) unavailable-suite case
    /// at app startup, and a convenience when a caller already holds one.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The configured vault path, or `nil` when never configured (first
    /// launch). Setting a non-nil value persists it immediately (a new
    /// instance over the same suite reads the same value); setting `nil`
    /// removes the stored value. Nothing else ever clears it — see the type
    /// documentation for the retained-path contract.
    public var vaultPath: String? {
        get { defaults.string(forKey: Self.vaultPathKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.vaultPathKey)
            } else {
                defaults.removeObject(forKey: Self.vaultPathKey)
            }
        }
    }
}
