import Foundation

/// File-system-level atomic writer for the vault (issue #5, PRD §18).
///
/// A low-level, content-agnostic component: it moves bytes and never parses
/// them (the #4 frontmatter codec is consumed only by this issue's tests, never
/// by production code in this file). Every operation either completes fully or
/// fails with a typed `AtomicFileWriterError` while leaving the previous
/// on-disk state intact — a crash or interrupt at any point can never leave a
/// partial, truncated or silently lost file behind.
///
/// # Atomic write
/// `write(_:to:durability:)` creates a hidden temp file (`.UUID.tmp`) **in the
/// same directory as the target** (so the publishing rename never crosses a
/// volume boundary), writes the payload, `fsync`s it, closes it and then
/// publishes it with a single atomic `rename(2)` over the target. An existing
/// target is replaced whole; if the target path is a symlink the rename
/// replaces the symlink itself rather than following it. A crash before the
/// rename leaves the old file at the target, a crash after it leaves the new
/// file — never anything in between. On any failure the writer's own temp file
/// is unlinked (best effort), so no temp litter is left behind.
///
/// # Concurrency (deliberate choice: last-wins via unique temp names)
/// Writes to the same target are safe under concurrent use without any locking
/// or per-path serialization: every call gets its own unique temp name (UUID),
/// so concurrent writers can never collide on temp paths, and `rename(2)` is
/// atomic, so each publication installs one *complete* payload — the last
/// rename to land wins and earlier ones are simply superseded. Completion
/// order is deliberately nondeterministic; the invariant the tests rely on is
/// that the final content at the target is always exactly one of the
/// concurrently written payloads. This was chosen over serialized-per-path
/// writes because it needs no shared mutable state, scales across tasks, and
/// the rename atomicity already provides the whole-file guarantee that
/// serialization would otherwise exist to protect.
///
/// # Durability (deliberate choice: directory fsync is opt-in)
/// - `.standard` (default): fsync the temp file, then atomic rename. Not
///   strictly required on APFS (macOS's default filesystem journals metadata,
///   and the platform's own atomic-save stacks rely on this level), and the
///   PRD §18 guarantee holds: the target always holds the old *or* the new
///   complete file.
/// - `.strict`: additionally fsyncs the parent directory after the rename so
///   the rename itself is durable even on filesystems with weaker metadata
///   guarantees. If the filesystem cannot fsync a directory fd, the call
///   reports `EINVAL`; that specific errno is deliberately treated as
///   "unsupported" and skipped (degrading to `.standard` behavior) instead of
///   failing an already-published write. Any other directory-sync failure
///   surfaces as `.directorySyncFailed`. Note the ordering: the rename has
///   already succeeded by then, so the target holds the *new* content when
///   that error surfaces.
///
/// # Move and delete
/// `move(from:to:)` is for task-file renames when a title changes: it never
/// silently overwrites — an existing destination (file, directory or dangling
/// symlink) fails with `.destinationExists` and the caller resolves the
/// conflict. Moving onto the same path is a documented no-op success
/// (idempotent for retitles that normalize to the same filename). `delete(_:)`
/// is a plain unlink: deleting a missing file is a typed error, never a crash
/// and never a silent success.
///
/// # Failure handling
/// All failures surface as typed, `Equatable` errors with the underlying
/// `POSIXErrorCode` preserved; nothing is swallowed or turned into a crash.
/// The only retry anywhere is bounded (≤5 attempts) for the astronomically
/// unlikely temp-name collision — no operation ever retries indefinitely.
public struct AtomicFileWriter: Sendable {

    /// Durability level for `write(_:to:durability:)`. See the type
    /// documentation for the trade-off between the two cases.
    public enum Durability: Sendable, Equatable {
        /// fsync the temp file + atomic rename (default; no parent-dir fsync).
        case standard
        /// Additionally fsync the parent directory after the rename.
        case strict
    }

