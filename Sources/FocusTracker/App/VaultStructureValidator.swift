import Foundation

/// Vault-structure validation and scaffolding for first-run onboarding
/// (issue #26, PRD §5.1–§5.2, §18): the pure classification of a directory
/// against the canonical vault structure (`Tasks/` AND `Logs/`, both
/// directories) plus the ONE scaffolding implementation shared by the
/// create path and the choose-existing consent flow.
///
/// # Placement (engineer's choice, documented)
/// These helpers live in `App/`, not `Vault/`: they encode the
/// *onboarding/AppModel-level* structure policy pinned by issue #26 —
/// "the structure pre-check lives at the onboarding/AppModel level;
/// `VaultStore` is consumed, not changed" — while `Vault/` stays the
/// store's persistence layer (the store keeps tolerating missing dirs
/// gracefully per #6). The canonical directory names (`Tasks`, `Logs`)
/// mirror `VaultStore`'s layout rules without touching it.
///
/// # Pure classification (pinned rules, issue #26)
/// The vault root is **valid iff `Tasks/` AND `Logs/` both exist as
/// DIRECTORIES**. Extra content — `.obsidian/`, stray files, anything else
/// Obsidian-owned — is irrelevant and tolerated. A non-directory entry
/// occupying a would-be folder path (`Tasks` or `Logs` occupied by a file)
/// is a `.nameCollision`. Pinned precedence: **any collision wins over the
/// missing cases** (e.g. `Tasks` occupied by a file while `Logs/` is
/// missing classifies as `.nameCollision`, not a mix) — this is what makes
/// collision detection precede any mkdir on the create path. The outcome
/// is typed and `Equatable` (house style).
public enum VaultStructureValidator {

    /// The typed classification of a directory against the canonical vault
    /// structure (issue #26; `Equatable` for exact-case assertions).
    public enum ValidationOutcome: Equatable, Sendable {
        /// `Tasks/` and `Logs/` both exist as directories (extra content
        /// tolerated).
        case valid
        /// Only `Tasks/` is missing (`Logs/` exists as a directory).
        case missingTasks
        /// Only `Logs/` is missing (`Tasks/` exists as a directory).
        case missingLogs
        /// Both `Tasks/` and `Logs/` are missing (including a root that
        /// does not exist at all — nothing is present, so both are).
        case bothMissing
        /// A non-directory entry occupies a would-be folder path (`Tasks`
        /// or `Logs` is a file). Pinned precedence: wins over every
        /// missing case.
        case nameCollision
    }

    /// The directories the app owns inside a vault (PRD §5.2) — the exact
    /// names `VaultStore` reads (`Tasks/`) and `DailyLogStore` writes
    /// (`Logs/`).
    private static let structureDirectoryNames = ["Tasks", "Logs"]

    /// Classifies the directory at `vaultURL` (pure: reads nothing but
    /// entry existence/kind, writes nothing, deterministic).
    ///
    /// The existence probes deliberately use paths WITHOUT the
    /// directory-annotated trailing slash: `stat("…/Tasks/")` fails with
    /// ENOTDIR when `Tasks` is a regular **file**, which would misreport
    /// the pinned `.nameCollision` case as missing — the exact distinction
    /// this validator exists to make.
    public static func validate(at vaultURL: URL) -> ValidationOutcome {
        let states = structureDirectoryNames.map {
            entryState(of: vaultURL.appendingPathComponent($0))
        }
        // Pinned precedence first: any collision wins over the missing
        // cases, so a file occupying `Tasks` while `Logs/` is missing is
        // `.nameCollision` — the create path must not scaffold around it.
        if states.contains(.occupiedByNonDirectory) { return .nameCollision }
        switch (states[0], states[1]) {
        case (.directory, .directory): return .valid
        case (.missing, .directory): return .missingTasks
        case (.directory, .missing): return .missingLogs
        case (.missing, .missing): return .bothMissing
        case (.occupiedByNonDirectory, _), (_, .occupiedByNonDirectory):
            // Unreachable (handled above); fail toward the honest case.
            return .nameCollision
        }
    }

    /// The existence state of one would-be structure directory.
    private enum EntryState {
        case directory
        case missing
        case occupiedByNonDirectory
    }

    private static func entryState(of url: URL) -> EntryState {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        else {
            return .missing
        }
        return isDirectory.boolValue ? .directory : .occupiedByNonDirectory
    }
}

/// The ONE scaffolding implementation for issue #26 (shared by the create
/// path's missing-structure cell and the choose-existing consent flow):
/// creates **ONLY** the directories the given validation outcome names as
/// missing — an explicit create operation; existing content is never
/// touched, and nothing Obsidian-owned (`.obsidian/`) is created.
///
/// Directory creation uses `withIntermediateDirectories: false`, so a
/// missing (or non-directory) vault root fails here instead of silently
/// creating unexpected parents — the fresh-create path creates the root
/// explicitly first. A mid-scaffold I/O failure (e.g. permissions) is not
/// transactional: directories already created stay, the caller stores no
/// path, and a retry re-validates and finishes the job.
public enum VaultScaffolder {

    /// Creates the missing structure directories named by `validation`.
    /// `.valid` and `.nameCollision` scaffold nothing (typed no-ops — the
    /// caller never passes them, but the helper fails closed rather than
    /// guessing).
    public static func scaffoldMissingDirectories(
        at vaultURL: URL, validation: VaultStructureValidator.ValidationOutcome
    ) throws {
        let tasksDirectory = vaultURL.appendingPathComponent("Tasks", isDirectory: true)
        let logsDirectory = vaultURL.appendingPathComponent("Logs", isDirectory: true)
        switch validation {
        case .missingTasks:
            try makeDirectory(at: tasksDirectory)
        case .missingLogs:
            try makeDirectory(at: logsDirectory)
        case .bothMissing:
            try makeDirectory(at: tasksDirectory)
            try makeDirectory(at: logsDirectory)
        case .valid, .nameCollision:
            break
        }
    }

    /// Creates the vault root itself — the fresh-create cell's explicit
    /// first step (`<parent>/<name>` is absent; the panel only ever
    /// provided the parent). Intermediate directories are allowed so a
    /// freshly chosen nested parent works; the vault's own structure
    /// directories are NOT created here (that is
    /// `scaffoldMissingDirectories(at:validation:)` with `.bothMissing`).
    public static func createRoot(at vaultURL: URL) throws {
        try FileManager.default.createDirectory(
            at: vaultURL, withIntermediateDirectories: true)
    }

    private static func makeDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false)
    }
}
