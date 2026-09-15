import AppKit

/// The shared expiry alarm of issues #33/#38: repeated system beeps (~1×/s)
/// plus the focus-back watch (`NSApplication.didBecomeActiveNotification`).
/// `AppModel` owns lifecycle dispatch: focus-session expiry enters the #22
/// modal, while break expiry logs and routes to session start.
///
/// # AppKit isolation (house pattern)
/// This is the alarm's ONE AppKit seam — the system beep (`NSSound.beep()`,
/// the Swift surface of AppKit's C `NSBeep`, which the apinotes hide from
/// Swift — see `init`), `NSApplication`'s
/// activation notification and the run-loop timer live here and nowhere else
/// (the main-window presentation precedent: AppKit usage is isolated to its
/// own file; `AppModel` stays AppKit-free and owns this controller instead).
/// The beep action and the app-active probe are injected closures, so tests
/// drive the whole state machine without touching AppKit: they count beeps
/// through the injected action and flip the probe's answer, and they deliver
/// the focus-back signal by posting
/// `NSApplication.didBecomeActiveNotification` themselves (selector-based
/// observers deliver synchronously on the posting thread — deterministic).
///
/// # Window-scene single-window note (issue #27 amendment)
/// The app has exactly one `Window`-scene window (plus the non-activating
/// mini panel), so "the app is focused" is exactly `NSApplication.isActive`:
/// there is no second window whose key status could diverge. Ordering the
/// main window out (mini mode) does not deactivate the app by itself, but a
/// mini-collapsed user working in another app IS unfocused — the alarm's
/// focus-back signal remains plain app activation (Dock click / Cmd-Tab /
/// clicking any app window), which is also what `FocusTrackerApp`'s
/// observable-driven sync needs to restore the main window for the modal.
///
/// # State machine (pinned, issue #33)
/// `stop()`/`start()` are the only transitions; `start()` is idempotent, so
/// repeated watcher ticks while the user ignores the alarm re-deliver
/// nothing (no beep restarts, no timer pile-up — the ONE repeating timer is
/// invalidated on `stop()`, and the notification observer is registered on
/// start and removed on stop, so nothing outlives the alarm: bounded
/// memory). `start()` beeps IMMEDIATELY (expiry just happened — waiting a
/// full second for the first beep would mute the alarm's onset) and then
/// every `beepInterval` seconds on the main run loop in `.common` mode (so
/// beeps survive modal/tracking run-loop modes while the sheet is up).
/// Becoming active while alarming is the focus-back event: the alarm stops
/// itself FIRST (the shake flag and the beeps end before any end-of-session
/// work runs) and then reports `onFocusBack` — the model's auto-end.
///
/// # Threading
/// `@MainActor` throughout. The repeating timer fires on the main run loop
/// (the block re-enters the actor via `MainActor.assumeIsolated` — the run
/// loop IS the main thread); `NSApplication` posts `didBecomeActive` on the
/// main thread. The controller is owned by the `@MainActor` `AppModel` and
/// only ever deallocated on the main actor; `deinit` still tears the timer
/// and observer down as a safety net so an armed alarm can never outlive its
/// owner (no runaway timers — the "loop survives a long unfocused stretch,
/// bounded memory" criterion).
///
/// `public` deliberately: it is an injectable seam of `AppModel`'s public
/// init (the `FocusSessionClock` / `ActiveSessionTickScheduler` precedent —
/// every seam the composition root takes is public for tests).
@MainActor
public final class ExpiryAlarmController: NSObject {

    /// The pinned beep cadence (issue #33: "~1×/s").
    public static let beepInterval: TimeInterval = 1.0

    /// The injected beep action (production: the system beep via
    /// `NSSound.beep()`; tests: a counter).
    private let beepAction: () -> Void
    /// The injected app-active probe (production: `NSApplication.shared
    /// .isActive`; tests: a mutable flag) — the "expiry while focused vs
    /// unfocused" decision input the model reads at expiry time.
    private let isAppActiveProvider: () -> Bool

    /// The one repeating beep timer; non-nil exactly while alarming.
    /// `nonisolated(unsafe)` ONLY for the deinit safety net: the owner is
    /// `@MainActor` and deallocates on the main actor, so the deinit
    /// invalidation below runs on the main thread like every other access.
    nonisolated(unsafe) private var beepTimer: Timer?

    /// Whether the alarm is currently running (beeps armed + focus-back
    /// watch registered). Drives `AppModel.isExpiryAlarmActive` through
    /// `onStateChange` — the shake animation's flag.
    public private(set) var isAlarming = false

    /// Delivered on start (true) and stop (false), on the main actor.
    public var onStateChange: ((Bool) -> Void)?
    /// Delivered exactly once per alarm, after the focus-back stop: the
    /// model's signal to finish whichever expired lifecycle armed the alarm.
    public var onFocusBack: (() -> Void)?

    /// - Parameters:
    /// - Parameters:
    ///   - beep: The beep action; defaults to the system beep. Note (pinned
    ///     intent, issue #33): the issue's "system beep via `NSBeep`" is the
    ///     AppKit system beep — in Swift the C `NSBeep` symbol is marked
    ///     SwiftPrivate in the SDK apinotes and cannot be named, so the
    ///     default uses `NSSound.beep()`, AppKit's Swift-facing wrapper of
    ///     the exact same system beep. No new dependency, no notification
    ///     permission.
    ///   - isAppActive: The app-focus probe; defaults to
    ///     `NSApplication.shared.isActive`.
    public init(
        beep: @escaping () -> Void = { NSSound.beep() },
        isAppActive: @escaping () -> Bool = { NSApplication.shared.isActive }
    ) {
        self.beepAction = beep
        self.isAppActiveProvider = isAppActive
        super.init()
    }

    /// Whether the app is currently active (focused) — the model's decision
    /// input at expiry: focused → straight to auto-end, unfocused → alarm.
    public var isAppActive: Bool { isAppActiveProvider() }

    /// Starts the alarm (idempotent): immediate first beep, the repeating
    /// ~1 s beep timer on the main run loop's `.common` mode, and the
    /// focus-back observer. Deliver `onStateChange(true)` first so the
    /// shake flag flips before the first beep.
    public func start() {
        guard !isAlarming else { return }
        isAlarming = true
        onStateChange?(true)
        beepAction()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        let timer = Timer(timeInterval: Self.beepInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.beepAction() }
        }
        RunLoop.main.add(timer, forMode: .common)
        beepTimer = timer
    }

    /// Stops the alarm (idempotent): the timer is invalidated (no further
    /// beeps), the observer removed (no further focus-back deliveries) and
    /// `onStateChange(false)` ends the shake flag.
    public func stop() {
        guard isAlarming else { return }
        isAlarming = false
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didBecomeActiveNotification, object: nil)
        beepTimer?.invalidate()
        beepTimer = nil
        onStateChange?(false)
    }

    /// The focus-back event (selector-based observer — synchronous delivery
    /// on the posting thread, which AppKit guarantees is main): stops the
    /// alarm first, then reports the focus-back so the model's auto-end
    /// runs with the alarm already down.
    @objc private func handleDidBecomeActive() {
        guard isAlarming else { return }
        stop()
        onFocusBack?()
    }

    deinit {
        // Safety net only: the owner is @MainActor and deallocates on the
        // main actor. A leaked armed alarm must not keep a run-loop timer
        // or a notification observer alive (no runaway memory).
        beepTimer?.invalidate()
        beepTimer = nil
        NotificationCenter.default.removeObserver(self)
    }
}
