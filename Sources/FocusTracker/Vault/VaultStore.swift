import Foundation

/// The vault store (issues #6 + #7, PRD §5.1–§5.5, §6.5, §18): one actor owning
/// both sides of the one-Markdown-file-per-top-level-task store in `Tasks/`.
///
/// **Read side (#6):** `load()` scans `Tasks/`, parses every task Markdown
/// file through the #4 frontmatter codec (`FrontmatterCodec.parseTask(_:)`),
/// and exposes the in-memory inventory with lookups by stable ID.
///
/// **Write side (#7):** `create(_:)`, `update(_:)`, `rename(_:to:)`,
/// `delete(_:)` and the `setStatus(_:to:)` write-through convenience. All
/// writes resolve their target file through the filename↔ID mapping built at
/// load — never by re-deriving a filename from a title — and every write goes
/// through the #5 `AtomicFileWriter` (atomic write / move / delete). After
/// every successful write the in-memory inventory (`tasks`, `taskCount`,
/// `lookup(_:)`) matches disk with no reload needed; `lastLoadState` and
/// `warnings` continue to describe the **last load** (they are only replaced
/// by `load()` — documented on each operation).
///
/// **Subtask writes (#8):** `addSubtask(parentID:subtask:toParentSubtaskID:)`,
/// `updateSubtask(parentID:subtaskID:modified:)`,
/// `deleteSubtask(parentID:subtaskID:)`,
/// `reorderSubtasks(parentID:parentSubtaskID:siblingIDsInNewOrder:)` and the
/// `setStatus(parentID:subtaskID:to:)` convenience address subtasks as
/// `(parent task ID, subtask ID)` paths into the parent task's recursive
/// `SubtaskItem` tree (unbounded nesting — no depth limits). Every operation
/// shares one path: resolve the parent from the inventory, apply a **pure**
/// tree mutation (the `[SubtaskItem]` helpers below the actor), then rewrite
/// the whole parent file through the same #7 `update` mechanics. Subtasks
/// carry no project/categories of their own — they inherit from ancestors via
/// the #3 `effectiveProject(of:)`/`effectiveCategories(of:)` helpers
/// (consumed as-is, never written here). `lastLoadState`/`warnings` keep
/// describing the last load, same as all writes.
///
/// **Manual task ordering (#10):** `applyOrdering(groupUpdates:)` persists the
/// per-(project, status)-group manual ordering through the same #7 update path;
/// the pure display/renumbering rules live in `TaskOrdering`. The multi-file
/// batch is per-file atomic only — a mid-batch failure surfaces typed
/// `.orderingBatchIncomplete` naming completed vs. pending files; see the
/// method's documentation.
///
/// **Write-side internal state (rebuilt at every load, maintained by every
/// write):**
/// - `fileNameByTaskID` — the filename↔ID mapping; the #6 filename-sorted
///   duplicate-ID winner rule decides which file maps to an ID.
/// - `recordedBytesByTaskID` — each loaded file's exact bytes, the record the
///   reload-before-write staleness guard byte-compares against (pinned
///   decision: content, not mtime — mtime alone is noisy for same-byte
///   rewrites and weaker with coarse timestamps).
/// - `bodyByTaskID` — each file's Markdown body (everything after the closing
///   `---`), recorded at load and re-attached byte-for-byte on writes; bodies
///   are opaque and never re-derived (PRD §18: nothing silently lost).
///
/// Writes do not require a prior successful `load()`: they operate on top of
/// the last load's mapping (empty when the vault or `Tasks/` was missing), and
/// a missing vault/`Tasks/` surfaces the #5 typed errors wrapped in
/// `VaultStoreError.writeFailed` — never a crash, never a partial write.
///
/// **Concurrency shape (engineer's choice, documented):** `VaultStore` is an
/// *actor*. `load()` always re-reads from disk (no cache) and every member —
/// inventory accessors, `lookup(_:)` and every write operation included — is
/// actor-isolated, so callers simply `await`. The store is therefore safe to
/// share across isolation domains under Swift 6 strict concurrency and cannot
/// data-race; store-driven writers are serialized by the actor. (The
/// alternative — an immutable struct snapshot returned by an async free
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
///   vault contents. Successful writes preserve that order in the in-memory
///   inventory without a reload (create inserts at the sorted position,
///   rename repositions).
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
    /// `Tasks/` missing. Successful write operations keep this in sync with
    /// disk (create inserts, update replaces in place, rename repositions,
    /// delete removes) so no reload is needed after a write.
    public private(set) var tasks: [TaskItem] = []
    /// Warnings produced by the last load; each reload replaces the previous
    /// set. Missing-vault states produce an empty set. Write operations never
    /// touch this — it keeps describing the last load (documented).
    public private(set) var warnings: [LoadWarning] = []
    /// The typed outcome of the last load, or nil before the first load.
    /// Write operations never touch this — it keeps describing the last load
    /// (documented).
    public private(set) var lastLoadState: LoadState?

    /// The number of tasks from the last successful load (kept in sync by
    /// successful write operations — see `tasks`).
    public var taskCount: Int { tasks.count }

    /// The filename each loaded top-level task ID maps to, built at load (the
    /// filename-sorted duplicate-ID winner rule decides which file maps to an
    /// ID) and maintained by every write operation. All writes resolve their
    /// target file through this mapping — never by re-deriving a filename
    /// from a title (pinned, issue #7).
    private var fileNameByTaskID: [UUID: String] = [:]

    /// The exact bytes of each loaded task's file, recorded at load and
    /// replaced by the store's own payload after every successful write. The
    /// staleness guard byte-compares the file's current bytes against this
    /// record before any write (pinned decision, issue #7).
    private var recordedBytesByTaskID: [UUID: Data] = [:]

    /// The Markdown body of each loaded task's file (everything after the
    /// closing `---`, byte-for-byte), recorded at load and re-attached
    /// unchanged on update/rename; new files start with an empty body
    /// (pinned, issue #7: bodies are opaque and never re-derived).
    private var bodyByTaskID: [UUID: String] = [:]

    /// The file-system writer used for every write operation (consumed
    /// as-is from #5).
    private let fileWriter = AtomicFileWriter()

    /// Upper bound for the create-collision probe: the slug plus at most this
    /// many `-2`, `-3`, … suffixed candidates are probed before the create
    /// fails with `.noFreeFileName` — no path retries indefinitely (same
    /// stance as #5). Far beyond any real vault.
    private static let maxSlugCollisionProbes = 1_000

    /// - Parameter vaultURL: The user-configurable vault location (see the
    ///   type-level doc comment for why this is a `URL`).
    public init(vaultURL: URL) {
        self.vaultURL = vaultURL
    }

    /// Re-reads the vault from disk and replaces the in-memory inventory.
    ///
    /// Always performs a fresh scan — nothing is cached between calls — so
    /// external changes made to the vault between loads are picked up, and
    /// each call's warnings replace the previous load's warnings. The
    /// write-side records (filename↔ID mapping, byte records, body records)
    /// are rebuilt from this scan, which is what makes `load()` the recovery
    /// path after a `.vaultChangedExternally` conflict.
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

    // MARK: - Writing (issue #7, PRD §5.3, §6.5, §18)

    /// Creates a new task file in `Tasks/`.
    ///
    /// The ID is the one the model carries — `TaskItem`'s initializer defaults
    /// it to a fresh `UUID()`, so a caller that did not set one gets a fresh
    /// ID; it is persisted in the file's frontmatter and the created task is
    /// returned so the caller knows the assigned ID.
    ///
    /// - The task is serialized through the #4 codec
    ///   (`FrontmatterCodec.encode(task:body:)`) with an **empty body** — new
    ///   files start with no Markdown body — and atomic-written via #5
    ///   `AtomicFileWriter.write`; the whole `TaskItem` including nested
    ///   subtasks persists through the codec.
    /// - The filename stem is the pinned slug rule (`slug(from:)`). If
    ///   `Tasks/<slug>.md` exists, `<slug>-2.md`, `<slug>-3.md`, … are probed
    ///   against the **real on-disk existence** (externally created files
    ///   count) until a free name is found — create is additive, so collisions
    ///   get a suffix, not an error (pinned decision, issue #7). The narrow
    ///   probe→write race window is accepted deliberately, same stance as #5's
    ///   fallback TOCTOU note; store-driven writers are serialized by the
    ///   actor.
    /// - Creating with an ID that is already loaded throws
    ///   `.duplicateTaskIDOnCreate` — duplicate IDs are silently dropped at
    ///   the next load, which is not acceptable (PRD §18).
    ///
    /// On success the filename↔ID mapping and the in-memory inventory are
    /// updated (filename-sorted order preserved), so `tasks`, `taskCount` and
    /// `lookup(_:)` match disk with no reload; `lastLoadState`/`warnings`
    /// continue to describe the last load. On any typed failure nothing is
    /// written and no state changes.
    @discardableResult
    public func create(_ task: TaskItem) throws -> TaskItem {
        guard fileNameByTaskID[task.id] == nil else {
            throw VaultStoreError.duplicateTaskIDOnCreate(task.id)
        }
        let fileName = try freeFileName(probing: Self.slug(from: task.title))
        let data = Data(FrontmatterCodec.encode(task: task, body: "").utf8)
        let target = tasksDirectory.appendingPathComponent(fileName, isDirectory: false)
        try performWriterOperation { try fileWriter.write(data, to: target) }

        fileNameByTaskID[task.id] = fileName
        recordedBytesByTaskID[task.id] = data
        bodyByTaskID[task.id] = ""
        insertSorted(task, fileName: fileName)
        return task
    }

    /// Persists the full task (frontmatter plus its nested subtask tree) to
    /// the file the task's ID currently maps to.
    ///
    /// - The target filename is resolved through the filename↔ID mapping built
    ///   at load — **never re-derived from the title** (pinned, issue #7).
    ///   Update deliberately keeps the existing filename even if the title
    ///   changed; moving the file to a new title's slug is `rename`'s job.
    /// - **Staleness guard** (pinned): the file is re-read and byte-compared
    ///   against the bytes recorded at load; on any mismatch — or if the file
    ///   vanished — `.vaultChangedExternally` is thrown and *nothing* is
    ///   written. The caller's recovery path is `load()` then retry.
    /// - The Markdown body is re-attached from the load-time record
    ///   byte-for-byte; bodies are opaque and never re-derived.
    /// - The write is atomic (same filename, whole-file replacement via #5).
    ///
    /// On success the in-memory inventory is replaced in place so `tasks`,
    /// `taskCount` and `lookup(_:)` match disk with no reload;
    /// `lastLoadState`/`warnings` continue to describe the last load. On any
    /// typed failure nothing is written and no state changes.
    @discardableResult
    public func update(_ task: TaskItem) throws -> TaskItem {
        let fileName = try resolveFileName(for: task.id)
        try requireTasksDirectory()
        try verifyUnchanged(taskID: task.id, fileName: fileName)
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else {
            throw VaultStoreError.unknownTaskID(task.id)
        }
        let data = Data(
            FrontmatterCodec.encode(task: task, body: bodyByTaskID[task.id] ?? "").utf8)
        let target = tasksDirectory.appendingPathComponent(fileName, isDirectory: false)
        try performWriterOperation { try fileWriter.write(data, to: target) }

        recordedBytesByTaskID[task.id] = data
        tasks[index] = task
        return task
    }

    /// Renames a task: persists it with `newTitle` and moves its file to the
    /// new title's slug. **The ID is unchanged** (rename-safe references,
    /// PRD §18) — only the cosmetic filename and the title change.
    ///
    /// Pinned sequence (issue #7):
    /// 1. **Staleness guard** — re-read + byte-compare (see `update`); a
    ///    mismatch throws `.vaultChangedExternally` and nothing is touched.
    /// 2. **Move first** via #5 `move(from:to:)` — a destination collision
    ///    fails here, *before any content is touched*, with
    ///    `.renameDestinationExists` and both files stay untouched (no suffix:
    ///    rename is not additive — pinned decision, asymmetric with create on
    ///    purpose). The move itself never overwrites (`RENAME_EXCL`) and is
    ///    whole-or-nothing.
    /// 3. **Atomic write** of the re-serialized task (new title, load-time
    ///    body re-attached byte-for-byte) at the destination. The intermediate
    ///    state after the move — the old content under the new name — is
    ///    always a complete valid file, safe per PRD §18. If this write fails,
    ///    the disk is left in that complete state and the store's in-memory
    ///    state still describes the last load (the mapping keeps pointing at
    ///    the pre-move filename, so any further write for this ID fails closed
    ///    with `.vaultChangedExternally` until a reload resolves the state).
    ///
    /// A same-slug rename (the new title's slug equals the current filename)
    /// is a no-op move that still persists the new title — success, never an
    /// error.
    ///
    /// On success the mapping, the byte record and the inventory (title and
    /// filename-sorted position) are updated; `lastLoadState`/`warnings`
    /// continue to describe the last load. The caller is expected to pass the
    /// task as currently known (from `tasks` or `lookup`); the staleness guard
    /// protects against external disk changes, not stale caller copies.
    @discardableResult
    public func rename(_ task: TaskItem, to newTitle: String) throws -> TaskItem {
        let currentFileName = try resolveFileName(for: task.id)
        try requireTasksDirectory()
        try verifyUnchanged(taskID: task.id, fileName: currentFileName)

        var renamed = task
        renamed.title = newTitle
        let destinationFileName = Self.slug(from: newTitle)
        let currentURL = tasksDirectory.appendingPathComponent(
            currentFileName, isDirectory: false)
        let destinationURL = tasksDirectory.appendingPathComponent(
            destinationFileName, isDirectory: false)

        if destinationFileName != currentFileName {
            if FileManager.default.fileExists(
                atPath: destinationURL.path(percentEncoded: false)) {
                throw VaultStoreError.renameDestinationExists(destinationFileName)
            }
            try performWriterOperation {
                try fileWriter.move(from: currentURL, to: destinationURL)
            }
        }

        let data = Data(
            FrontmatterCodec.encode(task: renamed, body: bodyByTaskID[task.id] ?? "").utf8)
        try performWriterOperation { try fileWriter.write(data, to: destinationURL) }

        fileNameByTaskID[task.id] = destinationFileName
        recordedBytesByTaskID[task.id] = data
        tasks.removeAll { $0.id == task.id }
        insertSorted(renamed, fileName: destinationFileName)
        return renamed
    }

    /// Deletes a task's file and removes the task from the store.
    ///
    /// - **Staleness guard** first (re-read + byte-compare; see `update`) — a
    ///   mismatch throws `.vaultChangedExternally` and nothing is deleted.
    /// - The file is removed via #5 `delete(_:)`; only then are the
    ///   filename↔ID mapping entry and the inventory entry removed, so a
    ///   failed delete changes nothing on disk and nothing in memory.
    ///
    /// On success `tasks`, `taskCount` and `lookup(_:)` reflect the removal
    /// with no reload; `lastLoadState`/`warnings` continue to describe the
    /// last load. Any later write operation for the deleted ID throws
    /// `.unknownTaskID`.
    public func delete(_ task: TaskItem) throws {
        let fileName = try resolveFileName(for: task.id)
        try requireTasksDirectory()
        try verifyUnchanged(taskID: task.id, fileName: fileName)
        let target = tasksDirectory.appendingPathComponent(fileName, isDirectory: false)
        try performWriterOperation { try fileWriter.delete(target) }

        fileNameByTaskID[task.id] = nil
        recordedBytesByTaskID[task.id] = nil
        bodyByTaskID[task.id] = nil
        tasks.removeAll { $0.id == task.id }
    }

    /// Changes a top-level task's status and writes it through to disk
    /// immediately (§6.5): the same mechanics as `update` (staleness guard,
    /// same filename, body preserved byte-for-byte), but an explicit API so a
    /// status change can never linger in memory only.
    ///
    /// Top-level tasks only: a subtask's status lives inside its parent task's
    /// file, so a subtask ID throws `.notTopLevelTask` (subtask writes are
    /// #8). The status is written exactly as given — no automatic
    /// propagation to parent/subtask statuses (out of scope for this issue).
    ///
    /// On success the in-memory inventory is replaced in place;
    /// `lastLoadState`/`warnings` continue to describe the last load.
    @discardableResult
    public func setStatus(_ id: UUID, to status: TaskStatus) throws -> TaskItem {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            if tasks.contains(where: { $0.chain(to: id) != nil }) {
                throw VaultStoreError.notTopLevelTask(id)
            }
            throw VaultStoreError.unknownTaskID(id)
        }
        var updated = tasks[index]
        updated.status = status
        return try update(updated)
    }

    // MARK: - Manual task ordering (issue #10, PRD §8.4)

    /// Applies a batch of `ID → new order` updates for top-level tasks and
    /// persists each affected task's file (issue #10, PRD §8.4).
    ///
    /// - **Validate first:** every ID is checked against the inventory before
    ///   anything is written. An ID that is not loaded fails
    ///   `.unknownTaskID`; an ID that belongs to a subtask fails
    ///   `.notTopLevelTask` (same convention as #7's `setStatus` — ordering is
    ///   a top-level field). Both abort the batch with *nothing* written.
    ///   Offending IDs are reported deterministically (UUID-string-sorted).
    /// - **Changed tasks only:** a task whose current `order` already equals
    ///   the requested value is skipped (no write, no byte-record churn). The
    ///   batch the #18 UI passes is `TaskOrdering.reorder`'s changed-only
    ///   output, so this is a defensive no-op guard; an empty map writes
    ///   nothing.
    /// - **Per-task writes** ride the existing #7 `update` path exactly:
    ///   filename resolved via the load-time mapping (never re-derived from a
    ///   title), `requireTasksDirectory()`, the reload-before-write staleness
    ///   guard, body re-attached byte-for-byte, atomic temp+rename via #5 —
    ///   with the in-memory inventory and byte records synced after **each**
    ///   success, so `tasks`/`taskCount`/`lookup(_:)` match disk with no
    ///   reload. `lastLoadState`/`warnings` keep describing the last load.
    /// - **Deterministic application order:** inventory order
    ///   (filename-sorted), which makes both the write sequence and the
    ///   completed/pending split of a mid-batch failure reproducible.
    /// - **NOT cross-file atomic (documented honestly):** PRD §18 atomicity is
    ///   per file and each task is its own file, so a mid-batch failure —
    ///   `.vaultChangedExternally`, `.writeFailed`, … — can leave some files
    ///   reordered and others not. The failure surfaces typed as
    ///   `.orderingBatchIncomplete(completed:pending:underlying:)` naming the
    ///   files written vs. not written (the failing task's own file is
    ///   untouched — its whole-file write is atomic). The recovery path is
    ///   `load()` then retry of the pending updates. After a failure the
    ///   inventory still matches disk for every file (written ones were
    ///   synced, untouched ones never diverged); the stale byte record of an
    ///   externally changed file is only refreshed by the reload.
    ///
    /// - Returns: The updated tasks, in application (inventory) order.
    @discardableResult
    public func applyOrdering(groupUpdates: [UUID: Int]) throws -> [TaskItem] {
        // Validate every ID before writing anything (documented above).
        let knownIDs = Set(tasks.map(\.id))
        for id in groupUpdates.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            if knownIDs.contains(id) { continue }
            if tasks.contains(where: { $0.chain(to: id) != nil }) {
                throw VaultStoreError.notTopLevelTask(id)
            }
            throw VaultStoreError.unknownTaskID(id)
        }

        // The work list in deterministic application order (inventory order),
        // restricted to tasks whose persisted value actually changes.
        let workList: [(id: UUID, fileName: String, newOrder: Int)] = tasks.compactMap { task in
            guard let newOrder = groupUpdates[task.id], task.order != newOrder,
                let fileName = fileNameByTaskID[task.id]
            else { return nil }
            return (task.id, fileName, newOrder)
        }

        var completed: [UUID: String] = [:]
        var applied: [TaskItem] = []
        for (index, entry) in workList.enumerated() {
            // The inventory holds the task's current content; only `order`
            // changes. (The actor serializes writers, so nothing can move
            // between validation and write; the lookup fails closed anyway.)
            guard let current = tasks.first(where: { $0.id == entry.id }) else {
                throw VaultStoreError.unknownTaskID(entry.id)
            }
            var mutated = current
            mutated.order = entry.newOrder
            do {
                applied.append(try update(mutated))
                completed[entry.id] = entry.fileName
            } catch let error as VaultStoreError {
                // The failing task plus everything after it was not written —
                // its whole-file write is atomic, so nothing of it landed.
                let pending = Dictionary(
                    uniqueKeysWithValues: workList[index...].map { ($0.id, $0.fileName) })
                throw VaultStoreError.orderingBatchIncomplete(
                    completed: completed, pending: pending, underlying: error)
            }
        }
        return applied
    }

    // MARK: - Subtask CRUD (issue #8, PRD §5.4, §7, §18)

    /// Appends a subtask inside a parent task's tree and persists the whole
    /// parent file (issue #8, PRD §5.4, §7).
    ///
    /// - `toParentSubtaskID: nil` appends to the parent task's **top-level**
    ///   subtask list; a non-nil ID appends as the **last child** of that
    ///   subtask, searched at any depth (unbounded nesting). Positioning
    ///   within a list is `reorderSubtasks`' job.
    /// - The subtask keeps the UUID its model default assigned
    ///   (`SubtaskItem.init` defaults to a fresh `UUID()`); it is persisted in
    ///   the parent file's frontmatter and returned to the caller through the
    ///   updated parent task.
    /// - **No project/categories on the subtask** (pinned): simply not part of
    ///   the API — `SubtaskItem` has no such fields; the child inherits them
    ///   from its ancestors via the #3 helpers.
    /// - **ID collision fails loudly** (pinned): the new subtask's ID may not
    ///   collide with ANY existing ID in the parent file — the task's own ID
    ///   or any subtask ID at any depth, across different subtask parents. No
    ///   silent regeneration (the caller would hold a different ID than the
    ///   one it passed — PRD §18), matching `.duplicateTaskIDOnCreate`'s
    ///   stance. IDs from *other* files are not checked: every top-level task
    ///   is its own file with its own ID namespace.
    ///
    /// Shared path for every subtask operation (issue #8): resolve the parent
    /// task from the inventory (mapping/inventory lookups only — never
    /// re-derived from a title), apply the pure tree mutation, then write the
    /// whole parent file via the #7 `update` mechanics:
    /// `requireTasksDirectory()`, the `verifyUnchanged` staleness guard,
    /// codec encode with the load-time body re-attached byte-for-byte, atomic
    /// temp+rename via #5. On success the inventory and byte records are
    /// updated in place so `tasks`/`taskCount`/`lookup(_:)` match disk with no
    /// reload; `lastLoadState`/`warnings` keep describing the last load
    /// (documented, consistent with #7). On any typed failure nothing is
    /// written and no state changes.
    ///
    /// - Returns: The updated parent `TaskItem` (including the new subtask).
    @discardableResult
    public func addSubtask(
        parentID: UUID,
        subtask: SubtaskItem,
        toParentSubtaskID: UUID? = nil
    ) throws -> TaskItem {
        let parent = try resolveParentTask(parentID)
        guard parent.id != subtask.id, parent.chain(to: subtask.id) == nil else {
            throw VaultStoreError.duplicateSubtaskIDOnAdd(
                subtaskID: subtask.id, parentTaskID: parent.id)
        }
        var mutated = parent
        if let targetID = toParentSubtaskID {
            guard let appended = parent.subtasks.appending(
                subtask, asLastChildOf: targetID)
            else {
                throw VaultStoreError.unknownSubtaskID(
                    subtaskID: targetID, parentTaskID: parent.id)
            }
            mutated.subtasks = appended
        } else {
            mutated.subtasks.append(subtask)
        }
        return try update(mutated)
    }

    /// Applies `modified` to a copy of the target subtask — searched at any
    /// depth in the parent task's tree — and persists the whole parent file
    /// (issue #8, PRD §5.4, §7).
    ///
    /// **Editable surface (pinned):** title, status, priority, effort,
    /// deadline, notes. Two parts of the target are *not* caller-editable
    /// data, and the store enforces both on the copy before it is written:
    /// - **The target's `id` is re-asserted after the closure** — the ID
    ///   addresses the operation, it is not editable data. (`SubtaskItem.id`
    ///   is a `let`, so a closure cannot change it today; the re-assertion
    ///   keeps the contract true even if the model ever loosens.)
    /// - **`children` edits through the closure are discarded** and the
    ///   original subtree restored — children edits are not part of this
    ///   operation's contract; the tree shape is mutated only by add, delete
    ///   and reorder.
    ///
    /// Shared path (staleness guard, atomic write, in-place inventory/byte
    /// record update, untouched `lastLoadState`/`warnings`) as documented on
    /// `addSubtask`. Errors: unknown parent → `.unknownTaskID`, parent-is-
    /// subtask → `.notTopLevelTask`, unknown subtask at any level →
    /// `.unknownSubtaskID`, unavailable vault → `.writeFailed`, external file
    /// change → `.vaultChangedExternally` with nothing written (recover via
    /// `load()` then retry).
    ///
    /// - Returns: The updated parent `TaskItem`.
    @discardableResult
    public func updateSubtask(
        parentID: UUID,
        subtaskID: UUID,
        modified: (inout SubtaskItem) -> Void
    ) throws -> TaskItem {
        let parent = try resolveParentTask(parentID)
        guard let mutatedSubtasks = parent.subtasks.updating(id: subtaskID, modified) else {
            throw VaultStoreError.unknownSubtaskID(
                subtaskID: subtaskID, parentTaskID: parent.id)
        }
        var mutated = parent
        mutated.subtasks = mutatedSubtasks
        return try update(mutated)
    }

    /// Removes the subtask `subtaskID` — searched at any depth in the parent
    /// task's tree — **together with its whole subtree**, and persists the
    /// whole parent file (issue #8). Siblings and other branches survive;
    /// unbounded nesting means the removed subtree may itself nest to any
    /// depth. Shared path and typed errors as documented on `addSubtask`.
    public func deleteSubtask(parentID: UUID, subtaskID: UUID) throws {
        let parent = try resolveParentTask(parentID)
        guard let mutatedSubtasks = parent.subtasks.removing(id: subtaskID) else {
            throw VaultStoreError.unknownSubtaskID(
                subtaskID: subtaskID, parentTaskID: parent.id)
        }
        var mutated = parent
        mutated.subtasks = mutatedSubtasks
        _ = try update(mutated)
    }

    /// Reorders exactly one sibling list inside the parent task's tree and
    /// persists the whole parent file (issue #8, PRD §5.4, §7).
    ///
    /// - `parentSubtaskID: nil` reorders the parent task's **top-level**
    ///   subtask list; a non-nil ID reorders that subtask's children (searched
    ///   at any depth). Ordering persists via the file's list order — no order
    ///   field is added.
    /// - **Pure core:** the permutation is computed by the pure, unit-testable
    ///   `[SubtaskItem]` helpers below the actor (`reordered(to:)` /
    ///   `reorderingChildren(of:to:)`), in the spirit of #3's
    ///   `newlyDoneIDs(markingDone:)`.
    /// - `siblingIDsInNewOrder` must be an exact permutation of the targeted
    ///   list's current IDs — missing, extra, or duplicated IDs throw
    ///   `.reorderNotExactPermutation` and nothing is written.
    ///
    /// Shared path and typed errors as documented on `addSubtask`.
    ///
    /// - Returns: The updated parent `TaskItem`.
    @discardableResult
    public func reorderSubtasks(
        parentID: UUID,
        parentSubtaskID: UUID? = nil,
        siblingIDsInNewOrder: [UUID]
    ) throws -> TaskItem {
        let parent = try resolveParentTask(parentID)
        var mutated = parent
        if let parentSubtaskID {
            guard let reorderedChildren = try parent.subtasks.reorderingChildren(
                of: parentSubtaskID, to: siblingIDsInNewOrder)
            else {
                throw VaultStoreError.unknownSubtaskID(
                    subtaskID: parentSubtaskID, parentTaskID: parent.id)
            }
            mutated.subtasks = reorderedChildren
        } else {
            mutated.subtasks = try parent.subtasks.reordered(to: siblingIDsInNewOrder)
        }
        return try update(mutated)
    }

    /// Changes a subtask's status and writes it through to disk immediately —
    /// a thin wrapper over `updateSubtask` (issue #8), symmetric with #7's
    /// top-level `setStatus`, so it carries all the same guarantees and typed
    /// errors (including the re-asserted `id` and the staleness guard). The
    /// status is written exactly as given — no propagation to ancestors or
    /// descendants (parent auto-completion bubble-up is #9).
    ///
    /// - Returns: The updated parent `TaskItem`.
    @discardableResult
    public func setStatus(
        parentID: UUID, subtaskID: UUID, to status: TaskStatus
    ) throws -> TaskItem {
        try updateSubtask(parentID: parentID, subtaskID: subtaskID) { $0.status = status }
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
            fileNameByTaskID = [:]
            recordedBytesByTaskID = [:]
            bodyByTaskID = [:]
        }
        return state
    }

    private func readInventory(from tasksDirectory: URL) -> Inventory {
        // The write-side records mirror exactly the files that load in *this*
        // pass; they are rebuilt from scratch on every load.
        fileNameByTaskID = [:]
        recordedBytesByTaskID = [:]
        bodyByTaskID = [:]

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

            let bytes: Data
            let task: TaskItem
            let body: String
            do {
                // The exact bytes are the staleness-guard record; the parse
                // path is the same split + decode as the codec's `parseTask`.
                bytes = try Data(contentsOf: entry)
                guard let text = String(data: bytes, encoding: .utf8) else {
                    throw VaultStoreError.nonUTF8Encoded(fileName)
                }
                let (frontmatter, parsedBody) = try FrontmatterCodec.split(text)
                body = parsedBody
                task = try FrontmatterCodec.decodeTask(frontmatter: frontmatter)
            } catch {
                warnings.append(
                    LoadWarning(fileName: fileName, underlyingError: error))
                continue
            }

            if let firstFile = fileNameByTaskID[task.id] {
                warnings.append(
                    LoadWarning(
                        fileName: fileName,
                        underlyingError: VaultStoreError.duplicateTaskID(
                            id: task.id, firstFile: firstFile)))
                continue
            }
            fileNameByTaskID[task.id] = fileName
            recordedBytesByTaskID[task.id] = bytes
            bodyByTaskID[task.id] = body
            tasks.append(task)
        }

        return Inventory(tasks: tasks, warnings: warnings)
    }

    // MARK: - Writing internals

    /// The filename stem for a task title — the pinned slug rule (issue #7):
    ///
    /// - Case- and space-preserving to match the fixture convention
    ///   (`"Read Deep Work"` → `Read Deep Work.md`).
    /// - Filesystem-unsafe characters — `/`, `:` and control characters — are
    ///   replaced with `-`.
    /// - Trailing dots and spaces are trimmed.
    /// - A title that sanitizes to empty becomes `untitled`.
    /// - `.md` is appended. Deterministic: the same title always produces the
    ///   same slug.
    static func slug(from title: String) -> String {
        var sanitized = ""
        sanitized.reserveCapacity(title.count)
        for scalar in title.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar.value < 0x20 || scalar.value == 0x7F {
                sanitized.append("-")
            } else {
                sanitized.unicodeScalars.append(scalar)
            }
        }
        while let last = sanitized.last, last == "." || last == " " {
            sanitized.removeLast()
        }
        if sanitized.isEmpty {
            sanitized = "untitled"
        }
        return sanitized + ".md"
    }

    /// The vault's `Tasks/` directory.
    private var tasksDirectory: URL {
        vaultURL.appendingPathComponent("Tasks", isDirectory: true)
    }

    /// The filename the given loaded task ID currently maps to — the only way
    /// write operations find their target file (pinned: never re-derived from
    /// a title, issue #7). Unknown/stale IDs fail typed.
    private func resolveFileName(for id: UUID) throws -> String {
        guard let fileName = fileNameByTaskID[id] else {
            throw VaultStoreError.unknownTaskID(id)
        }
        return fileName
    }

    /// The loaded top-level task with `parentID` — the only way subtask
    /// operations resolve their parent (inventory lookups only, never
    /// re-derived from a title, issue #8). An ID that is not loaded fails with
    /// `.unknownTaskID`; an ID that belongs to a subtask inside some loaded
    /// task's tree fails with `.notTopLevelTask`.
    private func resolveParentTask(_ parentID: UUID) throws -> TaskItem {
        guard let parent = tasks.first(where: { $0.id == parentID }) else {
            if tasks.contains(where: { $0.chain(to: parentID) != nil }) {
                throw VaultStoreError.notTopLevelTask(parentID)
            }
            throw VaultStoreError.unknownTaskID(parentID)
        }
        return parent
    }

    /// Fails with the #5 typed `directoryMissing` (wrapped in `writeFailed`)
    /// when the vault or its `Tasks/` directory is missing or not a directory.
    /// Checked *before* the staleness guard so an unavailable vault surfaces
    /// as the underlying writer error rather than a spurious conflict.
    private func requireTasksDirectory() throws {
        var isDirectory: ObjCBool = false
        let path = tasksDirectory.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw VaultStoreError.writeFailed(.directoryMissing(path: path))
        }
    }

    /// The pinned reload-before-write staleness guard (issue #7): re-reads the
    /// task's file and byte-compares it against the bytes recorded at load —
    /// same strength as a content hash, no crypto dependency. Any mismatch,
    /// including a failed re-read (the file vanished or became unreadable),
    /// throws `.vaultChangedExternally` before anything is written; the
    /// caller's recovery path is `load()` then retry.
    private func verifyUnchanged(taskID: UUID, fileName: String) throws {
        let url = tasksDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard let current = try? Data(contentsOf: url),
            current == recordedBytesByTaskID[taskID]
        else {
            throw VaultStoreError.vaultChangedExternally(id: taskID, fileName: fileName)
        }
    }

    /// Runs an `AtomicFileWriter` operation, surfacing its typed #5 errors
    /// wrapped in `VaultStoreError.writeFailed` (vault/`Tasks/` missing →
    /// `directoryMissing`, … — pinned, issue #7). Any other error kind (none
    /// today; the writer is fully typed) propagates unchanged.
    private func performWriterOperation<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as AtomicFileWriterError {
            throw VaultStoreError.writeFailed(error)
        }
    }

    /// The first free `<slug>` / `<stem>-2.md` / `<stem>-3.md` … name for the
    /// given slug (a full filename including its `.md` extension, as produced
    /// by `slug(from:)`), probing **real on-disk existence** so externally
    /// created files count (pinned create-collision strategy, issue #7). An
    /// entry of any kind (file, directory, symlink) blocks a candidate name.
    /// The probe is bounded (`maxSlugCollisionProbes` suffixed candidates) and
    /// surfaces `.noFreeFileName` instead of probing forever.
    private func freeFileName(probing slug: String) throws -> String {
        let stem = slug.hasSuffix(".md") ? String(slug.dropLast(3)) : slug
        var candidate = slug
        var suffix = 2
        while FileManager.default.fileExists(
            atPath: tasksDirectory.appendingPathComponent(candidate, isDirectory: false)
                .path(percentEncoded: false))
        {
            guard suffix - 2 < Self.maxSlugCollisionProbes else {
                throw VaultStoreError.noFreeFileName(stem: stem)
            }
            candidate = "\(stem)-\(suffix).md"
            suffix += 1
        }
        return candidate
    }

    /// Inserts `task` into `tasks` at the position that keeps the
    /// filename-sorted order a `load()` produces, comparing `fileName` against
    /// the mapped filenames of the tasks currently in the inventory.
    private func insertSorted(_ task: TaskItem, fileName: String) {
        var index = 0
        for existing in tasks {
            guard let existingName = fileNameByTaskID[existing.id] else { continue }
            if existingName < fileName {
                index += 1
            } else {
                break
            }
        }
        tasks.insert(task, at: index)
    }
}

