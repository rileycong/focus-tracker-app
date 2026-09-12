import AppKit
import SwiftUI

/// Pure layout math for the mini timer panel (issue #21, PRD §11):
/// extracted from `MiniTimerPanelController` so the default positioning is
/// unit-testable without instantiating any AppKit window (the honest-AppKit
/// test split, issue criterion 6). Plain CoreGraphics geometry — no AppKit
/// dependency, no state.
enum MiniTimerPanelLayout {

    /// The panel's fixed content size — small and calm (PRD §21): room for
    /// title, countdown, session-number line and the control row, nothing
    /// more (the §11 pinned do-not-show list keeps it this small).
    static let contentSize = CGSize(width: 260, height: 112)

    /// The inset from the visible frame's top-right corner (PRD §11
    /// "top-right-ish by default"; the user can drag it anywhere afterwards).
    static let screenMargin: CGFloat = 16

    /// The default top-right frame for the mini panel, computed against a
    /// screen's `visibleFrame` (menu bar/Dock excluded) in AppKit's
    /// bottom-left-origin coordinates. The frame is clamped to stay fully
    /// inside the visible frame on small screens (the margin wins over the
    /// top-right alignment there), and always carries exactly `contentSize`.
    static func defaultTopRightFrame(
        visibleFrame: CGRect,
        contentSize: CGSize = Self.contentSize,
        margin: CGFloat = Self.screenMargin
    ) -> CGRect {
        let x = max(
            visibleFrame.minX + margin,
            visibleFrame.maxX - contentSize.width - margin)
        let y = max(
            visibleFrame.minY + margin,
            visibleFrame.maxY - contentSize.height - margin)
        return CGRect(origin: CGPoint(x: x, y: y), size: contentSize)
    }
}

/// The always-on-top mini timer panel (issue #21, PRD §11, §10.2) — **the
/// one file allowed to import AppKit** (kept isolated from the SwiftUI
/// views, which stay AppKit-free). A borderless, non-activating `NSPanel`
/// hosting `MiniTimerView` via `NSHostingView`.
///
/// # Pinned panel configuration (issue #21 criterion 1)
/// `styleMask = [.borderless, .nonactivatingPanel]` (non-activating: showing
/// it never activates the app), `level = .floating` (always on top by
/// default), `isOpaque = false` + clear background (the SwiftUI rounded-rect
/// in `MiniTimerView` draws the visible shape, so the corners are truly
/// transparent), `collectionBehavior = [.canJoinAllSpaces,
/// .fullScreenAuxiliary]` (visible across Spaces and over full-screen apps),
/// `hidesOnDeactivate = false` (overridden from NSPanel's default — the mini
/// timer's whole point is to stay visible while the user works in *other*
/// apps), and `isMovableByWindowBackground = true` (borderless panels don't
/// drag by default; background drags move the window — the documented
/// draggability mechanism; no position persistence, issue criterion 5).
///
/// # Pinned show call (issue #21 criterion 1 — must not steal focus)
/// The panel is shown with exactly `panel.makeKeyAndOrderFront(nil)` and
/// nothing else: on a `.borderless` `NSPanel`, `canBecomeKey` is `false` by
/// default, so this orders the panel front **without a key round-trip** and
/// without activating the app — the user's typing keeps going to whatever
/// app had it. There is deliberately no `NSApp.activate(…)` and no
/// `makeKey()` anywhere on the show path.
///
/// # Lifecycle (issue #21 criterion 5, pinned)
/// The panel **only exists while a session is active**: `show(context:)`
/// creates it lazily and `dismiss()` tears it down completely (`orderOut` +
/// content release + nil). The driving logic lives in `FocusTrackerApp`'s
/// sync (the observable `AppModel.isMiniTimerActive` / `appPhase`), so the
/// panel closes on a session end **by any path** (End from mini, End from
/// full after restore, and #22's future flow — all funnel through
/// `AppModel.endSession()`, which clears the mini flag). There is **no
/// persistence of mini state**: the app quitting takes the panel with it,
/// and a relaunch defaults to the full view (the #14 recovery flow
/// resurfaces a pending session in the full window, as already built).
///
/// # Honest AppKit test reality (issue #21 criterion 6)
/// The actual floating/always-on-top/non-activating behavior of a real
/// `NSPanel` is not unit-testable; the suite covers everything around it
/// (the pure frame math here, and the `AppModel` mini-mode transitions).
/// Manual verification of the real floating/focus behavior is deferred to
/// the #24/#25 end-to-end verification passes.
@MainActor
final class MiniTimerPanelController {

    private let model: AppModel

    /// The live panel; `nil` exactly while no mini panel exists (created on
    /// `show`, fully torn down on `dismiss` — see the lifecycle contract
    /// above).
    private var panel: NSPanel?

    init(model: AppModel) {
        self.model = model
    }

    /// Creates (or recreates) the panel hosting `MiniTimerView` for the
    /// running session's context and shows it without stealing focus (the
    /// pinned show call above). The session itself is untouched — timing
    /// keeps running through the same coordinator.
    func show(context: AppModel.SessionContext) {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        panel.contentView = NSHostingView(
            rootView: MiniTimerView(context: context, model: model))
        // PINNED show call (see the type documentation): order front with no
        // key/activate round-trip — a borderless NSPanel cannot become key,
        // so the user's keyboard focus stays where it was.
        panel.makeKeyAndOrderFront(nil)
    }

    /// Closes the panel completely: ordered out, content released, and the
    /// panel object torn down so nothing survives a session end.
    func dismiss() {
        guard let panel else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
    }

    // MARK: - Main-window swap helpers (issue #21 criterion 3)

    /// **Pinned choice (issue #21, documented): collapse uses
    /// `orderOut(_:)`, NOT `miniaturize(_:)`.** `orderOut` truly removes the
    /// main window from the screen and keeps the focus story clean — no
    /// Dock-miniaturization affordance left to click, and the mini panel
    /// itself is the single restore affordance. `miniaturize` was rejected
    /// because it keeps a Dock tile whose click would fight with the mini
    /// panel's own restore path.
    static func hideMainWindow() {
        mainWindow()?.orderOut(nil)
    }

    /// Restore (issue #21 criterion 3): orderFront the main window. The
    /// pinned mechanism is exactly `makeKeyAndOrderFront(nil)` — no forced
    /// app activation; macOS's standard first-click-activates behavior
    /// covers the user's next interaction with the restored window.
    static func showMainWindow() {
        mainWindow()?.makeKeyAndOrderFront(nil)
    }

    /// The app's main content window — the first window that is not an
    /// `NSPanel`. SwiftUI's `WindowGroup` window stays in `NSApp.windows`
    /// even while `orderOut`'d, so this finds it in every state the sync
    /// drives.
    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { !($0 is NSPanel) }
    }

    // MARK: - Panel construction

    private func makePanel() -> NSPanel {
        let frame = MiniTimerPanelLayout.defaultTopRightFrame(
            visibleFrame: NSScreen.main?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 1440, height: 900))
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Borderless panels don't drag by default (issue #21 criterion 1):
        // background drags move the window (documented above).
        panel.isMovableByWindowBackground = true
        // NSPanel defaults this to true, which would hide the mini timer
        // whenever the app deactivates — the opposite of its purpose.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}
