import Foundation
import SwiftUI

struct SpyGameIntroParticipant<ID: Hashable>: Identifiable {
    let id: ID
    let name: String
    let avatar: String

    init(id: ID, name: String, avatar: String) {
        self.id = id
        self.name = name
        self.avatar = avatar
    }
}

/// A single choreography shared by the visual and its two tactile accents.
/// Every phase comes to rest without a spring overshoot or a clamped velocity.
enum SpyGameIntroChoreography {
    static func phase(_ progress: Double, from start: Double, to end: Double) -> Double {
        let t = min(max((progress - start) / max(end - start, 0.001), 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    static func spread(_ progress: Double, index: Int, count: Int) -> Double {
        let delay = Double(index) / Double(max(count - 1, 1)) * 0.085
        return phase(progress, from: 0.16 + delay, to: 0.50 + delay)
    }

    static func pulse(_ progress: Double) -> Double {
        let rise = phase(progress, from: 0.60, to: 0.70)
        let settle = phase(progress, from: 0.70, to: 0.84)
        return rise * (1 - settle)
    }
}

struct SpyGameIntroScene<ParticipantID: Hashable>: View {
    let participants: [SpyGameIntroParticipant<ParticipantID>]
    let spyCount: Int
    let fanEnabled: Bool
    let language: AppLanguage
    let startedAt: Date
    let duration: TimeInterval
    let holdsFinalFrame: Bool
    let accessibilityIdentifier: String
    let fixedProgress: Double?

    @SpyReduceMotion private var reduceMotion
    @State private var timelineCompleted = false

    init(
        participants: [SpyGameIntroParticipant<ParticipantID>],
        spyCount: Int,
        fanEnabled: Bool = false,
        language: AppLanguage,
        startedAt: Date,
        duration: TimeInterval = Base44Client.gameIntroDuration,
        holdsFinalFrame: Bool = false,
        fixedProgress: Double? = nil,
        accessibilityIdentifier: String = "spyGame.intro"
    ) {
        self.participants = participants
        self.spyCount = spyCount
        self.fanEnabled = fanEnabled
        self.language = language
        self.startedAt = startedAt
        self.duration = duration
        self.holdsFinalFrame = holdsFinalFrame
        self.fixedProgress = fixedProgress
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: resolvedFixedProgress != nil || timelineCompleted)) { timeline in
            GeometryReader { proxy in
                introStage(size: proxy.size, progress: resolvedProgress(at: timeline.date))
            }
        }
        .background(SpyTheme.black)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            fanEnabled
                ? "FAN MODE. " + FanModeCopy(language: language).rules
                : copy.introAccessibility(spyCount: spyCount)
        )
        .accessibilityIdentifier(accessibilityIdentifier)
        .task(id: startedAt) {
            await playIntroHaptics()
        }
        .task(id: startedAt) {
            timelineCompleted = false
            guard resolvedFixedProgress == nil else { return }
            let remaining = startedAt.addingTimeInterval(normalizedDuration).timeIntervalSinceNow
            do {
                if remaining > 0 {
                    try await Task.sleep(for: .seconds(remaining))
                }
                try Task.checkCancellation()
                timelineCompleted = true
            } catch {
                return
            }
        }
    }