// MARK: - Pure subtask tree mutations (issue #8, PRD §5.4/§7)

/// Pure helpers over one sibling list of `SubtaskItem`s, backing the #8
/// subtask CRUD: every helper maps the current list (and its arguments) to a
/// **new** list — the receiver is never mutated, nothing touches the store or
/// the disk — so `VaultStore` computes the fully mutated parent task first and
/// hands it to the #7 update mechanics for the atomic write only when the
/// mutation is valid. In the spirit of #3's pure model helpers
/// (`TaskItem.newlyDoneIDs(markingDone:)`); these live in `Vault/` (not
/// `Models/`) because they encode store-side persistence semantics, and
/// `Models/` is frozen for issue #8.
extension Array where Element == SubtaskItem {
    /// A copy of this sibling list with `newSubtask` appended as the **last
    /// child** of the subtask with `parentSubtaskID`, searching nested
    /// children at any depth (unbounded nesting — no depth limits). Returns
    /// nil when no subtask with that ID exists in this list or any descendant
    /// list; the first match in list order wins, same as `lookup(_:)`.
    func appending(
        _ newSubtask: SubtaskItem, asLastChildOf parentSubtaskID: UUID
    ) -> [SubtaskItem]? {
        var copy = self
        for index in copy.indices {
            if copy[index].id == parentSubtaskID {
                copy[index].children.append(newSubtask)
                return copy
            }
            if let deeper = copy[index].children.appending(
                newSubtask, asLastChildOf: parentSubtaskID)
            {
                copy[index].children = deeper
                return copy
            }
        }
        return nil
    }

