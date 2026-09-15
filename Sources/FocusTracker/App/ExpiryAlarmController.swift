import AppKit
import AVFoundation

/// Injectable media-output player used by the shared focus/break alarm.
/// Production uses `AVAudioPlayer`; tests provide a hardware-free spy.
@MainActor
public protocol ExpiryAlarmPlaying: AnyObject {
    func play() throws
    func stop()
}

public enum ExpiryAlarmPlayerError: Error {
    case playbackFailed
}

/// One bounded `AVAudioPlayer` backed by a deterministic in-memory WAV. Media
/// output is intentionally used instead of the often-muted system alert
/// channel. No package, generated file, or notification permission is needed.
@MainActor
public final class AVAudioExpiryAlarmPlayer: ExpiryAlarmPlaying {
    private var player: AVAudioPlayer?

    public init() {}

    public func play() throws {
        let player: AVAudioPlayer
        if let existing = self.player {
            player = existing
        } else {
            let created = try AVAudioPlayer(data: Self.beepWAV())
            created.volume = 0.8
            created.prepareToPlay()
            self.player = created
            player = created
        }
        player.currentTime = 0
        guard player.play() else { throw ExpiryAlarmPlayerError.playbackFailed }
    }

    public func stop() {
        player?.stop()
        player?.currentTime = 0
    }

    /// 160 ms, 880 Hz, mono unsigned 8-bit PCM at 8 kHz.
    private static func beepWAV() -> Data {
        let sampleRate: UInt32 = 8_000
        let sampleCount = 1_280
        var samples = [UInt8](repeating: 128, count: sampleCount)
        for index in samples.indices {
            let envelope = min(1.0, Double(index) / 80.0)
                * min(1.0, Double(sampleCount - index) / 120.0)
            let wave = sin(2 * Double.pi * 880 * Double(index) / Double(sampleRate))
            samples[index] = UInt8(clamping: Int(128 + 76 * envelope * wave))
        }

        var data = Data()
        func appendASCII(_ value: String) { data.append(contentsOf: value.utf8) }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        appendASCII("RIFF")
        appendLE(UInt32(36 + samples.count))
        appendASCII("WAVEfmt ")
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(1))
        appendLE(sampleRate)
        appendLE(sampleRate)
        appendLE(UInt16(1))
        appendLE(UInt16(8))
        appendASCII("data")
        appendLE(UInt32(samples.count))
        data.append(contentsOf: samples)
        return data
    }
}

/// Shared focus/break expiry alarm: an immediate media-output beep followed
/// by one beep per second, plus the app focus-back watch. Start/stop are
/// idempotent and own exactly one player, timer, and notification observer.
/// Any player setup or playback failure falls back to `NSSound.beep()`.
@MainActor
public final class ExpiryAlarmController: NSObject {
    public static let beepInterval: TimeInterval = 1.0

    private let player: any ExpiryAlarmPlaying
    private let fallbackBeep: () -> Void
    private let isAppActiveProvider: () -> Bool
    nonisolated(unsafe) private var beepTimer: Timer?

    public private(set) var isAlarming = false
    public var onStateChange: ((Bool) -> Void)?
    public var onFocusBack: (() -> Void)?

    public init(
        player: (any ExpiryAlarmPlaying)? = nil,
        fallbackBeep: @escaping () -> Void = { NSSound.beep() },
        isAppActive: @escaping () -> Bool = { NSApplication.shared.isActive }
    ) {
        self.player = player ?? AVAudioExpiryAlarmPlayer()
        self.fallbackBeep = fallbackBeep
        self.isAppActiveProvider = isAppActive
        super.init()
    }

    public var isAppActive: Bool { isAppActiveProvider() }

    public func start() {
        guard !isAlarming else { return }
        isAlarming = true
        onStateChange?(true)
        playAlarmPulse()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        let timer = Timer(timeInterval: Self.beepInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.playAlarmPulse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        beepTimer = timer
    }

    public func stop() {
        guard isAlarming else { return }
        isAlarming = false
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didBecomeActiveNotification, object: nil)
        beepTimer?.invalidate()
        beepTimer = nil
        player.stop()
        onStateChange?(false)
    }

    /// Internal deterministic cadence seam: tests trigger repeats directly,
    /// avoiding sleeps and audio hardware.
    func playAlarmPulse() {
        do {
            try player.play()
        } catch {
            fallbackBeep()
        }
    }

    @objc private func handleDidBecomeActive() {
        guard isAlarming else { return }
        stop()
        onFocusBack?()
    }

    deinit {
        beepTimer?.invalidate()
        beepTimer = nil
        NotificationCenter.default.removeObserver(self)
    }
}
