import AppKit
import SwiftUI

/// Pure layout math for the mini timer panel (issue #21, PRD §11):
/// extracted from `MiniTimerPanelController` so the default positioning is
/// unit-testable without instantiating any AppKit window (the honest-AppKit
/// test split, issue criterion 6). Plain CoreGraphics geometry — no AppKit
/// dependency, no state.
enum MiniTimerPanelLayout {

    /// The panel's default content size — small and calm (PRD §21): room for
    /// title, countdown, session-number line and the control row, nothing
    /// more (the §11 pinned do-not-show list keeps it this small). Since #28
    /// this is the *default* (relaunch) size, not a fixed one: the user can
    /// resize the panel within the bounds below, and every relaunch resets
    /// to this frame (no persistence, issue #28 criterion 5).
    static let contentSize = CGSize(width: 260, height: 112)

    /// The user-resizable lower bound (issue #28): the panel can never be
    /// collapsed below this. Pinned from measured layout facts, not guessed:
    /// - width: the control row (Pause + End + restore, `.controlSize(.small)`)
    ///   has an ideal width of 177pt; 220 − 2×14 padding leaves 192 — real
    ///   slack instead of button-label truncation.
    /// - height: at the helper's 22pt minimum countdown the laid-out stack
    ///   (title + countdown + session line + spacing + control row) needs
    ///   ≈101pt; 104 keeps everything inside the padded box. The issue's
    ///   200×80 suggestion was measured to actually clip the window edge
    ///   (the stack spills 17pt into the 14pt padding at 80pt height), so
    ///   the pinned min sits above that floor while respecting "min ≥ 200×80"
    ///   on both axes.
    static let contentMinSize = CGSize(width: 220, height: 104)

    /// The user-resizable upper bound (issue #28): "mini" stays mini — wide
    /// and tall enough for the full §11 content at a comfortably larger
    /// countdown, never a second full window (the issue's suggested ceiling).
    static let contentMaxSize = CGSize(width: 520, height: 240)

    /// Countdown digit size at the smallest resizable height (issue #28):
    /// the graceful small end of the scale (the base token size at the
    /// default size, growing to `countdownMaxFontSize` at the max size).
    static let countdownMinFontSize: CGFloat = 22

    /// Countdown digit size at `contentMaxSize` (issue #28): a calm step up,
    /// roughly proportional to the extra height, without becoming a display
    /// clock.
    static let countdownMaxFontSize: CGFloat = 44

