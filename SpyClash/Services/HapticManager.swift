import CoreHaptics
import UIKit

@MainActor
final class HapticManager {
    static let shared = HapticManager()
    static let interfaceSoundsEnabledKey = "spyclash.interface-sounds.enabled"

    enum AudioPolicy {
        case automatic
        case hapticOnly
    }

    enum HapticType {
        case buttonPress
        case tabSelection
        case notification(UINotificationFeedbackGenerator.FeedbackType)
        case milestone
        case reveal
        case navigation
    }

    // Compatibility surface for existing call sites. SpyClash is intentionally
    // silent; sound cues now describe only the paired haptic intent.
    enum SoundCue: CaseIterable, Hashable, Sendable {
        case click
        case success
        case denied
        case allow
        case holographicTick
        case hardDeny
        case echoBlip
        case navigationShift
        case qrCardFlip
        case secretReveal
        case roleReveal
        case copyConfirm
        case toggleOn
        case toggleOff
        case playerJoin
        case playerLeave
        case readyLock
        case turnPass
        case countdownTick
        case countdownGo
        case voteCast
        case voteLocked
        case gameStart
        case resultDetectives
        case resultSpy
    }

    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private let notificationGenerator = UINotificationFeedbackGenerator()
    private var limitlessEngine: CHHapticEngine?

    private init() {
        UserDefaults.standard.set(false, forKey: Self.interfaceSoundsEnabledKey)
        selectionGenerator.prepare()
        impactGenerator.prepare()
        rigidGenerator.prepare()
        configureLimitlessEngine()
    }

    func fire(
        _ type: HapticType,
        isEnabled: Bool = true,
        audioPolicy _: AudioPolicy = .automatic
    ) {
        guard isEnabled else { return }

        switch type {
        case .buttonPress:
            impactGenerator.impactOccurred(intensity: 0.62)
            impactGenerator.prepare()
        case .tabSelection, .navigation:
            selectionGenerator.selectionChanged()
            selectionGenerator.prepare()
        case .notification(let feedback):
            notificationGenerator.notificationOccurred(feedback)
            notificationGenerator.prepare()
        case .milestone:
            notificationGenerator.notificationOccurred(.success)
            notificationGenerator.prepare()
        case .reveal:
            rigidGenerator.impactOccurred(intensity: 0.52)
            rigidGenerator.prepare()
        }
    }

    func fire(
        _ type: HapticType,
        sound _: SoundCue,
        isEnabled: Bool = true
    ) {
        fire(type, isEnabled: isEnabled, audioPolicy: .hapticOnly)
    }

    func preloadInterfaceSounds() {}

    func playSound(_: SoundCue) {}

    func prepareSharedAudioSession(
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        completion(false)
    }

    func setInterfaceSoundsEnabled(_: Bool) {
        UserDefaults.standard.set(false, forKey: Self.interfaceSoundsEnabledKey)
    }

    func setApplicationActive(_: Bool) {}

    func stopInterfaceSounds() {}

    func prepareLimitlessPresentation() {
        guard let limitlessEngine else {
            rigidGenerator.prepare()
            return
        }

        try? limitlessEngine.start()
    }

    func playLimitlessCharge() {
        let events = [
            continuousEvent(time: 0, duration: 0.34, intensity: 0.18, sharpness: 0.82),
            transientEvent(time: 0.02, intensity: 0.24, sharpness: 0.90),
            transientEvent(time: 0.13, intensity: 0.48, sharpness: 0.96),
            transientEvent(time: 0.27, intensity: 0.88, sharpness: 1.00)
        ]

        playLimitlessPattern(events, fallbackIntensity: 0.88)
    }

    func playLimitlessUnlock(index: Int) {
        let emphasis = min(1, 0.72 + Float(index) * 0.06)
        let events = [
            transientEvent(time: 0, intensity: emphasis, sharpness: 1.00),
            continuousEvent(time: 0.015, duration: 0.10, intensity: 0.20, sharpness: 0.78),
            transientEvent(time: 0.12, intensity: 0.38, sharpness: 0.42)
        ]

        playLimitlessPattern(events, fallbackIntensity: CGFloat(emphasis))
    }

    func playLimitlessCompletion() {
        let events = [
            transientEvent(time: 0, intensity: 0.42, sharpness: 0.64),
            transientEvent(time: 0.09, intensity: 0.66, sharpness: 0.84),
            transientEvent(time: 0.20, intensity: 1.00, sharpness: 0.98),
            continuousEvent(time: 0.22, duration: 0.18, intensity: 0.25, sharpness: 0.58)
        ]

        playLimitlessPattern(events, fallbackIntensity: 1)
    }

    private func configureLimitlessEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            return
        }

        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            engine.resetHandler = { [weak self] in
                Task { @MainActor in
                    try? self?.limitlessEngine?.start()
                }
            }
            limitlessEngine = engine
        } catch {
            limitlessEngine = nil
        }
    }

    private func playLimitlessPattern(_ events: [CHHapticEvent], fallbackIntensity: CGFloat) {
        guard let limitlessEngine else {
            rigidGenerator.impactOccurred(intensity: fallbackIntensity)
            rigidGenerator.prepare()
            return
        }

        do {
            try limitlessEngine.start()
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try limitlessEngine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            rigidGenerator.impactOccurred(intensity: fallbackIntensity)
            rigidGenerator.prepare()
        }
    }

    private func transientEvent(
        time: TimeInterval,
        intensity: Float,
        sharpness: Float
    ) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: time
        )
    }

    private func continuousEvent(
        time: TimeInterval,
        duration: TimeInterval,
        intensity: Float,
        sharpness: Float
    ) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: time,
            duration: duration
        )
    }
}
