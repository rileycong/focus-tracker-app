import Foundation

/// Read side of the vault (issue #6, PRD §5.1–§5.5, §18): scans `Tasks/` inside
/// a user-configurable vault location, parses every task Markdown file through
/// the #4 frontmatter codec (`FrontmatterCodec.parseTask(_:)`), and exposes the
/// in-memory inventory with lookups by stable ID.
///
/// **Concurrency shape (engineer's choice, documented):** `VaultStore` is an
/// *actor*. `load()` always re-reads from disk (no cache) and every member —
/// inventory accessors and `lookup(_:)` included — is actor-isolated, so
/// callers simply `await`. The store is therefore safe to share across
/// isolation domains under Swift 6 strict concurrency and cannot data-race.
/// (The alternative — an immutable struct snapshot returned by an async free
/// function — was rejected because the store must also expose the *last*
/// load's warnings and state; the actor keeps that mutable state internal and
/// serialized.)
///
/// **Path type (engineer's choice, documented):** the vault location is a
/// `URL`, Foundation's canonical file reference, so no string↔URL conversion
/// is needed at call sites (`vaultURL`).
///
/// **Layout rules (documented):**
/// - Only entries directly inside `Tasks/` are considered. The `.md` extension
///   is matched case-insensitively (APFS is commonly case-insensitive, and a
///   silently ignored `TASK.MD` would be silent data loss, PRD §18).
/// - **Subdirectories inside `Tasks/` are ignored, with a non-fatal warning**
///   (`VaultStoreError.subdirectoryIgnored`). The schema is flat — one Markdown
///   file per top-level task, nested subtasks inside the parent file — so
///   recursion has no defined meaning; stray directories are surfaced instead
///   of silently dropped. Non-Markdown files (and dotfiles such as `.DS_Store`)
///   are ignored silently.
/// - Files are processed in filename-sorted order (Swift `String` `<` on the
///   last path component), so the task list is deterministic for identical
///   vault contents.
///
/// **Duplicates (documented):** when two files declare the same top-level task
/// ID, the first file in the filename-sorted processing order wins and the
/// later one is skipped with a warning naming both files
/// (`VaultStoreError.duplicateTaskID`) — no silent data acceptance (PRD §18).
/// Subtask IDs are not deduplicated; `lookup(_:)` returns the first match in
/// the same deterministic order.
///
/// **Failure handling (PRD §18: "no silent data loss", "graceful handling if
/// the vault is temporarily unavailable"):** a file that cannot be read or
/// parsed is skipped and reported as a `LoadWarning` (filename + underlying
/// error) without failing the load; a missing vault or missing `Tasks/`
/// directory yields a typed `LoadState` (`.vaultMissing` / `.tasksDirectoryMissing`)
/// and an empty inventory — never a crash. Non-loaded states reset the
/// in-memory inventory to empty (no stale cache); the typed state tells the
/// caller why.
public actor VaultStore {
    /// A non-fatal problem with one vault entry, produced by the last load.
    public struct LoadWarning: Sendable, CustomStringConvertible {
        /// The file name (or directory name) the warning is about.
        public let fileName: String
        /// The error that caused the entry to be skipped: a codec error
        /// (`FrontmatterError`, or `TaskItem.ValidationError` from the model's
        /// throwing initializer), a file-access error, or a `VaultStoreError`.
        public let underlyingError: any Error

        public init(fileName: String, underlyingError: any Error) {
            self.fileName = fileName
            self.underlyingError = underlyingError
        }

        public var description: String {
            "\"\(fileName)\" skipped: \(underlyingError)"
        }
    }

    /// The inventory built by one successful load.
    public struct Inventory: Sendable {
        /// All tasks that loaded, in filename-sorted order.
        public let tasks: [TaskItem]
        /// Warnings for entries skipped during this load, in processing order.
        public let warnings: [LoadWarning]

        public init(tasks: [TaskItem], warnings: [LoadWarning]) {
            self.tasks = tasks
            self.warnings = warnings
        }
    }

    /// The typed outcome of a load — the three states are distinguishable by
    /// pattern matching.
    public enum LoadState: Sendable {
        /// The vault and its `Tasks/` directory exist. The inventory may still
        /// be empty (empty-but-valid vault) and may carry warnings (skipped
        /// files).
        case loaded(Inventory)
        /// The vault path does not exist, or exists but is not a directory.
        case vaultMissing(path: URL)
        /// The vault path exists but `Tasks/` is missing or not a directory.
        case tasksDirectoryMissing(path: URL)
    }

    /// The typed result of a lookup by ID. `.notFound` is the typed
    /// "absent ID" outcome — a lookup never crashes and never returns a
    /// half-built task.
    public enum LookupResult: Sendable {
        /// The ID belongs to a top-level task.
        case task(TaskItem)
        /// The ID belongs to a subtask found anywhere in the parent task's
        /// recursive subtask tree; the second value is that parent task.
        case subtask(SubtaskItem, in: TaskItem)
        case notFound
    }

    /// The configured vault location.
    public let vaultURL: URL

    /// The tasks from the last successful load, in filename-sorted order.
    /// Empty before the first load, or after a load that found the vault or
    /// `Tasks/` missing.
    public private(set) var tasks: [TaskItem] = []
    /// Warnings produced by the last load; each reload replaces the previous
    /// set. Missing-vault states produce an empty set.
    public private(set) var warnings: [LoadWarning] = []
    /// The typed outcome of the last load, or nil before the first load.
    public private(set) var lastLoadState: LoadState?

    /// The number of tasks from the last successful load.
    public var taskCount: Int { tasks.count }

    /// - Parameter vaultURL: The user-configurable vault location (see the
    ///   type-level doc comment for why this is a `URL`).
    public init(vaultURL: URL) {
        self.vaultURL = vaultURL
    }

    /// Re-reads the vault from disk and replaces the in-memory inventory.
    ///
    /// Always performs a fresh scan — nothing is cached between calls — so
    /// external changes made to the vault between loads are picked up, and
    /// each call's warnings replace the previous load's warnings.
    ///
    /// - Returns: The typed `LoadState` of this load.
    @discardableResult
    public func load() -> LoadState {
        var isDirectory: ObjCBool = false
        let vaultPath = vaultURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: vaultPath, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return finish(.vaultMissing(path: vaultURL))
        }

        let tasksDirectory = vaultURL.appendingPathComponent("Tasks", isDirectory: true)
        let tasksPath = tasksDirectory.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: tasksPath, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return finish(.tasksDirectoryMissing(path: vaultURL))
        }

        return finish(.loaded(readInventory(from: tasksDirectory)))
    }

    /// Looks up a task or nested subtask by stable ID (PRD §18: reference by
    /// ID, not title). Walks every loaded task's recursive subtask tree at any
    /// depth; unknown IDs yield `.notFound`.
    public func lookup(_ id: UUID) -> LookupResult {
        for task in tasks {
            if task.id == id { return .task(task) }
            if let chain = task.chain(to: id), let target = chain.last {
                return .subtask(target, in: task)
            }
        }
        return .notFound
    }

    // MARK: - Loading internals

    private func finish(_ state: LoadState) -> LoadState {
        lastLoadState = state
        if case .loaded(let inventory) = state {
            tasks = inventory.tasks
            warnings = inventory.warnings
        } else {
            tasks = []
            warnings = []
        }
        return state
    }

    private func readInventory(from tasksDirectory: URL) -> Inventory {
        let entries: [URL]
        do {
            entries = try FileManager.default
                .contentsOfDirectory(
                    at: tasksDirectory, includingPropertiesForKeys: [.isDirectoryKey])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            // `Tasks/` exists but cannot be listed (e.g. no read permission):
            // degrade to an empty inventory plus a warning instead of crashing.
            return Inventory(
                tasks: [],
                warnings: [
                    LoadWarning(
                        fileName: tasksDirectory.lastPathComponent,
                        underlyingError: error)
                ])
        }

        var tasks: [TaskItem] = []
        var warnings: [LoadWarning] = []
        var firstFileByTaskID: [UUID: String] = [:]

        for entry in entries {
            let fileName = entry.lastPathComponent
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(
                atPath: entry.path(percentEncoded: false), isDirectory: &isDirectory)
            if isDirectory.boolValue {
                warnings.append(
                    LoadWarning(
                        fileName: fileName,
                        underlyingError: VaultStoreError.subdirectoryIgnored(fileName)))
                continue
            }
            guard entry.pathExtension.lowercased() == "md" else { continue }

            let task: TaskItem
            do {
                let text = try String(contentsOf: entry, encoding: .utf8)
                task = try FrontmatterCodec.parseTask(text)
            } catch {
                warnings.append(
                    LoadWarning(fileName: fileName, underlyingError: error))
                continue
            }

            if let firstFile = firstFileByTaskID[task.id] {
                warnings.append(
                    LoadWarning(
                        fileName: fileName,
                        underlyingError: VaultStoreError.duplicateTaskID(
                            id: task.id, firstFile: firstFile)))
                continue
            }
            firstFileByTaskID[task.id] = fileName
            tasks.append(task)
        }

        return Inventory(tasks: tasks, warnings: warnings)
    }
}