    /// A copy of this sibling list with `modify` applied to the subtask with
    /// `targetID` (first match in list order, nested at any depth). Returns
    /// nil when the ID does not exist. The two parts the #8 contract keeps out
    /// of the caller's reach are enforced here, on the copy: the target's
    /// `id` is re-asserted after the closure (the ID addresses the operation —
    /// it is not editable data), and any `children` edits through the closure
    /// are discarded (the original subtree is restored — tree shape is
    /// mutated only by add/delete/reorder).
    func updating(
        id targetID: UUID, _ modify: (inout SubtaskItem) -> Void
    ) -> [SubtaskItem]? {
        var copy = self
        for index in copy.indices {
            guard copy[index].id == targetID else {
                if let deeper = copy[index].children.updating(id: targetID, modify) {
                    copy[index].children = deeper
                    return copy
                }
                continue
            }
            var target = copy[index]
            let assertedID = target.id
            let originalChildren = target.children
            modify(&target)
            copy[index] = SubtaskItem(
                id: assertedID,
                title: target.title,
                status: target.status,
                priority: target.priority,
                effort: target.effort,
                deadline: target.deadline,
                notes: target.notes,
                children: originalChildren)
            return copy
        }
        return nil
    }

    /// A copy of this sibling list with the subtask with `targetID` (first
    /// match, any depth) — and its whole subtree — removed. Returns nil when
    /// the ID does not exist; siblings and other branches survive untouched.
    func removing(id targetID: UUID) -> [SubtaskItem]? {
        var copy = self
        if let index = copy.firstIndex(where: { $0.id == targetID }) {
            copy.remove(at: index)
            return copy
        }
        for index in copy.indices {
            if let deeper = copy[index].children.removing(id: targetID) {
                copy[index].children = deeper
                return copy
            }
        }
        return nil
    }

