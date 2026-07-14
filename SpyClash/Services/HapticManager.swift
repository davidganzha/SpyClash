import AVFoundation
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

        fileprivate var channel: SoundChannel {
            switch self {
            case .click,
                 .holographicTick,
                 .navigationShift,
                 .copyConfirm,
                 .toggleOn,
                 .toggleOff:
                .interaction
            case .denied, .hardDeny:
                .negative
            case .qrCardFlip, .secretReveal, .roleReveal:
                .reveal
            case .playerJoin,
                 .playerLeave,
                 .readyLock,
                 .turnPass,
                 .voteCast,
                 .voteLocked:
                .roomState
            case .countdownTick, .countdownGo, .gameStart:
                .gameFlow
            case .success,
                 .allow,
                 .echoBlip,
                 .resultDetectives,
                 .resultSpy:
                .outcome
            }
        }

        fileprivate var profile: SoundProfile {
            switch self {
            case .click:
                SoundProfile(
                    resourceName: "ui-click",
                    volume: 0.65,
                    startTime: 0.070,
                    cutTime: 0.200,
                    fadeDuration: 0.015,
                    cooldown: 0.060,
                    priority: 1,
                    priorityHold: 0.050
                )
            case .success:
                SoundProfile(
                    resourceName: "ui-success",
                    volume: 0.45,
                    startTime: 0,
                    cutTime: 2.250,
                    fadeDuration: 0.035,
                    cooldown: 0.750,
                    priority: 4,
                    priorityHold: 0.800
                )
            case .denied:
                SoundProfile(
                    resourceName: "ui-denied",
                    volume: 0.32,
                    startTime: 0,
                    cutTime: 0.900,
                    fadeDuration: 0.030,
                    cooldown: 0.220,
                    priority: 3,
                    priorityHold: 0.350
                )
            case .allow:
                SoundProfile(
                    resourceName: "ui-allow",
                    volume: 0.75,
                    startTime: 0,
                    cutTime: 1.300,
                    fadeDuration: 0.030,
                    cooldown: 0.180,
                    priority: 4,
                    priorityHold: 0.400,
                    pan: -0.10
                )
            case .holographicTick:
                SoundProfile(
                    resourceName: "ui-holographic-tick",
                    volume: 0.55,
                    startTime: 0,
                    cutTime: 0.120,
                    fadeDuration: 0.015,
                    // A fast slider can emit dozens of value changes per second.
                    // Keep the audible cadence deliberate instead of restarting
                    // the player on every single UIKit valueChanged callback.
                    cooldown: 0.085,
                    priority: 1,
                    priorityHold: 0.040
                )
            case .hardDeny:
                SoundProfile(
                    resourceName: "ui-hard-deny",
                    volume: 0.75,
                    startTime: 0,
                    cutTime: 1.280,
                    fadeDuration: 0.035,
                    cooldown: 0.400,
                    priority: 5,
                    priorityHold: 0.550
                )
            case .echoBlip:
                SoundProfile(
                    resourceName: "ui-echo-blip",
                    volume: 0.60,
                    startTime: 0.018,
                    cutTime: 0.850,
                    fadeDuration: 0.050,
                    cooldown: 0.140,
                    priority: 4,
                    priorityHold: 0.260
                )
            case .navigationShift:
                SoundProfile(
                    resourceName: "ui-navigation-shift",
                    volume: 0.68,
                    startTime: 0,
                    cutTime: 0.667,
                    fadeDuration: 0,
                    cooldown: 0.140,
                    priority: 2,
                    priorityHold: 0.120,
                    requiresManualStop: false
                )
            case .qrCardFlip:
                SoundProfile(
                    resourceName: "ui-qr-card-flip",
                    volume: 0.85,
                    startTime: 0,
                    cutTime: 0.600,
                    fadeDuration: 0,
                    cooldown: 0.550,
                    priority: 6,
                    priorityHold: 0.500,
                    requiresManualStop: false
                )
            case .secretReveal:
                SoundProfile(
                    resourceName: "ui-secret-reveal",
                    volume: 0.70,
                    startTime: 0,
                    cutTime: 0.875,
                    fadeDuration: 0,
                    cooldown: 0.550,
                    priority: 6,
                    priorityHold: 0.550,
                    requiresManualStop: false
                )
            case .roleReveal:
                SoundProfile(
                    resourceName: "ui-role-reveal",
                    volume: 0.76,
                    startTime: 0,
                    cutTime: 0.646,
                    fadeDuration: 0,
                    cooldown: 0.550,
                    priority: 6,
                    priorityHold: 0.550,
                    requiresManualStop: false
                )
            case .copyConfirm:
                SoundProfile(
                    resourceName: "ui-copy-confirm",
                    volume: 0.82,
                    startTime: 0,
                    cutTime: 0.507,
                    fadeDuration: 0,
                    cooldown: 0.180,
                    priority: 2,
                    priorityHold: 0.120,
                    requiresManualStop: false
                )
            case .toggleOn:
                SoundProfile(
                    resourceName: "ui-toggle-on",
                    volume: 0.82,
                    startTime: 0,
                    cutTime: 0.090,
                    fadeDuration: 0,
                    cooldown: 0.080,
                    priority: 1,
                    priorityHold: 0.040,
                    requiresManualStop: false
                )
            case .toggleOff:
                SoundProfile(
                    resourceName: "ui-toggle-off",
                    volume: 0.80,
                    startTime: 0,
                    cutTime: 0.110,
                    fadeDuration: 0,
                    cooldown: 0.080,
                    priority: 1,
                    priorityHold: 0.040,
                    requiresManualStop: false
                )
            case .playerJoin:
                SoundProfile(
                    resourceName: "ui-player-join",
                    volume: 0.72,
                    startTime: 0,
                    cutTime: 0.550,
                    fadeDuration: 0,
                    cooldown: 0.250,
                    priority: 3,
                    priorityHold: 0.280,
                    requiresManualStop: false
                )
            case .playerLeave:
                SoundProfile(
                    resourceName: "ui-player-leave",
                    volume: 0.72,
                    startTime: 0,
                    cutTime: 0.550,
                    fadeDuration: 0,
                    cooldown: 0.250,
                    priority: 3,
                    priorityHold: 0.280,
                    requiresManualStop: false
                )
            case .readyLock:
                SoundProfile(
                    resourceName: "ui-ready-lock",
                    volume: 0.86,
                    startTime: 0,
                    cutTime: 0.230,
                    fadeDuration: 0,
                    cooldown: 0.240,
                    priority: 3,
                    priorityHold: 0.240,
                    requiresManualStop: false
                )
            case .turnPass:
                SoundProfile(
                    resourceName: "ui-turn-pass",
                    volume: 0.78,
                    startTime: 0,
                    cutTime: 0.624,
                    fadeDuration: 0,
                    cooldown: 0.300,
                    priority: 3,
                    priorityHold: 0.300,
                    requiresManualStop: false
                )
            case .countdownTick:
                SoundProfile(
                    resourceName: "ui-countdown-tick",
                    volume: 0.84,
                    startTime: 0,
                    cutTime: 0.075,
                    fadeDuration: 0,
                    cooldown: 0.700,
                    priority: 3,
                    priorityHold: 0.120,
                    requiresManualStop: false
                )
            case .countdownGo:
                SoundProfile(
                    resourceName: "ui-countdown-go",
                    volume: 0.86,
                    startTime: 0,
                    cutTime: 0.600,
                    fadeDuration: 0,
                    cooldown: 1.000,
                    priority: 6,
                    priorityHold: 0.550,
                    requiresManualStop: false
                )
            case .voteCast:
                SoundProfile(
                    resourceName: "ui-vote-cast",
                    volume: 0.80,
                    startTime: 0,
                    cutTime: 0.120,
                    fadeDuration: 0,
                    cooldown: 0.240,
                    priority: 3,
                    priorityHold: 0.120,
                    requiresManualStop: false
                )
            case .voteLocked:
                SoundProfile(
                    resourceName: "ui-vote-locked",
                    volume: 0.86,
                    startTime: 0,
                    cutTime: 0.320,
                    fadeDuration: 0,
                    cooldown: 0.320,
                    priority: 3,
                    priorityHold: 0.300,
                    requiresManualStop: false
                )
            case .gameStart:
                SoundProfile(
                    resourceName: "ui-game-start",
                    volume: 0.90,
                    startTime: 0,
                    cutTime: 1.200,
                    fadeDuration: 0,
                    cooldown: 2.000,
                    priority: 7,
                    priorityHold: 1.050,
                    requiresManualStop: false
                )
            case .resultDetectives:
                SoundProfile(
                    resourceName: "ui-result-detectives",
                    volume: 0.94,
                    startTime: 0,
                    cutTime: 1.802,
                    fadeDuration: 0,
                    cooldown: 3.000,
                    priority: 8,
                    priorityHold: 1.250,
                    requiresManualStop: false
                )
            case .resultSpy:
                SoundProfile(
                    resourceName: "ui-result-spy",
                    volume: 0.94,
                    startTime: 0,
                    cutTime: 1.375,
                    fadeDuration: 0,
                    cooldown: 3.000,
                    priority: 8,
                    priorityHold: 1.000,
                    requiresManualStop: false
                )
            }
        }
    }

    fileprivate enum SoundChannel: Hashable, Sendable {
        case interaction
        case negative
        case reveal
        case roomState
        case gameFlow
        case outcome

        var cooldown: TimeInterval {
            switch self {
            case .interaction:
                0.075
            case .negative:
                0.180
            case .reveal:
                0.220
            case .roomState:
                0.120
            case .gameFlow:
                0.060
            case .outcome:
                0.150
            }
        }
    }

    fileprivate struct SoundProfile: Sendable {
        let resourceName: String
        let volume: Float
        let startTime: TimeInterval
        let cutTime: TimeInterval
        let fadeDuration: TimeInterval
        let cooldown: TimeInterval
        let priority: Int
        let priorityHold: TimeInterval
        var pan: Float = 0
        var requiresManualStop = true
    }

    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private let notificationGenerator = UINotificationFeedbackGenerator()
    private let interfaceSoundEngine = InterfaceSoundEngine()
    private var limitlessEngine: CHHapticEngine?

    private init() {
        selectionGenerator.prepare()
        impactGenerator.prepare()
        rigidGenerator.prepare()
        configureLimitlessEngine()
    }

    func fire(
        _ type: HapticType,
        isEnabled: Bool = true,
        audioPolicy: AudioPolicy = .automatic
    ) {
        guard isEnabled else { return }

        switch type {
        case .buttonPress:
            impactGenerator.impactOccurred(intensity: 0.62)
        case .tabSelection:
            selectionGenerator.selectionChanged()
        case .notification(let feedback):
            notificationGenerator.notificationOccurred(feedback)
            switch feedback {
            case .success:
                break
            case .warning:
                playIfAllowed(.denied, policy: audioPolicy)
            case .error:
                playIfAllowed(.hardDeny, policy: audioPolicy)
            @unknown default:
                break
            }
        case .milestone:
            notificationGenerator.notificationOccurred(.success)
        case .reveal:
            rigidGenerator.impactOccurred(intensity: 0.52)
            playIfAllowed(.roleReveal, policy: audioPolicy)
        case .navigation:
            selectionGenerator.selectionChanged()
        }
    }

    func fire(
        _ type: HapticType,
        sound cue: SoundCue,
        isEnabled: Bool = true
    ) {
        guard isEnabled else { return }
        fire(type, audioPolicy: .hapticOnly)
        playSound(cue)
    }

    func preloadInterfaceSounds() {
        interfaceSoundEngine.preload()
    }

    func playSound(_ cue: SoundCue) {
        interfaceSoundEngine.play(cue)
    }

    func prepareSharedAudioSession(
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        interfaceSoundEngine.prepareSharedAudioSession(completion: completion)
    }

    func setInterfaceSoundsEnabled(_ isEnabled: Bool) {
        interfaceSoundEngine.setEnabled(isEnabled)
    }

    func setApplicationActive(_ isActive: Bool) {
        interfaceSoundEngine.setApplicationActive(isActive)
    }

    func stopInterfaceSounds() {
        interfaceSoundEngine.stop()
    }

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

    private func playIfAllowed(_ cue: SoundCue, policy: AudioPolicy) {
        guard case .automatic = policy else { return }
        playSound(cue)
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

/// Queue-confined audio playback. AVAudioPlayer preparation and audio-session
/// activation are synchronous APIs, so keeping them off MainActor prevents a
/// navigation sound from stealing a frame during a tab transition.
private final class InterfaceSoundEngine: @unchecked Sendable {
    typealias Cue = HapticManager.SoundCue

    private static let latencySensitiveCues: [Cue] = [
        .qrCardFlip,
        .secretReveal,
        .roleReveal,
        .copyConfirm,
        .readyLock,
        .countdownTick,
        .countdownGo,
        .gameStart
    ]

    private let queue = DispatchQueue(
        label: "com.spyclash.interface-audio",
        qos: .userInitiated
    )
    private let defaultsKey = "spyclash.interface-sounds.enabled"

    private var players: [Cue: AVAudioPlayer] = [:]
    private var stopWorkItems: [Cue: DispatchWorkItem] = [:]
    private var generations: [Cue: UInt] = [:]
    private var lastPlayAt: [Cue: TimeInterval] = [:]
    private var lastChannelPlayAt: [HapticManager.SoundChannel: TimeInterval] = [:]
    private var lastChannelPriority: [HapticManager.SoundChannel: Int] = [:]
    private var blockedPriority = 0
    private var lowerPriorityBlockedUntil: TimeInterval = 0
    private var isEnabled: Bool
    private var isApplicationActive = true
    private var isSessionConfigured = false
    private var isSessionActive = false

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: defaultsKey) == nil {
            isEnabled = true
        } else {
            isEnabled = defaults.bool(forKey: defaultsKey)
        }
    }

    func preload() {
        queue.async { [weak self] in
            guard let self, self.isEnabled else { return }
            _ = self.configureSessionIfNeeded()
            for cue in Self.latencySensitiveCues where self.players[cue] == nil {
                self.loadPlayer(for: cue)
            }
        }
    }

    func play(_ cue: Cue) {
        queue.async { [weak self] in
            self?.playLocked(cue)
        }
    }

    func prepareSharedAudioSession(
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, self.isApplicationActive else {
                completion(false)
                return
            }
            completion(self.activateSessionIfNeeded())
        }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
        queue.async { [weak self] in
            guard let self else { return }
            self.isEnabled = enabled
            if enabled {
                _ = self.configureSessionIfNeeded()
                for cue in Self.latencySensitiveCues where self.players[cue] == nil {
                    self.loadPlayer(for: cue)
                }
            } else {
                self.stopLocked()
                self.deactivateSessionLocked()
            }
        }
    }

    func setApplicationActive(_ active: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isApplicationActive = active
            if active {
                self.isSessionActive = false
                guard self.isEnabled else { return }
                _ = self.configureSessionIfNeeded()
                for cue in Self.latencySensitiveCues where self.players[cue] == nil {
                    self.loadPlayer(for: cue)
                }
            } else {
                self.stopLocked()
                self.deactivateSessionLocked()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func playLocked(_ cue: Cue) {
        guard isEnabled, isApplicationActive else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let profile = cue.profile
        let channel = cue.channel
        if let lastPlay = lastPlayAt[cue], now - lastPlay < profile.cooldown {
            return
        }
        if let lastChannelPlay = lastChannelPlayAt[channel],
           now - lastChannelPlay < channel.cooldown,
           profile.priority <= (lastChannelPriority[channel] ?? profile.priority) {
            return
        }
        if now < lowerPriorityBlockedUntil, profile.priority < blockedPriority {
            return
        }

        guard activateSessionIfNeeded() else { return }
        if players[cue] == nil {
            loadPlayer(for: cue)
        }
        guard let player = players[cue] else { return }

        let activeChannelCues = players.filter { entry in
            entry.key.channel == channel && entry.value.isPlaying
        }
        if activeChannelCues.contains(where: { entry in
            entry.key.profile.priority > profile.priority
        }) {
            return
        }

        stopSounds(lowerThan: profile.priority)
        stopSounds(in: channel, atMost: profile.priority)
        lastPlayAt[cue] = now
        lastChannelPlayAt[channel] = now
        lastChannelPriority[channel] = profile.priority
        if profile.priority > 1 {
            blockedPriority = profile.priority
            lowerPriorityBlockedUntil = now + profile.priorityHold
        }

        let generation = (generations[cue] ?? 0) &+ 1
        generations[cue] = generation
        stopWorkItems[cue]?.cancel()
        stopWorkItems[cue] = nil

        if player.isPlaying { player.pause() }
        player.volume = profile.volume
        player.pan = profile.pan
        player.currentTime = min(profile.startTime, player.duration)
        if !player.play() {
            isSessionActive = false
            guard activateSessionIfNeeded() else { return }
            player.prepareToPlay()
            guard player.play() else { return }
        }

        if profile.requiresManualStop {
            scheduleStop(for: cue, generation: generation)
        }
    }

    private func loadPlayer(for cue: Cue) {
        let profile = cue.profile
        guard let url = Bundle.main.url(
            forResource: profile.resourceName,
            withExtension: "wav"
        ), let player = try? AVAudioPlayer(contentsOf: url) else {
            return
        }

        player.numberOfLoops = 0
        player.volume = profile.volume
        player.pan = profile.pan
        player.currentTime = min(profile.startTime, player.duration)
        player.prepareToPlay()
        players[cue] = player
    }

    @discardableResult
    private func configureSessionIfNeeded() -> Bool {
        guard !isSessionConfigured else { return true }

        do {
            try AVAudioSession.sharedInstance().setCategory(
                .ambient,
                mode: .default,
                options: [.mixWithOthers]
            )
            isSessionConfigured = true
            return true
        } catch {
            isSessionConfigured = false
            return false
        }
    }

    @discardableResult
    private func activateSessionIfNeeded() -> Bool {
        guard isEnabled, isApplicationActive, configureSessionIfNeeded() else { return false }
        guard !isSessionActive else { return true }

        do {
            try AVAudioSession.sharedInstance().setActive(true)
            isSessionActive = true
            return true
        } catch {
            isSessionActive = false
            return false
        }
    }

    private func deactivateSessionLocked() {
        guard isSessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
        isSessionActive = false
    }

    private func stopSounds(lowerThan priority: Int) {
        guard priority > 1 else { return }

        for (cue, player) in players where cue.profile.priority < priority && player.isPlaying {
            stopPlayback(for: cue, player: player)
        }
    }

    private func stopSounds(
        in channel: HapticManager.SoundChannel,
        atMost priority: Int
    ) {
        for (cue, player) in players
        where cue.channel == channel &&
            cue.profile.priority <= priority &&
            player.isPlaying {
            stopPlayback(for: cue, player: player)
        }
    }

    private func stopPlayback(for cue: Cue, player: AVAudioPlayer) {
        stopWorkItems[cue]?.cancel()
        stopWorkItems[cue] = nil
        generations[cue] = (generations[cue] ?? 0) &+ 1
        player.pause()
        player.currentTime = min(cue.profile.startTime, player.duration)
        player.volume = cue.profile.volume
    }

    private func scheduleStop(for cue: Cue, generation: UInt) {
        let profile = cue.profile
        let playbackDuration = max(0, profile.cutTime - profile.startTime)
        let fadeStartDelay = max(0, playbackDuration - profile.fadeDuration)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.generations[cue] == generation,
                  let player = self.players[cue] else {
                return
            }

            player.setVolume(0, fadeDuration: profile.fadeDuration)
            self.queue.asyncAfter(deadline: .now() + profile.fadeDuration) { [weak self] in
                guard let self,
                      self.generations[cue] == generation,
                      let player = self.players[cue] else {
                    return
                }

                player.pause()
                player.currentTime = min(profile.startTime, player.duration)
                player.volume = profile.volume
                self.stopWorkItems[cue] = nil
            }
        }

        stopWorkItems[cue] = workItem
        queue.asyncAfter(deadline: .now() + fadeStartDelay, execute: workItem)
    }

    private func stopLocked() {
        for workItem in stopWorkItems.values {
            workItem.cancel()
        }
        stopWorkItems.removeAll()

        for (cue, player) in players {
            if player.isPlaying { player.pause() }
            player.currentTime = min(cue.profile.startTime, player.duration)
            player.volume = cue.profile.volume
        }

        blockedPriority = 0
        lowerPriorityBlockedUntil = 0
        lastChannelPlayAt.removeAll()
        lastChannelPriority.removeAll()
    }
}
