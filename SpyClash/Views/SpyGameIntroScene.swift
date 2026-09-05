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

struct SpyGameIntroScene<ParticipantID: Hashable>: View {
    let participants: [SpyGameIntroParticipant<ParticipantID>]
    let spyCount: Int
    let language: AppLanguage
    let startedAt: Date
    let duration: TimeInterval
    let accessibilityIdentifier: String

    let fixedProgress: Double?

    @SpyReduceMotion private var reduceMotion

    init(
        participants: [SpyGameIntroParticipant<ParticipantID>],
        spyCount: Int,
        language: AppLanguage,
        startedAt: Date,
        duration: TimeInterval = 8,
        fixedProgress: Double? = nil,
        accessibilityIdentifier: String = "spyGame.intro"
    ) {
        self.participants = participants
        self.spyCount = spyCount
        self.language = language
        self.startedAt = startedAt
        self.duration = duration
        self.fixedProgress = fixedProgress
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: pausesTimeline)) { timeline in
            GeometryReader { proxy in
                introStage(
                    size: proxy.size,
                    progress: resolvedProgress(at: timeline.date)
                )
            }
        }
        .background(SpyTheme.black)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(copy.introAccessibility(spyCount: normalizedSpyCount))
        .accessibilityIdentifier(accessibilityIdentifier)
        .task(id: startedAt) {
            await playIntroHaptics()
        }
    }

    private func introStage(size: CGSize, progress: Double) -> some View {
        let deckPoint = CGPoint(x: size.width / 2, y: size.height * 0.65)
        let warningProgress = reduceMotion ? 1 : SpyExperienceMotion.segment(progress, from: 0.72, to: 0.84)
        let warningExit = reduceMotion ? 0 : SpyExperienceMotion.segment(progress, from: 0.90, to: 0.96)
        let warningOpacity = reduceMotion ? 1 : warningProgress * (1 - warningExit)
        let dimmedOpacity = reduceMotion ? 0.42 : 1 - warningProgress * 0.88
        let outro = reduceMotion ? 0 : SpyExperienceMotion.segment(progress, from: 0.94, to: 1)
        let deckReveal = SpyExperienceMotion.spring(
            SpyExperienceMotion.segment(progress, from: 0.16, to: 0.34)
        )

        return ZStack {
            SpyCinematicBackdrop(intensity: CGFloat(0.72 + warningProgress * 0.34))
                .opacity(dimmedOpacity + warningProgress * 0.28)

            VStack(spacing: 7) {
                SpyWordmark(fontSize: 22)
                Text(copy.gameStarting)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(SpyTheme.dim)
            }
            .position(x: size.width / 2, y: max(68, size.height * 0.10))
            .opacity(SpyExperienceMotion.segment(progress, from: 0, to: 0.14))
            .blur(radius: reduceMotion ? 0 : warningProgress * 5)
            .offset(y: reduceMotion ? 0 : -warningProgress * 10)

            ForEach(Array(participants.enumerated()), id: \.element.id) { index, participant in
                let target = participantPosition(index: index, count: participants.count, size: size)
                let appearance = reduceMotion
                    ? 1
                    : SpyExperienceMotion.easeOut(
                        SpyExperienceMotion.segment(
                            progress,
                            from: 0.11 + Double(index) * 0.018,
                            to: 0.29 + Double(index) * 0.018
                        )
                    )
                let window = dealWindow(index: index, count: participants.count)
                let rawDeal = reduceMotion
                    ? 1
                    : SpyExperienceMotion.segment(progress, from: window.start, to: window.end)
                let deal = reduceMotion ? 1 : SpyExperienceMotion.spring(rawDeal)
                let cardPoint = SpyExperienceMotion.arcPoint(
                    from: deckPoint,
                    to: CGPoint(x: target.x, y: target.y + 72),
                    progress: min(max(deal, 0), 1),
                    lift: 56 + abs(target.x - deckPoint.x) * 0.18
                )
                let landingPulse = SpyExperienceMotion.pulse(rawDeal, center: 0.88, width: 0.18)

                SpyGameIntroParticipantIdentity(
                    name: participant.name,
                    avatar: participant.avatar,
                    isReady: rawDeal > 0.82,
                    illumination: CGFloat(min(max(deal, 0), 1))
                )
                .scaleEffect(0.82 + 0.18 * appearance + landingPulse * 0.035)
                .opacity(appearance * dimmedOpacity)
                .position(target)
                .blur(radius: reduceMotion ? 0 : warningProgress * 3)

                CutCornerShape(cut: 10)
                    .stroke(SpyTheme.red.opacity(0.62), lineWidth: 1)
                    .frame(width: 66 + landingPulse * 24, height: 66 + landingPulse * 24)
                    .position(x: target.x, y: target.y + 12)
                    .opacity(landingPulse * dimmedOpacity)
                    .accessibilityHidden(true)

                SpyGameIntroRoleCardBack()
                    .frame(width: min(42, size.width * 0.108))
                    .rotation3DEffect(
                        .degrees(reduceMotion ? 0 : (Double(index % 3) - 1) * 12 * (1 - rawDeal)),
                        axis: (x: 0.22, y: 1, z: 0),
                        perspective: 0.72
                    )
                    .rotationEffect(
                        .degrees(
                            reduceMotion
                                ? 0
                                : (Double(index % 3) - 1) * 10 * (1 - rawDeal) + sin(rawDeal * .pi) * 7
                        )
                    )
                    .scaleEffect(0.78 + min(max(deal, 0), 1) * 0.22)
                    .position(cardPoint)
                    .shadow(color: SpyTheme.red.opacity(0.28 * sin(rawDeal * .pi)), radius: 16)
                    .opacity((rawDeal > 0 ? 1 : 0) * dimmedOpacity)
                    .accessibilityHidden(true)
            }

            SpyGameIntroCardDeck()
                .position(deckPoint)
                .scaleEffect(0.72 + 0.28 * deckReveal)
                .rotation3DEffect(
                    .degrees(reduceMotion ? 0 : (1 - deckReveal) * 26),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 0.68
                )
                .opacity(
                    deckReveal *
                        (1 - SpyExperienceMotion.segment(progress, from: 0.68, to: 0.78)) *
                        dimmedOpacity
                )
                .shadow(color: SpyTheme.red.opacity(0.22), radius: 24, y: 14)
                .accessibilityHidden(true)

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [.clear, SpyTheme.red.opacity(0.92), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.4
                )
                .frame(width: 120, height: 120)
                .scaleEffect(0.35 + warningProgress * 2.8)
                .opacity(reduceMotion ? 0 : (1 - warningProgress) * warningProgress * 2.2)
                .position(x: size.width / 2, y: size.height * 0.49)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                Text(copy.spyTeam(spyCount: normalizedSpyCount))
                    .foregroundStyle(SpyTheme.red)
                Text(copy.amongYou)
                    .foregroundStyle(.white)
            }
            .font(SpyTheme.brandFont(size: min(48, size.width * 0.125)))
            .tracking(2.5)
            .multilineTextAlignment(.center)
            .shadow(color: SpyTheme.red.opacity(0.28), radius: 30)
            .scaleEffect(reduceMotion ? 1 : 0.72 + 0.28 * SpyExperienceMotion.spring(warningProgress))
            .blur(radius: reduceMotion ? 0 : (1 - warningProgress) * 14 + warningExit * 6)
            .opacity(warningOpacity)
            .position(x: size.width / 2, y: size.height * 0.49)

            Color.black
                .opacity(outro)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func dealWindow(index: Int, count: Int) -> (start: Double, end: Double) {
        let intervals = max(count - 1, 1)
        let spacing = min(0.058, 0.22 / Double(intervals))
        let start = 0.29 + Double(index) * spacing
        return (start, start + 0.24)
    }

    private func participantPosition(index: Int, count: Int, size: CGSize) -> CGPoint {
        guard count > 0 else {
            return CGPoint(x: size.width / 2, y: size.height * 0.26)
        }

        let columns = min(count, size.width < 360 ? 3 : 4)
        let row = index / columns
        let rows = Int(ceil(Double(count) / Double(columns)))
        let column = index % columns
        let rowCount = row == rows - 1 ? count - row * columns : columns
        let horizontalInset: CGFloat = 50
        let usableWidth = max(size.width - horizontalInset * 2, 0)
        let x = rowCount == 1
            ? size.width / 2
            : horizontalInset + usableWidth * CGFloat(column) / CGFloat(rowCount - 1)
        let y = size.height * 0.22 + CGFloat(row) * 104
        return CGPoint(x: x, y: y)
    }

    private func resolvedProgress(at date: Date) -> Double {
        if let fixedProgress = resolvedFixedProgress {
            return fixedProgress
        }
        if reduceMotion {
            return 0.82
        }

        return min(max(date.timeIntervalSince(startedAt) / normalizedDuration, 0), 1)
    }

    @MainActor
    private func playIntroHaptics() async {
        guard !reduceMotion, resolvedFixedProgress == nil else { return }

        let count = max(participants.count, 1)
        for index in participants.indices {
            let window = dealWindow(index: index, count: count)
            let targetDate = startedAt.addingTimeInterval(normalizedDuration * (window.start + 0.18))
            let delay = targetDate.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            HapticManager.shared.fire(.navigation)
        }

        let warningDate = startedAt.addingTimeInterval(normalizedDuration * 0.74)
        let warningDelay = warningDate.timeIntervalSinceNow
        if warningDelay > 0 {
            try? await Task.sleep(for: .seconds(warningDelay))
        }
        guard !Task.isCancelled else { return }
        HapticManager.shared.fire(.reveal)
    }

    private var normalizedDuration: TimeInterval {
        max(duration, 0.01)
    }

    private var normalizedSpyCount: Int {
        max(spyCount, 1)
    }

    private var pausesTimeline: Bool {
        reduceMotion || resolvedFixedProgress != nil
    }

    private var resolvedFixedProgress: Double? {
        fixedProgress.map { min(max($0, 0), 1) }
    }

    private var copy: SpyGameIntroCopy {
        SpyGameIntroCopy(language: language)
    }
}

