import Foundation

/// Errors surfaced by `AtomicFileWriter` (issue #5, PRD §18).
///
/// Every failure of the atomic writer is one of these cases; the underlying
/// POSIX errno is preserved (`EACCES` permission denied, `ENOSPC` disk full,
/// `ENOENT` missing entries, `EIO` I/O error, …) instead of being swallowed,
/// so callers can react to specific OS conditions. All cases are `Equatable`
/// (mirroring the codec's `FrontmatterError` conventions) so tests can assert
/// exact cases, and `Sendable` so errors can cross concurrency domains.
public enum AtomicFileWriterError: Error, Equatable, Sendable {
    /// The parent directory of the target does not exist or is not a directory —
    /// e.g. the vault is temporarily unavailable (PRD §18). Never a crash, never
    /// a retry loop; the caller catches and handles it.
    case directoryMissing(path: String)
    /// The entry a move or delete operates on does not exist. For delete this
    /// includes deleting an already-missing file: never a silent success.
    case fileMissing(path: String)
    /// A move's destination already exists (file, directory or dangling symlink).
    /// The writer never overwrites silently and never resolves the conflict —
    /// the caller decides what to do.
    case destinationExists(path: String)
    /// The publishing (or fallback) rename failed; `code` is the underlying
    /// errno. The target is untouched — a failed rename happens whole or not
    /// at all.
    case renameFailed(code: POSIXErrorCode, path: String)
    /// `.strict` durability: fsyncing the parent directory after a successful
    /// rename failed with something other than unsupported-`EINVAL` (which is
    /// deliberately ignored). The rename itself already succeeded, so the
    /// target holds the *new* content when this error surfaces.
    case directorySyncFailed(code: POSIXErrorCode, path: String)
    /// Any other underlying POSIX failure while performing `operation` on
    /// `path` (create/write/fsync/close/unlink/stat), with the errno preserved.
    case posixError(code: POSIXErrorCode, operation: String, path: String)
}