    /// Clamps an arbitrary (user-resized) content size into the pinned
    /// `[contentMinSize, contentMaxSize]` envelope, per axis independently.
    /// Pure — the unit-tested mirror of the panel's `contentMinSize` /
    /// `contentMaxSize` enforcement (AppKit clamps live edge-drags; this
    /// helper pins the same logic for tests and for the view's font math).
    static func clampedContentSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, contentMinSize.width), contentMaxSize.width),
            height: min(max(size.height, contentMinSize.height), contentMaxSize.height))
    }

    /// The countdown digit size for a panel content size (issue #28):
    /// piecewise-linear on the (clamped) content height —
    /// `countdownMinFontSize` at `contentMinSize.height`, the #15 token base
    /// at the default `contentSize.height`, `countdownMaxFontSize` at
    /// `contentMaxSize.height`. Height-driven (the countdown is the panel's
    /// vertical anchor); width is deliberately ignored. Pure and unit-tested.
    static func countdownFontSize(forContentSize size: CGSize) -> CGFloat {
        let base = DesignTokens.miniCountdownSize
        let height = clampedContentSize(size).height
        if height <= contentSize.height {
            let shrinkSpan = contentSize.height - contentMinSize.height
            guard shrinkSpan > 0 else { return base }
            let t = min(max(contentSize.height - height, 0), shrinkSpan) / shrinkSpan
            return base - (base - countdownMinFontSize) * t
        }
        let growSpan = contentMaxSize.height - contentSize.height
        guard growSpan > 0 else { return base }
        let t = min(max(height - contentSize.height, 0), growSpan) / growSpan
        return base + (countdownMaxFontSize - base) * t
    }

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
/// # Pinned panel configuration (issue #21 criterion 1, amended by #28)
/// `styleMask = [.borderless, .nonactivatingPanel, .resizable]` — #28 adds
/// `.resizable` (user resize by dragging an edge/corner). Verified on the
/// real build (probe + the in-suite `MiniTimerPanelPropertyTests`): the
/// mask stays free of `.titled` (no title bar, no standard window buttons)
/// and `canBecomeKey` stays `false` — borderless panels cannot become key
/// with or without `.resizable`, so neither the borderless look nor the
/// non-activating show path changes. Remaining config unchanged:
/// `level = .floating` (always on top by default), `isOpaque = false` +
/// clear background (the SwiftUI rounded-rect in `MiniTimerView` draws the
/// visible shape, so the corners are truly transparent),
/// `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` (visible
/// across Spaces and over full-screen apps), `hidesOnDeactivate = false`
/// (overridden from NSPanel's default — the mini timer's whole point is to
/// stay visible while the user works in *other* apps), and
/// `isMovableByWindowBackground = true` (borderless panels don't drag by
/// default; background drags move the window).
///
/// # Resize + move coexistence (issue #28, criterion 1)
/// `.resizable` and `isMovableByWindowBackground` coexist by AppKit's
/// standard hit-testing: the window's outer frame edges/corners are resize
/// zones (drag edge = resize), everything inside them is window background
/// (drag body = move). The size range is enforced by
/// `contentMinSize`/`contentMaxSize` from the pure `MiniTimerPanelLayout`
/// clamp helpers. Honest deferral: the physical drag-body-vs-drag-edge feel
/// is a manual check, folded into #25's end-to-end pass (TCC-deferred).
///
/// # No frame persistence (issue #21 criterion 5, #28 criterion 5)
/// There is deliberately no reading or writing of the panel's frame: every
/// `show` presents the default top-right frame at the default 260×112
/// content size (`MiniTimerPanelLayout.defaultTopRightFrame`), and a
/// user-resized frame dies with the panel on `dismiss`/relaunch.
/// (`contentMinSize`/`contentMaxSize` clamp live user resizes only —
/// programmatic `setContentSize` bypasses them, which is why the pure
/// clamp helpers exist and are unit-tested.)
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
    ///
    /// #28: while the panel already exists (redundant sync deliveries while
    /// collapsed), the live contentView is kept, not rebuilt — the user's
    /// resized frame and the view's adaptive state survive; a rebuild only
    /// happens on a fresh panel (a fresh session context always follows a
    /// `dismiss`, so the content can never go stale).
    func show(context: AppModel.SessionContext) {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        if panel.contentView == nil {
            panel.contentView = NSHostingView(
                rootView: MiniTimerView(context: context, model: model))
        }
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
    /// `NSPanel`. The single-window `Window` scene (#27 amendment) keeps
    /// its one window in `NSApp.windows` even while `orderOut`'d, so this
    /// finds it in every state the sync drives.
    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { !($0 is NSPanel) }
    }

    // MARK: - Panel construction

    /// Builds the configured panel for a screen's visible frame. `static` +
    /// `internal` on purpose (issue #28): the property-level panel facts —
    /// styleMask, `canBecomeKey`, content-size bounds, movability — ARE
    /// unit-testable in-process (`MiniTimerPanelPropertyTests`), while the
    /// behavioral floating/focus/resize-drag parts stay #25's manual pass.
    static func makePanel(defaultVisibleFrame: CGRect) -> NSPanel {
        let frame = MiniTimerPanelLayout.defaultTopRightFrame(
            visibleFrame: defaultVisibleFrame)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Borderless panels don't drag by default (issue #21 criterion 1):
        // background drags move the window. Coexists with #28's `.resizable`
        // (drag body = move, drag edge = resize — see the type docs).
        panel.isMovableByWindowBackground = true
        // User-resizable range (issue #28): the pure clamp helpers' bounds,
        // enforced by AppKit on live edge-drags.
        panel.contentMinSize = MiniTimerPanelLayout.contentMinSize
        panel.contentMaxSize = MiniTimerPanelLayout.contentMaxSize
        // NSPanel defaults this to true, which would hide the mini timer
        // whenever the app deactivates — the opposite of its purpose.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func makePanel() -> NSPanel {
        Self.makePanel(
            defaultVisibleFrame: NSScreen.main?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 1440, height: 900))
    }
}