private struct SpyGameIntroParticipantIdentity: View {
    let name: String
    let avatar: String
    let isReady: Bool
    let illumination: CGFloat

    var body: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                CutCornerShape(cut: 9)
                    .fill(SpyTheme.control)
                    .frame(width: 52, height: 52)
                    .overlay {
                        CutCornerShape(cut: 9)
                            .stroke(isReady ? SpyTheme.green.opacity(0.74) : SpyTheme.red.opacity(0.46), lineWidth: 1.2)
                    }

                Text(displayAvatar)
                    .font(.system(size: 25))
                    .frame(width: 52, height: 52)
                    .saturation(0.24 + illumination * 0.76)
                    .opacity(0.46 + illumination * 0.54)

                if isReady {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.black)
                        .frame(width: 15, height: 15)
                        .background(SpyTheme.green, in: CutCornerShape(cut: 4))
                        .offset(x: 4, y: 4)
                }
            }

            Text(name.uppercased())
                .font(SpyTheme.brandFont(size: 11))
                .tracking(0.8)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .frame(width: 88)

            Capsule()
                .fill(isReady ? SpyTheme.green.opacity(0.72) : SpyTheme.red.opacity(0.24))
                .frame(width: isReady ? 24 : 10, height: 1)
        }
    }

    private var displayAvatar: String {
        let normalizedAvatar = avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedAvatar.isEmpty {
            return normalizedAvatar
        }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedName.first.map { String($0).uppercased() } ?? "•"
    }
}

