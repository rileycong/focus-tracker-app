import AppKit
import Foundation

/// Real-app compact-mode lifecycle harness. Inert unless launched with
/// `-autoCollapseDemo`; defaults to three collapse/restore cycles.
@MainActor
enum AutoCollapseDemo {
    static let launchArgument = "-autoCollapseDemo"
    static let cyclesArgument = "-autoCollapseDemoCycles"
    static let logFileArgument = "-autoCollapseDemoLog"

    private static var logFile: FileHandle?
    private static var hasStarted = false

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static var cycleCount: Int {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: cyclesArgument),
            index + 1 < arguments.count,
            let count = Int(arguments[index + 1]), count >= 1
        else { return 3 }
        return count
    }

    static func runIfNeeded(model: AppModel) async {
        guard isEnabled, !hasStarted else { return }
        hasStarted = true
        openLogIfRequested()
        let identity = ObjectIdentifier(model)
        let initializations = AppModel.initializationCount
        let bootstraps = AppModel.bootstrapCount
        log("START model=\(identity) initializations=\(initializations) bootstraps=\(bootstraps)")

        await waitForVaultLoad(model)
        await ensureSessionStarted(model)
        try? await Task.sleep(for: .milliseconds(500))

        for cycle in 1...cycleCount {
            logState("cycle \(cycle) before collapse", model: model, identity: identity)
            model.collapseToMiniTimer()
            try? await Task.sleep(for: .seconds(1))
            logState("cycle \(cycle) compact", model: model, identity: identity)
            model.restoreFromMiniTimer()
            try? await Task.sleep(for: .seconds(1))
            logState("cycle \(cycle) restored", model: model, identity: identity)
        }

        let stable = ObjectIdentifier(model) == identity
            && AppModel.initializationCount == initializations
            && AppModel.bootstrapCount == bootstraps
            && !isRecoveryPrompt(model.appPhase)
        log("RESULT stable=\(stable) model=\(ObjectIdentifier(model)) initializations=\(AppModel.initializationCount) bootstraps=\(AppModel.bootstrapCount) recoveryPrompt=\(isRecoveryPrompt(model.appPhase))")
        finishSession(model)
        try? await Task.sleep(for: .milliseconds(300))
        NSApp.terminate(nil)
    }

    private static func waitForVaultLoad(_ model: AppModel) async {
        for _ in 0..<25 {
            if case .loaded = model.vaultState { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func ensureSessionStarted(_ model: AppModel) async {
        if model.pendingSessionRecovery != nil { model.discardPendingSession() }
        guard !model.isSessionActive else { return }
        if let task = model.tasks.first {
            _ = try? await model.startSession(taskID: task.id, duration: 3600)
        } else {
            _ = try? await model.startAdHocSession(
                title: "Compact lifecycle diagnostic",
                categoryNames: ["Diagnostic"], duration: 3600)
        }
    }

    private static func finishSession(_ model: AppModel) {
        guard case .timerView = model.appPhase, model.isSessionActive else { return }
        _ = try? model.endSession()
        model.discardEndOfSession()
    }

    private static func logState(
        _ label: String, model: AppModel, identity: ObjectIdentifier
    ) {
        let windows = NSApp.windows.map {
            "#\($0.windowNumber):style=\($0.styleMask.rawValue):frame=\($0.frame)"
                + ":layout=\($0.contentLayoutRect.size)"
                + ":level=\($0.level.rawValue)"
        }.joined(separator: ",")
        log("\(label) modelStable=\(ObjectIdentifier(model) == identity) initializations=\(AppModel.initializationCount) bootstraps=\(AppModel.bootstrapCount) recoveryPrompt=\(isRecoveryPrompt(model.appPhase)) windows=[\(windows)]")
    }

    private static func isRecoveryPrompt(_ phase: AppModel.AppPhase) -> Bool {
        if case .recoveryPrompt = phase { return true }
        return false
    }

    private static func openLogIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: logFileArgument),
            index + 1 < arguments.count
        else { return }
        let path = arguments[index + 1]
        FileManager.default.createFile(atPath: path, contents: nil)
        logFile = FileHandle(forWritingAtPath: path)
    }

    private static func log(_ message: String) {
        let data = Data("[auto-collapse-demo] \(message)\n".utf8)
        FileHandle.standardOutput.write(data)
        try? logFile?.write(contentsOf: data)
    }
}
