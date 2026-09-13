import SwiftUI

/// The first-launch onboarding screen (issue #26, PRD §5.1–§5.2): replaces
/// the #15 `notConfiguredView` placeholder inside `TasksView` — the vault
/// state is `.notConfigured`, so nothing can write anywhere yet.
///
/// # The two options (clearly separated, pinned)
/// - **Create New Vault** (default, prominent): a location picker selects
///   the **PARENT** folder only — the app itself creates `<parent>/<name>/`
///   with its `Tasks/` + `Logs/` structure through
///   `AppModel.createVault(parentURL:name:)`'s pinned matrix (the panel
///   must not create the vault folder). The name field is pre-filled with
///   `Focus Tracker` (editable); the live sanitization rule
///   (`VaultFolderNameSanitizer`) disables Create and surfaces the typed
///   empty-name error inline.
/// - **Choose Existing Vault…**: the previous folder-picker behavior,
///   preserved — with the pinned **onboarding-level pre-check**: the pure
///   `VaultStructureValidator` runs BEFORE any `setVaultPath`. A valid
///   folder is used as-is via `setVaultPath(to:)` exactly as today; a
///   folder with missing structure shows the explicit consent UI
///   (**Scaffold missing folders** / **Cancel**) — nothing is modified
///   before consent, and cancel leaves disk, settings and state untouched;
///   a `.nameCollision` is a typed inline error with no scaffold offer.
///
/// # Inline typed errors (the #19 sheet precedent — never alert-only)
/// Every user-decision failure surfaces inline from its typed outcome:
/// empty-after-sanitize name, `.nameCollision`, the structure-mismatch
/// consent affordance, and the (defensive, unreachable from onboarding)
/// session-active refusals. Non-decision I/O failures surface through
/// their localized description, same as #19.
struct OnboardingView: View {

    /// The composition root — `createVault(parentURL:name:)`,
    /// `selectExistingVault(at:scaffoldMissingWithConsent:)` and
    /// `setVaultPath(to:)` are the pinned paths.
    let model: AppModel

    /// The pinned pre-filled vault name (issue #26).
    private static let defaultVaultName = "Focus Tracker"

    // MARK: - State

    /// Create New Vault: the chosen PARENT folder (nil until picked).
    @State private var parentURL: URL?
    /// Create New Vault: the editable vault folder name (pre-filled).
    @State private var vaultName = OnboardingView.defaultVaultName
    /// Choose Existing Vault: the folder awaiting the scaffold consent
    /// (shown only when the pre-check found missing structure — a valid
    /// folder applies immediately, a collision shows the typed error).
    @State private var consentRequest: ConsentRequest?
    /// The inline typed-error surface (the #19 `inlineMessage` pattern).
    @State private var inlineError: String?
    /// The typed-cancelled confirmation (consent declined — nothing was
    /// changed).
    @State private var cancelNotice = false
    /// Guards the buttons while a model operation is in flight.
    @State private var isWorking = false

    /// The pending scaffold-consent decision (pure data — view-local; the
    /// model re-validates on apply).
    private struct ConsentRequest {
        let url: URL
        let missing: VaultStructureValidator.ValidationOutcome
    }

    // MARK: - Derived state

    /// The create-path sanitization, evaluated live: nil = the name
    /// sanitizes to empty (typed `emptyAfterSanitize` rule) — Create
    /// disabled plus the inline error.
    private var sanitizedVaultName: String? {
        try? VaultFolderNameSanitizer.sanitize(vaultName)
    }

    private var canCreate: Bool {
        parentURL != nil && sanitizedVaultName != nil && !isWorking
    }