    private func introStage(size: CGSize, progress: Double) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height * 0.47)
        let radius = min(size.width * 0.32, size.height * 0.22, 156)
        let cardWidth = min(size.width * 0.174, 76)
        let entrance = SpyGameIntroChoreography.phase(progress, from: 0.08, to: 0.22)
        let mission = SpyGameIntroChoreography.phase(progress, from: 0.54, to: 0.70)
        let pulse = reduceMotion ? 0 : SpyGameIntroChoreography.pulse(progress)
        let exit = holdsFinalFrame ? 0 : SpyGameIntroChoreography.phase(progress, from: 0.85, to: 1)

        return ZStack {
            SpyTheme.black

            RadialGradient(
                colors: [SpyTheme.red.opacity(0.11 + pulse * 0.045), .clear],
                center: .center,
                startRadius: 6,
                endRadius: radius * 1.75
            )
            .frame(width: radius * 4, height: radius * 4)
            .position(center)
            .opacity(entrance)
            .accessibilityHidden(true)

            VStack(spacing: 10) {
                SpyWordmark(fontSize: 21)
                Text(copy.gameStarting)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(2.1)
                    .foregroundStyle(Color.white.opacity(0.38))
            }
            .position(x: size.width / 2, y: max(96, size.height * 0.15))
            .opacity(entrance * (1 - mission * 0.35))

            cardFormation(
                center: center,
                radius: radius,
                cardWidth: cardWidth,
                progress: progress,
                entrance: entrance,
                mission: mission
            )

            Circle()
                .stroke(SpyTheme.red.opacity(0.26), lineWidth: 0.75)
                .frame(width: radius * 1.12, height: radius * 1.12)
                .scaleEffect(1 + pulse * 0.18)
                .position(center)
                .opacity(reduceMotion ? 0 : pulse * 0.72)
                .accessibilityHidden(true)

            missionTitle(cardWidth: cardWidth)
                .scaleEffect(reduceMotion ? 1 : 0.985 + mission * 0.015 + pulse * 0.03)
                .opacity(mission)
                .position(center)

            Color.black
                .opacity(exit)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .clipped()
    }

    private func cardFormation(
        center: CGPoint,
        radius: CGFloat,
        cardWidth: CGFloat,
        progress: Double,
        entrance: Double,
        mission: Double
    ) -> some View {
        ZStack {
            ForEach(0..<visualCardCount, id: \.self) { index in
                let spread = reduceMotion
                    ? 1
                    : SpyGameIntroChoreography.spread(progress, index: index, count: visualCardCount)
                let fraction = Double(index) / Double(visualCardCount)
                let targetAngle = fraction * 360 - 90
                let radialRotation = fraction > 0.5 ? fraction * 360 - 360 : fraction * 360
                // A restrained shared arc opens the deck, then resolves into a true circle.
                let travelAngle = (targetAngle - 22 * (1 - spread)) * .pi / 180
                let stackOffset = (Double(index) - Double(visualCardCount - 1) / 2) * 0.75
                let x = cos(travelAngle) * radius * spread + stackOffset * (1 - spread)
                let y = sin(travelAngle) * radius * spread + (28 + stackOffset) * (1 - spread)
                let rotation = reduceMotion
                    ? radialRotation
                    : stackOffset * 0.7 * (1 - spread) + radialRotation * spread

                SpyGameIntroRoleCardBack()
                    .frame(width: cardWidth, height: cardWidth / 0.70)
                    .rotationEffect(.degrees(rotation))
                    .scaleEffect(reduceMotion ? 1 : 0.96 + entrance * 0.04)
                    .position(x: center.x + x, y: center.y + y)
                    .opacity(entrance * (1 - mission * 0.70))
            }
        }
        .accessibilityHidden(true)
    }

    private func missionTitle(cardWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(fanEnabled ? copy.fanLead : copy.missionLead)
                .font(.system(size: min(cardWidth * 0.25, 18), weight: .semibold, design: .monospaced))
                .tracking(2.0)
                .foregroundStyle(.white.opacity(0.9))

            Text(fanEnabled ? copy.fanSubject : copy.missionSubject(spyCount: spyCount))
                .font(SpyTheme.brandFont(size: min(cardWidth * 0.61, 44)))
                .tracking(1.5)
                .foregroundStyle(SpyTheme.red)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.70)
        .multilineTextAlignment(.center)
        .frame(width: cardWidth * 3.4)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var visualCardCount: Int {
        // The ring is decorative, never a disclosure of roles or exact team composition.
        min(max(participants.count, 6), 12)
    }

    private func resolvedProgress(at date: Date) -> Double {
        resolvedFixedProgress ?? (timelineCompleted ? 1 : min(max(date.timeIntervalSince(startedAt) / normalizedDuration, 0), 1))
    }

    @MainActor
    private func playIntroHaptics() async {
        guard !reduceMotion, resolvedFixedProgress == nil else { return }

        let cues: [(Double, HapticManager.HapticType)] = [(0.19, .navigation), (0.66, .reveal)]
        for (progress, feedback) in cues {
            let date = startedAt.addingTimeInterval(normalizedDuration * progress)
            let delay = date.timeIntervalSinceNow
            // A delayed snapshot/resume must not replay every missed haptic at once.
            guard delay > -0.12 else { continue }
            do {
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
                try Task.checkCancellation()
            } catch {
                return
            }
            guard !reduceMotion, abs(date.timeIntervalSinceNow) < 0.15 else { continue }
            HapticManager.shared.fire(feedback)
        }
    }

    private var normalizedDuration: TimeInterval {
        duration.isFinite ? max(duration, 0.01) : Base44Client.gameIntroDuration
    }

    private var resolvedFixedProgress: Double? {
        fixedProgress.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
    }

    private var copy: SpyGameIntroCopy {
        SpyGameIntroCopy(language: language)
    }
}