private struct SpyGameIntroRoleCardBack: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                SpyTheme.card

                SpyCardSurfacePattern(theme: .field, accent: SpyTheme.red)
                    .opacity(0.44)

                VStack(spacing: 3) {
                    SpyBrandMark()
                        .frame(width: 27, height: 31)
                        .scaleEffect(min(proxy.size.width / 82, 0.66))
                    SpyWordmark(fontSize: 5.5)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .aspectRatio(0.75, contentMode: .fit)
        .clipShape(CutCornerShape(cut: 6))
        .overlay {
            CutCornerShape(cut: 6)
                .stroke(SpyTheme.red.opacity(0.62), lineWidth: 0.8)
        }
        .accessibilityHidden(true)
    }
}

private struct SpyGameIntroCardDeck: View {
    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                SpyGameIntroRoleCardBack()
                    .frame(width: 76)
                    .offset(x: CGFloat(index) * 2.4 - 4, y: CGFloat(index) * -2.8 + 5)
                    .rotationEffect(.degrees(Double(index) * 1.55 - 2.3))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SpyGameIntroCopy {
    let language: AppLanguage

    var gameStarting: String {
        text(
            "// THE GAME BEGINS",
            "// EL JUEGO EMPIEZA",
            "// ИГРА НАЧИНАЕТСЯ",
            "// ГРА ПОЧИНАЄТЬСЯ"
        )
    }

    var amongYou: String {
        text("AMONG YOU", "ENTRE USTEDES", "СРЕДИ ВАС", "СЕРЕД ВАС")
    }

    func spyTeam(spyCount: Int) -> String {
        spyCount > 1
            ? text("SPIES", "ESPÍAS", "ШПИОНЫ", "ШПИГУНИ")
            : text("SPY", "ESPÍA", "ШПИОН", "ШПИГУН")
    }

    func introAccessibility(spyCount: Int) -> String {
        spyCount > 1
            ? text(
                "The game begins. Cards are dealt. The spies are among you.",
                "El juego comienza. Las cartas están repartidas. Los espías están entre ustedes.",
                "Игра начинается. Карты розданы. Шпионы среди вас.",
                "Гра починається. Карти роздано. Шпигуни серед вас."
            )
            : text(
                "The game begins. Cards are dealt. The spy is among you.",
                "El juego comienza. Las cartas están repartidas. El espía está entre ustedes.",
                "Игра начинается. Карты розданы. Шпион среди вас.",
                "Гра починається. Карти роздано. Шпигун серед вас."
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
