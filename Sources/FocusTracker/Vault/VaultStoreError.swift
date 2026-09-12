import Foundation

/// Errors synthesized by `VaultStore` itself while building the inventory
/// (issue #6, PRD §18). None of these abort a load: each one is reported
/// inside a `VaultStore.LoadWarning` (as `underlyingError`) and the rest of
/// the vault still loads.
public enum VaultStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Two task files declare the same top-level task ID. `firstFile` names the
    /// filename-sorted winner; the skipped file is named by the warning's
    /// `LoadWarning.fileName`.
    case duplicateTaskID(id: UUID, firstFile: String)
    /// A subdirectory inside `Tasks/` was found and ignored. The vault schema
    /// is flat (one Markdown file per top-level task, nested subtasks live
    /// inside the parent file), so nothing inside the directory was read.
    case subdirectoryIgnored(String)

    public var description: String {
        switch self {
        case .duplicateTaskID(let id, let firstFile):
            return "duplicate task ID \(id.uuidString); filename-sorted winner: \(firstFile)"
        case .subdirectoryIgnored(let name):
            return "subdirectory inside Tasks/ ignored: \(name)"
        }
    }
}