    private static let refusalMessage =
        "A session is active — finish or end it before changing the vault."

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.spacingL) {
                header
                Rectangle()
                    .fill(DesignTokens.divider)
                    .frame(height: 1)
                createSection
                Rectangle()
                    .fill(DesignTokens.divider)
                    .frame(height: 1)
                existingSection
                inlineMessages
            }
            .padding(DesignTokens.spacingL)
            .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.background)
    }

    private var header: some View {
        VStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "tray")
                .font(.system(size: DesignTokens.emptyStateIconSize))
                .foregroundStyle(.secondary)
            Text("Focus Tracker")
                .font(DesignTokens.titleFont)
            Text(
                "Your tasks and focus logs live in a vault — a plain folder "
                    + "of Markdown files. Create a new vault, or point the "
                    + "app at an existing one.")
                .font(DesignTokens.bodyFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Create New Vault (default, prominent)

    private var createSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            Text("Create a new vault")
                .font(DesignTokens.sectionFont)
            Text(
                "Pick a location — the app creates the vault folder with "
                    + "its Tasks/ and Logs/ structure inside it. Existing "
                    + "content is never overwritten.")
                .font(DesignTokens.annotationFont)
                .foregroundStyle(.secondary)
            HStack(spacing: DesignTokens.spacingS) {
                Button {
                    pickParentLocation()
                } label: {
                    Label("Choose location…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
                if let parentURL {
                    Text(parentURL.path(percentEncoded: false))
                        .font(DesignTokens.annotationFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
                TextField("Vault name", text: $vaultName)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.bodyFont)
                if sanitizedVaultName == nil {
                    Text("The vault name cannot be empty.")
                        .font(DesignTokens.annotationFont)
                        .foregroundStyle(DesignTokens.warning)
                }
            }
            Button {
                createVault()
            } label: {
                Label("Create Vault", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCreate)
            .help("Creates <location>/<name> with Tasks/ and Logs/ inside")
        }
    }

    // MARK: - Choose Existing Vault

    private var existingSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            Text("Use an existing vault")
                .font(DesignTokens.sectionFont)
            Text(
                "Choose a folder that contains Tasks/ and Logs/ — or one "
                    + "where they can be scaffolded with your consent.")
                .font(DesignTokens.annotationFont)
                .foregroundStyle(.secondary)
            Button("Choose Existing Vault…") {
                pickExistingVault()
            }
            .buttonStyle(.bordered)
            .disabled(isWorking)
            if let request = consentRequest {
                consentView(request)
            }
        }
    }

    /// The explicit consent UI for a structure-mismatch pre-check (pinned:
    /// consent is required before ANY modification; nothing was touched by
    /// the pre-check itself).
    private func consentView(_ request: ConsentRequest) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            Text(
                "“\(request.url.lastPathComponent)” is missing "
                    + Self.missingFoldersDescription(request.missing) + ".")
                .font(DesignTokens.bodyFont)
            Text(
                "Scaffold the missing folders in place? Existing content is "
                    + "never touched.")
                .font(DesignTokens.annotationFont)
                .foregroundStyle(.secondary)
            HStack(spacing: DesignTokens.spacingS) {
                Button("Scaffold missing folders") {
                    consentScaffold(request)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
                Button("Cancel", role: .cancel) {
                    consentCancel(request)
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
            }
        }
        .padding(DesignTokens.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bannerBackground)
        .cornerRadius(DesignTokens.cornerRadius)
    }

    /// The inline error + typed-cancel surfaces (the #19 precedent).
    private var inlineMessages: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            if let inlineError {
                Text(inlineError)
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(DesignTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if cancelNotice {
                Text("Cancelled — nothing was changed.")
                    .font(DesignTokens.annotationFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    /// The Create New Vault parent picker: selects the PARENT only — the
    /// app creates `<parent>/<name>/` itself through the pinned matrix.
    private func pickParentLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // The user may create or pick the parent folder; the vault folder
        // itself is the app's job (pinned — the panel must not create it).
        panel.canCreateDirectories = true
        panel.message =
            "Choose the folder to create “"
            + (sanitizedVaultName ?? vaultName) + "” inside."
        panel.prompt = "Choose location"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        parentURL = url
        inlineError = nil
        cancelNotice = false
    }

    private func createVault() {
        guard let parentURL, canCreate else { return }
        inlineError = nil
        cancelNotice = false
        isWorking = true
        Task {
            do {
                let outcome = try await model.createVault(
                    parentURL: parentURL, name: vaultName)
                switch outcome {
                case .created, .scaffolded, .usedExisting:
                    break // the vault state flips to .loaded; TasksView swaps
                case .nameCollision(let url):
                    inlineError =
                        "Cannot create the vault: a file already exists at "
                        + "“\(url.path(percentEncoded: false))” or in place "
                        + "of its Tasks/ or Logs/ folder. Nothing was changed."
                case .refusedWhileSessionActive:
                    inlineError = Self.refusalMessage
                }
            } catch is VaultFolderNameSanitizer.SanitizationError {
                // The typed empty-name rule (the field disables Create on
                // the same rule — this is the fail-closed backstop).
                inlineError = "The vault name cannot be empty."
            } catch {
                // Non-decision I/O failure — surfaced, never swallowed.
                inlineError = error.localizedDescription
            }
            isWorking = false
        }
    }

    /// The Choose Existing Vault picker + the pinned onboarding-level
    /// pre-check: the pure validator runs BEFORE any `setVaultPath` and
    /// decides the branch. The degraded-state re-selection flow elsewhere
    /// in `TasksView` keeps its current behavior (out of scope).
    private func pickExistingVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose the vault folder that contains Tasks/ and Logs/."
        panel.prompt = "Choose vault"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        inlineError = nil
        cancelNotice = false
        consentRequest = nil

        // The onboarding-level pre-check (pinned, read-only).
        let validation = VaultStructureValidator.validate(at: url)
        switch validation {
        case .valid:
            // The frictionless case: used as-is via setVaultPath exactly as
            // today (issue #14's .changed semantics) — no consent needed.
            isWorking = true
            Task {
                let outcome = await model.setVaultPath(to: url)
                if case .refusedWhileSessionActive = outcome {
                    inlineError = Self.refusalMessage
                }
                isWorking = false
            }
        case .missingTasks, .missingLogs, .bothMissing:
            // Typed structure mismatch: explicit consent UI before ANY
            // modification.
            consentRequest = ConsentRequest(url: url, missing: validation)
        case .nameCollision:
            // Typed inline error; nothing modified; no scaffold offer.
            inlineError =
                "“\(url.lastPathComponent)” has a file where its Tasks/ or "
                + "Logs/ folder should be. Nothing was changed."
        }
    }

    /// The consent path: scaffold ONLY the missing directories (the same
    /// helper as the create path), then store the path like a normal
    /// selection.
    private func consentScaffold(_ request: ConsentRequest) {
        consentRequest = nil
        inlineError = nil
        isWorking = true
        Task {
            do {
                let outcome = try await model.selectExistingVault(
                    at: request.url, scaffoldMissingWithConsent: true)
                switch outcome {
                case .scaffolded, .selected:
                    break // done — the vault state flips to .loaded
                case .cancelled:
                    cancelNotice = true
                case .nameCollision(let url):
                    inlineError =
                        "“\(url.lastPathComponent)” has a file where its "
                        + "Tasks/ or Logs/ folder should be. Nothing was "
                        + "changed."
                case .refusedWhileSessionActive:
                    inlineError = Self.refusalMessage
                }
            } catch {
                // Non-decision I/O failure — surfaced, never swallowed; the
                // path was not stored.
                inlineError = error.localizedDescription
            }
            isWorking = false
        }
    }

    /// The typed cancelled path: nothing on disk modified, path NOT stored,
    /// the app stays `.notConfigured` — confirmed by the model's outcome.
    private func consentCancel(_ request: ConsentRequest) {
        consentRequest = nil
        inlineError = nil
        Task {
            if case .cancelled = (try? await model.selectExistingVault(
                at: request.url, scaffoldMissingWithConsent: false))
            {
                cancelNotice = true
            }
        }
    }

    // MARK: - Message helpers

    private static func missingFoldersDescription(
        _ outcome: VaultStructureValidator.ValidationOutcome
    ) -> String {
        switch outcome {
        case .missingTasks: "its Tasks/ folder"
        case .missingLogs: "its Logs/ folder"
        case .bothMissing: "its Tasks/ and Logs/ folders"
        case .valid, .nameCollision:
            // Unreachable from the consent UI (only mismatch pre-checks
            // open it); fail toward the honest empty description.
            "anything"
        }
    }
}
