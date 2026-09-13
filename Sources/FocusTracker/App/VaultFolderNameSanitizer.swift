import Foundation

/// Folder-name sanitization for first-run vault creation (issue #26): the
/// **house character policy of `VaultStore.slug(from:)` (issue #7)** reused
/// for the vault folder's own name, WITHOUT the parts that are
/// task-filename-specific — no `.md` suffix and no `untitled` fallback
/// (pinned: a name that sanitizes to empty is a typed error instead, with
/// the UI disabling Create on the same rule). Pure and deterministic.
///
/// The pinned policy:
/// - `/`, `:` and control characters (U+0000–U+001F, U+007F) → `-`.
/// - **Case- and space-preserving — no slug-casing**: the vault folder name
///   may contain spaces (`Focus Tracker` stays `Focus Tracker`).
/// - Trailing dots and spaces trimmed (macOS Finder-legal names).
public enum VaultFolderNameSanitizer {

    /// The typed sanitization failure (house style — typed outcomes over
    /// silent fallbacks): the raw name produced an empty folder name — e.g.
    /// an empty string, or only dots/spaces (which the trailing trim
    /// removes). Note `/`/`:`/control characters become `-` and therefore
    /// do NOT empty the name (`"///"` sanitizes to `"---"`, a legal folder
    /// name — deliberately unlike the slug rule's `untitled` fallback).
    public enum SanitizationError: Error, Equatable, Sendable {
        case emptyAfterSanitize
    }

    /// Applies the pinned policy to `rawName`.
    ///
    /// - Throws: `SanitizationError.emptyAfterSanitize` when nothing
    ///   remains after replacement and trimming.
    public static func sanitize(_ rawName: String) throws -> String {
        var sanitized = ""
        sanitized.reserveCapacity(rawName.count)
        for scalar in rawName.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar.value < 0x20 || scalar.value == 0x7F {
                sanitized.append("-")
            } else {
                sanitized.unicodeScalars.append(scalar)
            }
        }
        while let last = sanitized.last, last == "." || last == " " {
            sanitized.removeLast()
        }
        guard !sanitized.isEmpty else {
            throw SanitizationError.emptyAfterSanitize
        }
        return sanitized
    }
}