private struct SpyGameIntroRoleCardBack: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                CutCornerShape(cut: 7)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.14, green: 0.055, blue: 0.06), SpyTheme.card],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                CutCornerShape(cut: 4)
                    .stroke(SpyTheme.red.opacity(0.17), lineWidth: 0.6)
                    .padding(5)

                VStack(spacing: 5) {
                    SpyBrandMark()
                        .frame(width: proxy.size.width * 0.50, height: proxy.size.height * 0.42)
                    SpyWordmark(fontSize: proxy.size.width * 0.086)
                }
                .padding(.horizontal, 8)
            }
            .overlay {
                CutCornerShape(cut: 7)
                    .stroke(
                        LinearGradient(
                            colors: [SpyTheme.red.opacity(0.76), SpyTheme.red.opacity(0.24)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.85
                    )
            }
        }
        .shadow(color: .black.opacity(0.48), radius: 6, y: 3)
    }
}

private struct SpyGameIntroCopy {
    let language: AppLanguage

    var gameStarting: String {
        text("THE GAME BEGINS", "EMPIEZA EL JUEGO", "ИГРА НАЧИНАЕТСЯ", "ГРА ПОЧИНАЄТЬСЯ")
    }

    var missionLead: String {
        text("FIND THE", "ENCUENTRA", "НАЙДИТЕ", "ЗНАЙДІТЬ")
    }

    func missionSubject(spyCount: Int) -> String {
        spyCount > 1
            ? text("SPIES", "A LOS ESPÍAS", "ШПИОНОВ", "ШПИГУНІВ")
            : text("SPY", "AL ESPÍA", "ШПИОНА", "ШПИГУНА")
    }

    var fanLead: String {
        text("TRUST", "NO CONFÍES", "НЕ ВЕРЬТЕ", "НЕ ВІРТЕ")
    }

    var fanSubject: String {
        text("NO ONE", "EN NADIE", "НИКОМУ", "НІКОМУ")
    }

    func introAccessibility(spyCount: Int) -> String {
        spyCount > 1
            ? text(
                "The game begins. Cards are dealt. Find the spies.",
                "El juego comienza. Se reparten las cartas. Encuentra a los espías.",
                "Игра начинается. Карты раздаются. Найдите шпионов.",
                "Гра починається. Карти роздаються. Знайдіть шпигунів."
            )
            : text(
                "The game begins. Cards are dealt. Find the spy.",
                "El juego comienza. Se reparten las cartas. Encuentra al espía.",
                "Игра начинается. Карты раздаются. Найдите шпиона.",
                "Гра починається. Карти роздаються. Знайдіть шпигуна."
            )
    }

    private func text(_ en: String, _ es: String, _ ru: String, _ uk: String) -> String {
        switch language {
        case .en: en
        case .es: es
        case .ru: ru
        case .uk: uk
        }
    }
}