    /// Test-only seam (internal): the points at which a hook installed by tests
    /// observes the write pipeline or injects a failure. Production code always
    /// constructs `AtomicFileWriter()` with no hook. A throwing hook aborts the
    /// operation at that point with the thrown error propagated unchanged,
    /// including the normal temp-file cleanup.
    enum HookEvent: Sendable {
        /// The temp file was fully written, fsynced and closed; the rename is next.
        case tempCreated(URL)
        /// Immediately before `rename(temp, target)`.
        case beforeRename
        /// `.strict` durability only: immediately before the parent-dir fsync.
        case beforeDirectorySync
    }

    typealias Hook = @Sendable (HookEvent) throws -> Void

    /// Maximum attempts to pick an unused temp file name. UUID collisions are
    /// astronomically unlikely; the bound exists so no path ever retries
    /// indefinitely (PRD §18).
    private static let maxTempNameAttempts = 5

    /// `RENAME_EXCL` from `<sys/stdio.h>` (0x4): fail instead of overwriting
    /// when the destination exists. The C macro does not import into Swift.
    private static let renameExclFlag: UInt32 = 0x0000_0004

    /// Wraps the thread-local `errno` as a `POSIXErrorCode`. The failable
    /// `init(rawValue:)` cannot fail for a live errno value (every errno has an
    /// enum case), but the component bans force-unwraps, so the conversion is
    /// kept total with a harmless fallback case instead.
    private static func currentPOSIXCode() -> POSIXErrorCode {
        POSIXErrorCode(rawValue: errno) ?? .EPERM
    }

    private let hook: Hook?

    /// Creates a writer for production use (no test seam installed).
    public init() {
        self.init(hook: nil)
    }

    /// Test-only initializer installing a hook around fsync/rename.
    init(hook: Hook?) {
        self.hook = hook
    }

    // MARK: - Atomic write

    /// Atomically writes `data` over `target`, leaving either the old or the
    /// new complete file at the target no matter where a crash lands (PRD §18).
    /// Throws a typed `AtomicFileWriterError` on any failure; on failure the
    /// target keeps its previous content and no temp file is left behind.
    public func write(_ data: Data, to target: URL, durability: Durability = .standard) throws {
        let targetPath = target.path(percentEncoded: false)
        guard !target.lastPathComponent.isEmpty else {
            throw AtomicFileWriterError.posixError(
                code: .EINVAL, operation: "write", path: targetPath)
        }
        let directoryURL = target.deletingLastPathComponent()
        let directoryPath = directoryURL.path(percentEncoded: false)
        try requireDirectory(atPath: directoryPath)

        let (tempURL, fd) = try createTempFile(in: directoryURL)
        let tempPath = tempURL.path(percentEncoded: false)

        do {
            try writeAndSync(data, toFD: fd, path: tempPath)
            guard Darwin.close(fd) == 0 else {
                throw AtomicFileWriterError.posixError(
                    code: Self.currentPOSIXCode(),
                    operation: "close-temp-file", path: tempPath)
            }
        } catch {
            cleanupTemp(atPath: tempPath)
            throw error
        }

        do {
            try hook?(.tempCreated(tempURL))
            try publishTemp(tempPath, over: targetPath)
        } catch {
            cleanupTemp(atPath: tempPath)
            throw error
        }

        guard durability == .strict else { return }
        try hook?(.beforeDirectorySync)
        try syncDirectory(atPath: directoryPath)
    }

