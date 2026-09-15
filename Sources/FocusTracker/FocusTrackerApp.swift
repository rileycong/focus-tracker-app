import SwiftUI

@main
struct FocusTrackerApp: App {
    @State private var model: AppModel
    @State private var windowPresentation: MainWindowPresentationController

    init() {
        let settings: AppSettings
        do {
            settings = try AppSettings(suiteName: AppSettings.defaultSuiteName)
        } catch {
            settings = AppSettings(defaults: .standard)
        }
        _model = State(initialValue: AppModel(settings: settings))
        _windowPresentation = State(initialValue: MainWindowPresentationController())
    }

    var body: some Scene {
        // A `Window`, rather than `WindowGroup`, preserves the app's
        // single-window contract. Compact mode reconfigures this same window.
        Window("Focus Tracker", id: "main") {
            Group {
                switch model.appPhase {
                case .tasksView:
                    TasksView(model: model)
                case .timerView(let context):
                    if model.isMiniTimerActive {
                        MiniTimerView(context: context, model: model)
                    } else {
                        TimerView(context: context, model: model)
                    }
                case .endingSession(let result, _, let context):
                    TimerView(context: context, model: model)
                        .sheet(isPresented: .constant(true)) {
                            EndOfSessionModalView(
                                result: result, context: context, model: model)
                                .interactiveDismissDisabled(true)
                        }
                case .postSessionChoice(let completionFailure):
                    PostSessionChoiceView(
                        model: model, completionFailure: completionFailure)
                case .breakActive:
                    BreakView(model: model)
                case .sessionStart:
                    TasksView(model: model)
                        .sheet(isPresented: .constant(true)) {
                            SessionStartView(
                                tasks: model.tasks,
                                knownCategoryNames: TaskFormState
                                    .knownCategoryNames(in: model.tasks),
                                preselectedTargetID: model.lastSessionTargetID,
                                onStart: { taskID, duration in
                                    try await model.startSession(
                                        taskID: taskID, duration: duration)
                                },
                                onStartAdHoc: { title, categoryNames, duration in
                                    try await model.startAdHocSession(
                                        title: title,
                                        categoryNames: categoryNames,
                                        duration: duration)
                                },
                                onCancel: { model.cancelSessionStart() })
                        }
                case .recoveryPrompt(let snapshot, let context):
                    TasksView(model: model)
                        .sheet(isPresented: .constant(true)) {
                            RecoveryPromptView(
                                snapshot: snapshot, context: context, model: model)
                                .interactiveDismissDisabled(true)
                        }
                }
            }
            .overlay(alignment: .bottom) {
                if let warning = model.pendingBreakLogWarning {
                    Text(warning)
                        .font(DesignTokens.annotationFont)
                        .foregroundStyle(DesignTokens.warning)
                        .padding(.horizontal, DesignTokens.spacingM)
                        .padding(.vertical, DesignTokens.spacingS)
                        .background(DesignTokens.bannerBackground)
                        .cornerRadius(DesignTokens.cornerRadius)
                        .padding(.bottom, DesignTokens.spacingM)
                        .transition(.opacity)
                }
            }
            .frame(
                minWidth: model.isMiniTimerActive
                    ? MiniTimerWindowLayout.contentMinSize.width : 640,
                idealWidth: model.isMiniTimerActive
                    ? MiniTimerWindowLayout.contentSize.width : nil,
                maxWidth: model.isMiniTimerActive
                    ? MiniTimerWindowLayout.contentMaxSize.width : nil,
                minHeight: model.isMiniTimerActive
                    ? MiniTimerWindowLayout.contentMinSize.height : 420,
                idealHeight: model.isMiniTimerActive
                    ? MiniTimerWindowLayout.contentSize.height : nil,
                maxHeight: model.isMiniTimerActive
                    ? MiniTimerWindowLayout.contentMaxSize.height : nil)
            .background {
                MainWindowAccessor { window in
                    windowPresentation.attach(window)
                    syncWindowPresentation()
                }
            }
            .task { await model.bootstrap() }
            .onChange(of: model.appPhase) { _, _ in syncWindowPresentation() }
            .onChange(of: model.isMiniTimerActive) { _, _ in syncWindowPresentation() }
            .preferredColorScheme(.dark)
        }
    }

    private func syncWindowPresentation() {
        let compact = AppShellContent.resolve(
            phase: model.appPhase,
            isMiniTimerActive: model.isMiniTimerActive) == .miniTimer
        windowPresentation.setCompact(compact)
    }
}