    /// This sibling list reordered to exactly `newOrder` — the pure,
    /// unit-testable core of `VaultStore.reorderSubtasks` (issue #8). Every
    /// current ID must appear in `newOrder` exactly once, in the desired
    /// sequence; a missing, extra, or duplicated ID throws
    /// `VaultStoreError.reorderNotExactPermutation` carrying both lists.
    /// Ordering persists via the file's list order — no order field exists.
    func reordered(to siblingIDsInNewOrder: [UUID]) throws -> [SubtaskItem] {
        let currentSiblings = map(\.id)
        guard siblingIDsInNewOrder.count == currentSiblings.count,
            Set(siblingIDsInNewOrder) == Set(currentSiblings)
        else {
            throw VaultStoreError.reorderNotExactPermutation(
                currentSiblings: currentSiblings,
                proposedOrder: siblingIDsInNewOrder)
        }
        // First wins on duplicate keys, matching `lookup(_:)`'s first-match
        // rule (loaded files are not deduplicated across subtask lists).
        let byID = Dictionary(map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return siblingIDsInNewOrder.compactMap { byID[$0] }
    }

    /// A copy of this sibling list in which the children of the subtask with
    /// `parentSubtaskID` (first match, any depth) are reordered via
    /// `reordered(to:)`. Returns nil when no subtask with that ID exists;
    /// throws the permutation error when `newOrder` is not an exact
    /// permutation of that subtask's current children.
    func reorderingChildren(
        of parentSubtaskID: UUID, to newOrder: [UUID]
    ) throws -> [SubtaskItem]? {
        var copy = self
        for index in copy.indices {
            if copy[index].id == parentSubtaskID {
                copy[index].children = try copy[index].children.reordered(to: newOrder)
                return copy
            }
            if let deeper = try copy[index].children.reorderingChildren(
                of: parentSubtaskID, to: newOrder)
            {
                copy[index].children = deeper
                return copy
            }
        }
        return nil
    }
}