    /// Creates (and opens for writing) a unique hidden temp file `.UUID.tmp`
    /// inside `directory` — the same directory as the target, so the publishing
    /// rename never crosses a volume boundary. The UUID makes collisions
    /// impossible in practice and keeps concurrent writes to the same target
    /// from ever sharing a temp path.
    private func createTempFile(in directory: URL) throws -> (url: URL, fd: Int32) {
        var lastCode = POSIXErrorCode.EEXIST
        var lastPath = ""
        for _ in 0..<Self.maxTempNameAttempts {
            let url = directory.appendingPathComponent("." + UUID().uuidString + ".tmp")
            let path = url.path(percentEncoded: false)
            let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o644))
            if fd >= 0 {
                return (url, fd)
            }
            lastCode = Self.currentPOSIXCode()
            lastPath = path
            guard lastCode == .EEXIST else { break }
        }
        throw AtomicFileWriterError.posixError(
            code: lastCode, operation: "open-temp-file", path: lastPath)
    }

    /// Writes every byte of `data` to the open temp file descriptor and fsyncs
    /// it, so the payload is fully on disk before the rename publishes it.
    private func writeAndSync(_ data: Data, toFD fd: Int32, path: String) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) throws in
            guard data.count > 0 else { return }
            guard let base = buffer.baseAddress else {
                throw AtomicFileWriterError.posixError(
                    code: .EFAULT, operation: "write-temp-file", path: path)
            }
            var offset = 0
            while offset < data.count {
                let bytesWritten = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if bytesWritten < 0 {
                    let code = Self.currentPOSIXCode()
                    guard code != .EINTR else { continue }
                    throw AtomicFileWriterError.posixError(
                        code: code, operation: "write-temp-file", path: path)
                }
                offset += bytesWritten
            }
        }
        try fsyncFD(fd, operation: "fsync-temp-file", path: path)
    }

    /// Publishes the temp file with a single atomic rename over the target.
    private func publishTemp(_ tempPath: String, over targetPath: String) throws {
        try hook?(.beforeRename)
        guard Darwin.rename(tempPath, targetPath) == 0 else {
            throw AtomicFileWriterError.renameFailed(
                code: Self.currentPOSIXCode(), path: targetPath)
        }
    }

    /// `.strict` durability: fsync the parent directory so the rename itself is
    /// durable. `EINVAL` means the filesystem cannot fsync a directory fd —
    /// treated as unsupported and skipped; every other failure is fatal-typed.
    private func syncDirectory(atPath directoryPath: String) throws {
        let fd = Darwin.open(directoryPath, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw AtomicFileWriterError.directorySyncFailed(
                code: Self.currentPOSIXCode(), path: directoryPath)
        }
        do {
            while Darwin.fsync(fd) != 0 {
                let code = Self.currentPOSIXCode()
                if code == .EINTR { continue }
                if code == .EINVAL { break }  // directory fsync unsupported here
                throw AtomicFileWriterError.directorySyncFailed(code: code, path: directoryPath)
            }
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
        if Darwin.close(fd) != 0 {
            throw AtomicFileWriterError.directorySyncFailed(
                code: Self.currentPOSIXCode(), path: directoryPath)
        }
    }

    /// `fsync` with EINTR retry (the only retry besides temp naming).
    private func fsyncFD(_ fd: Int32, operation: String, path: String) throws {
        while Darwin.fsync(fd) != 0 {
            let code = Self.currentPOSIXCode()
            if code == .EINTR { continue }
            throw AtomicFileWriterError.posixError(code: code, operation: operation, path: path)
        }
    }

    // MARK: - Move

    /// Moves (renames) `source` to `destination` without ever silently
    /// overwriting an existing destination (used for title-based filename
    /// renames when a task title changes).
    ///
    /// Semantics (documented decisions):
    /// - Moving onto the *same path* (lexically identical after URL
    ///   standardization) is a no-op success: idempotent for retitles that
    ///   normalize to the same filename; no filesystem call is made at all.
    /// - An existing destination — file, directory or dangling symlink — fails
    ///   with `.destinationExists`; this layer never resolves conflicts.
    /// - The no-overwrite guarantee is race-proof: the move is attempted with
    ///   `renamex_np(..., RENAME_EXCL)`, which fails with `EEXIST` instead of
    ///   clobbering even if a concurrent writer creates the destination after
    ///   the pre-check. Only when the filesystem reports the flag unsupported
    ///   (`EINVAL`/`ENOSYS`) does it fall back to plain `rename`, where the
    ///   pre-check above is the guard (a tiny residual TOCTOU window, called
    ///   out here deliberately).
    /// - On success the source no longer exists; on any failure the source is
    ///   untouched — a rename happens whole or not at all, never half-moved.
    public func move(from source: URL, to destination: URL) throws {
        let sourcePath = source.path(percentEncoded: false)
        let destinationPath = destination.path(percentEncoded: false)
        if source.standardizedFileURL.path(percentEncoded: false)
            == destination.standardizedFileURL.path(percentEncoded: false) {
            return  // same path: documented no-op success
        }
        try requireEntry(atPath: sourcePath)
        try requireDirectory(
            atPath: destination.deletingLastPathComponent().path(percentEncoded: false))
        if entryExists(atPath: destinationPath) {
            throw AtomicFileWriterError.destinationExists(path: destinationPath)
        }

        if Darwin.renamex_np(sourcePath, destinationPath, Self.renameExclFlag) == 0 {
            return
        }
        let code = Self.currentPOSIXCode()
        switch code {
        case .EEXIST, .ENOTEMPTY:
            // The destination appeared between the pre-check and the rename
            // (or lstat missed a filesystem oddity): never overwrite.
            throw AtomicFileWriterError.destinationExists(path: destinationPath)
        case .ENOENT:
            // The source disappeared between the existence check and the rename.
            throw AtomicFileWriterError.fileMissing(path: sourcePath)
        case .EINVAL, .ENOSYS:
            // RENAME_EXCL unsupported on this filesystem; the pre-check above
            // already established the destination is absent.
            guard Darwin.rename(sourcePath, destinationPath) == 0 else {
                throw AtomicFileWriterError.renameFailed(
                    code: Self.currentPOSIXCode(), path: destinationPath)
            }
        default:
            throw AtomicFileWriterError.renameFailed(code: code, path: destinationPath)
        }
    }

    // MARK: - Delete

    /// Deletes the file at `target`. Plain delete — no trash/undo semantics at
    /// this layer. Deleting a missing file surfaces `.fileMissing`; every other
    /// failure (including deleting a directory) keeps its underlying errno —
    /// never a crash, never a silent success.
    public func delete(_ target: URL) throws {
        let path = target.path(percentEncoded: false)
        guard !path.isEmpty, !target.lastPathComponent.isEmpty else {
            throw AtomicFileWriterError.posixError(code: .EINVAL, operation: "delete", path: path)
        }
        if Darwin.unlink(path) == 0 { return }
        let code = Self.currentPOSIXCode()
        if code == .ENOENT {
            throw AtomicFileWriterError.fileMissing(path: path)
        }
        throw AtomicFileWriterError.posixError(code: code, operation: "unlink", path: path)
    }

    // MARK: - Filesystem helpers

    /// Fails with `.directoryMissing` when `path` does not exist or is not a
    /// directory (vault temporarily unavailable, PRD §18); other stat failures
    /// keep their underlying errno (e.g. traversal permission denied).
    private func requireDirectory(atPath path: String) throws {
        var status = stat()
        // NB: unqualified `stat` — the `Darwin.`-prefixed name resolves to the
        // struct, not the function.
        guard stat(path, &status) == 0 else {
            let code = Self.currentPOSIXCode()
            if code == .ENOENT {
                throw AtomicFileWriterError.directoryMissing(path: path)
            }
            throw AtomicFileWriterError.posixError(
                code: code, operation: "stat-directory", path: path)
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw AtomicFileWriterError.directoryMissing(path: path)
        }
    }

    /// Throws `.fileMissing` unless an entry (file, directory or dangling
    /// symlink) exists at `path`; other failures keep their errno.
    private func requireEntry(atPath path: String) throws {
        var status = stat()
        guard Darwin.lstat(path, &status) == 0 else {
            let code = Self.currentPOSIXCode()
            if code == .ENOENT {
                throw AtomicFileWriterError.fileMissing(path: path)
            }
            throw AtomicFileWriterError.posixError(code: code, operation: "lstat", path: path)
        }
    }

    /// `lstat`-based existence check (a dangling symlink counts as existing).
    private func entryExists(atPath path: String) -> Bool {
        var status = stat()
        return Darwin.lstat(path, &status) == 0
    }

    /// Best-effort removal of a failed write's temp file.
    private func cleanupTemp(atPath path: String) {
        _ = Darwin.unlink(path)
    }
}
