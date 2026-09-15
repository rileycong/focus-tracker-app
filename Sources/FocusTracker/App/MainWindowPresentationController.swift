import AppKit
import SwiftUI

enum MiniTimerWindowLayout {
    static let contentSize = CGSize(width: 260, height: 112)
    static let contentMinSize = CGSize(width: 220, height: 104)
    static let contentMaxSize = CGSize(width: 520, height: 240)
    static let countdownMinFontSize: CGFloat = 22
    static let countdownMaxFontSize: CGFloat = 44
    static let screenMargin: CGFloat = 16

    static func clampedContentSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, contentMinSize.width), contentMaxSize.width),
            height: min(max(size.height, contentMinSize.height), contentMaxSize.height))
    }

    static func countdownFontSize(forContentSize size: CGSize) -> CGFloat {
        let base = DesignTokens.miniCountdownSize
        let height = clampedContentSize(size).height
        if height <= contentSize.height {
            let span = contentSize.height - contentMinSize.height
            guard span > 0 else { return base }
            return base - (base - countdownMinFontSize)
                * ((contentSize.height - height) / span)
        }
        let span = contentMaxSize.height - contentSize.height
        guard span > 0 else { return base }
        return base + (countdownMaxFontSize - base)
            * ((height - contentSize.height) / span)
    }

    static func defaultTopRightFrame(
        visibleFrame: CGRect,
        contentSize: CGSize = Self.contentSize,
        margin: CGFloat = Self.screenMargin
    ) -> CGRect {
        CGRect(
            x: max(visibleFrame.minX + margin, visibleFrame.maxX - contentSize.width - margin),
            y: max(visibleFrame.minY + margin, visibleFrame.maxY - contentSize.height - margin),
            width: contentSize.width,
            height: contentSize.height)
    }
}

/// Every property changed for compact mode. Keeping this as value state makes
/// collapse/restore behavior testable without a second window or a panel.
struct MainWindowPresentationState: Equatable {
    var frame: CGRect
    var level: NSWindow.Level
    var styleMask: NSWindow.StyleMask
    var contentMinSize: CGSize
    var contentMaxSize: CGSize
    var collectionBehavior: NSWindow.CollectionBehavior
    var titleVisibility: NSWindow.TitleVisibility
    var titlebarAppearsTransparent: Bool
    var isMovableByWindowBackground: Bool
    var isOpaque: Bool
    var backgroundColor: NSColor
    var hasShadow: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.frame == rhs.frame
            && lhs.level == rhs.level
            && lhs.styleMask == rhs.styleMask
            && lhs.contentMinSize == rhs.contentMinSize
            && lhs.contentMaxSize == rhs.contentMaxSize
            && lhs.collectionBehavior == rhs.collectionBehavior
            && lhs.titleVisibility == rhs.titleVisibility
            && lhs.titlebarAppearsTransparent == rhs.titlebarAppearsTransparent
            && lhs.isMovableByWindowBackground == rhs.isMovableByWindowBackground
            && lhs.isOpaque == rhs.isOpaque
            && lhs.backgroundColor.isEqual(rhs.backgroundColor)
            && lhs.hasShadow == rhs.hasShadow
    }

    static func capture(_ window: NSWindow) -> Self {
        Self(
            frame: window.frame,
            level: window.level,
            styleMask: window.styleMask,
            contentMinSize: window.contentMinSize,
            contentMaxSize: window.contentMaxSize,
            collectionBehavior: window.collectionBehavior,
            titleVisibility: window.titleVisibility,
            titlebarAppearsTransparent: window.titlebarAppearsTransparent,
            isMovableByWindowBackground: window.isMovableByWindowBackground,
            isOpaque: window.isOpaque,
            backgroundColor: window.backgroundColor,
            hasShadow: window.hasShadow)
    }
}

enum MainWindowVisibilityAction: Equatable {
    case keepOnScreen
}

struct MainWindowCompactTransition: Equatable {
    let normal: MainWindowPresentationState
    let compact: MainWindowPresentationState
    let visibilityAction: MainWindowVisibilityAction

    static func collapse(
        from normal: MainWindowPresentationState,
        visibleFrame: CGRect
    ) -> Self {
        var compact = normal
        compact.frame = MiniTimerWindowLayout.defaultTopRightFrame(visibleFrame: visibleFrame)
        compact.level = .floating
        compact.styleMask = [.borderless, .resizable]
        compact.contentMinSize = MiniTimerWindowLayout.contentMinSize
        compact.contentMaxSize = MiniTimerWindowLayout.contentMaxSize
        compact.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        compact.titleVisibility = .hidden
        compact.titlebarAppearsTransparent = true
        compact.isMovableByWindowBackground = true
        compact.isOpaque = false
        compact.backgroundColor = .clear
        compact.hasShadow = true
        return Self(normal: normal, compact: compact, visibilityAction: .keepOnScreen)
    }
}

/// Reconfigures the existing SwiftUI scene window in place. No `NSPanel` or
/// other `NSWindow` is created. Unlike the old swap, this path never orders
/// out, miniaturizes, closes, or hides the app window. The reliability tradeoff
/// is deliberate: because compact mode is the main window, clicking it may
/// activate the app.
@MainActor
final class MainWindowPresentationController {
    private weak var window: NSWindow?
    private var normalPresentation: MainWindowPresentationState?
    private var compactRequested = false

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        normalPresentation = nil
        reconcile()
    }

    func setCompact(_ compact: Bool) {
        compactRequested = compact
        reconcile()
    }

    private func reconcile() {
        guard let window else { return }
        if compactRequested {
            guard normalPresentation == nil else { return }
            let normal = MainWindowPresentationState.capture(window)
            normalPresentation = normal
            let visibleFrame = window.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            apply(
                MainWindowCompactTransition.collapse(
                    from: normal, visibleFrame: visibleFrame).compact,
                to: window)
        } else if let normalPresentation {
            apply(normalPresentation, to: window)
            self.normalPresentation = nil
        }
    }

    private func apply(_ state: MainWindowPresentationState, to window: NSWindow) {
        window.styleMask = state.styleMask
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
        window.setFrame(state.frame, display: true)
    }
}

/// Resolves the scene-created window without owning or creating one.
struct MainWindowAccessor: NSViewRepresentable {
    let onResolve: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowObservationView {
        WindowObservationView(onResolve: onResolve)
    }

    func updateNSView(_ view: WindowObservationView, context: Context) {
        view.onResolve = onResolve
        view.resolve()
    }

    final class WindowObservationView: NSView {
        var onResolve: @MainActor (NSWindow) -> Void

        init(onResolve: @escaping @MainActor (NSWindow) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolve()
        }

        func resolve() {
            if let window { onResolve(window) }
        }
    }
}

enum AppShellContent: Equatable {
    case miniTimer
    case fullTimer
    case other

    static func resolve(phase: AppModel.AppPhase, isMiniTimerActive: Bool) -> Self {
        guard case .timerView = phase else { return .other }
        return isMiniTimerActive ? .miniTimer : .fullTimer
    }
}
