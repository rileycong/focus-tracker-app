import AppKit
import XCTest
@testable import FocusTracker

@MainActor
final class MiniTimerPresentationTests: XCTestCase {
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func makeNormalState() -> MainWindowPresentationState {
        MainWindowPresentationState(
            frame: CGRect(x: 180, y: 140, width: 860, height: 620),
            level: .normal,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            contentMinSize: CGSize(width: 640, height: 420),
            contentMaxSize: CGSize(width: 1600, height: 1200),
            collectionBehavior: [.managed],
            titleVisibility: .visible,
            titlebarAppearsTransparent: false,
            isMovableByWindowBackground: false,
            isOpaque: true,
            backgroundColor: .windowBackgroundColor,
            hasShadow: true)
    }

    private func makeWindow(from state: MainWindowPresentationState) -> NSWindow {
        let window = NSWindow(
            contentRect: state.frame,
            styleMask: state.styleMask,
            backing: .buffered,
            defer: false)
        window.level = state.level
        window.contentMinSize = state.contentMinSize
        window.contentMaxSize = state.contentMaxSize
        window.collectionBehavior = state.collectionBehavior
        window.titleVisibility = state.titleVisibility
        window.titlebarAppearsTransparent = state.titlebarAppearsTransparent
        window.isMovableByWindowBackground = state.isMovableByWindowBackground
        window.isOpaque = state.isOpaque
        window.backgroundColor = state.backgroundColor
        window.hasShadow = state.hasShadow
        window.setFrame(state.frame, display: false)
        return window
    }

    func testCollapseKeepsWindowOnScreenAndBuildsCompactPresentation() {
        let normal = makeNormalState()
        let transition = MainWindowCompactTransition.collapse(
            from: normal, visibleFrame: visibleFrame)

        XCTAssertEqual(transition.visibilityAction, .keepOnScreen)
        XCTAssertEqual(transition.normal, normal)
        XCTAssertEqual(
            transition.compact.frame,
            MiniTimerWindowLayout.defaultTopRightFrame(visibleFrame: visibleFrame))
        XCTAssertEqual(transition.compact.level, .floating)
        XCTAssertEqual(transition.compact.styleMask, [.borderless, .resizable])
        XCTAssertEqual(transition.compact.contentMinSize, CGSize(width: 220, height: 104))
        XCTAssertEqual(transition.compact.contentMaxSize, CGSize(width: 520, height: 240))
        XCTAssertTrue(transition.compact.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(transition.compact.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(transition.compact.isMovableByWindowBackground)
    }

    func testRestoreRecoversEveryCapturedPresentationProperty() {
        let normal = makeNormalState()
        let transition = MainWindowCompactTransition.collapse(
            from: normal, visibleFrame: visibleFrame)

        XCTAssertEqual(transition.normal, normal)
    }

    func testThreeCyclesAndDuplicateRequestsAreStableOnSameWindow() {
        let expected = makeNormalState()
        let window = makeWindow(from: expected)
        let identity = window.windowNumber
        let windowCount = NSApp.windows.count
        let controller = MainWindowPresentationController()
        controller.attach(window)

        for cycle in 1...3 {
            controller.setCompact(true)
            controller.setCompact(true)
            XCTAssertEqual(window.windowNumber, identity, "cycle \(cycle): identity")
            XCTAssertEqual(window.level, .floating, "cycle \(cycle): floating")
            XCTAssertFalse(window.isMiniaturized, "cycle \(cycle): never minimized")

            controller.setCompact(false)
            controller.setCompact(false)
            XCTAssertEqual(
                MainWindowPresentationState.capture(window), expected,
                "cycle \(cycle): exact restore")
        }

        XCTAssertEqual(NSApp.windows.count, windowCount, "no panel or second window created")
    }

    func testEndFromMiniRestoresNormalPresentation() {
        let expected = makeNormalState()
        let window = makeWindow(from: expected)
        let controller = MainWindowPresentationController()
        controller.attach(window)
        controller.setCompact(true)

        // End clears the model flag; the shell delivers the same explicit
        // non-compact request as Restore.
        controller.setCompact(false)

        XCTAssertEqual(MainWindowPresentationState.capture(window), expected)
    }

    func testShellMiniFlagSelectsMiniContentWithoutChangingPhase() {
        let context = AppModel.SessionContext(
            taskID: UUID(), title: "Task", parentTaskTitle: nil,
            project: nil, categories: [])
        let phase = AppModel.AppPhase.timerView(context)

        XCTAssertEqual(
            AppShellContent.resolve(phase: phase, isMiniTimerActive: false),
            .fullTimer)
        XCTAssertEqual(
            AppShellContent.resolve(phase: phase, isMiniTimerActive: true),
            .miniTimer)
        XCTAssertEqual(
            AppShellContent.resolve(phase: .tasksView, isMiniTimerActive: true),
            .other)
    }
}
