import Foundation
import SwiftUI

enum OnlineVoteIdentityPolicy {
    static func candidates(
        from activePlayers: [Player],
        currentUserEmail: String?,
        eliminatedEmails: [String]
    ) -> [Player] {
        let currentUser = normalized(currentUserEmail)
        let eliminated = Set(eliminatedEmails.compactMap(normalized))

        return activePlayers.filter { player in
            guard let candidate = normalized(player.email) else { return false }
            return candidate != currentUser && !eliminated.contains(candidate)
        }
    }

    static func currentUserVote(
        in votes: [VoteRecord],
        currentUserEmail: String?
    ) -> VoteRecord? {
        guard let currentUser = normalized(currentUserEmail) else { return nil }
        return votes.first { normalized($0.voterEmail) == currentUser }
    }

    static func matches(_ left: String?, _ right: String?) -> Bool {
        guard let left = normalized(left), let right = normalized(right) else { return false }
        return left == right
    }

    private static func normalized(_ email: String?) -> String? {
        guard let email else { return nil }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

// MARK: - Shared online role card

enum MissionRoleCardContent: Equatable {
    case spy
    case detective(word: String)
    case spectator
}

enum MissionRoleCardSize: Equatable {
    case hero
    case compact

    var maximumWidth: CGFloat {
        switch self {
        case .hero: 300
        case .compact: 220
        }
    }

    var cornerCut: CGFloat {
        switch self {
        case .hero: 16
        case .compact: 10
        }
    }

    var scale: CGFloat {
        switch self {
        case .hero: 1
        case .compact: 0.76
        }
    }
}

struct SpyRoleCardIdentity: Identifiable, Equatable {
    let id: String
    let name: String
    let avatar: String
}

struct SpyRoleCardTeammateStrip: View {
    let teammates: [SpyRoleCardIdentity]
    let language: AppLanguage
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 4 : 7) {
            Text(title)
                .font(.system(size: compact ? 7 : 8, weight: .black, design: .monospaced))
                .tracking(compact ? 1.1 : 1.6)
                .foregroundStyle(SpyTheme.red)

            HStack(spacing: compact ? 6 : 9) {
                ForEach(teammates) { teammate in
                    HStack(spacing: 4) {
                        Text(teammate.avatar)
                        Text(teammate.name.uppercased())
                            .lineLimit(1)
                            .minimumScaleFactor(0.58)
                    }
                    .font(.system(size: compact ? 8 : 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, compact ? 9 : 12)
        .padding(.vertical, compact ? 6 : 8)
        .background(SpyTheme.red.opacity(0.08), in: CutCornerShape(cut: compact ? 5 : 7))
        .overlay {
            CutCornerShape(cut: compact ? 5 : 7)
                .stroke(SpyTheme.red.opacity(0.34), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(teammates.map(\.name).joined(separator: ", "))")
    }

    private var title: String {
        switch language {
        case .en: "SPY TEAM"
        case .es: "EQUIPO DE ESPIAS"
        case .ru: "КОМАНДА ШПИОНОВ"
        case .uk: "КОМАНДА ШПИГУНІВ"
        }
    }
}

struct MissionRoleCard: View {
    let role: MissionRoleCardContent
    let category: String?
    let theme: SpyCardThemeID
    let accent: Color
    let language: AppLanguage
    let isRevealed: Bool
    var size: MissionRoleCardSize = .hero

    @SpyReduceMotion private var reduceMotion

    init(
        role: MissionRoleCardContent,
        category: String? = nil,
        theme: SpyCardThemeID = .field,
        accent: Color = SpyTheme.red,
        language: AppLanguage = .ru,
        isRevealed: Bool,
        size: MissionRoleCardSize = .hero
    ) {
        self.role = role
        self.category = category
        self.theme = theme
        self.accent = accent
        self.language = language
        self.isRevealed = isRevealed
        self.size = size
    }

    var body: some View {
        ZStack {
            cardBack
                .modifier(
                    MissionCardFlipSide(
                        progress: isRevealed ? 1 : 0,
                        showsRevealedFace: false,
                        reduceMotion: reduceMotion
                    )
                )

            cardFace
                .modifier(
                    MissionCardFlipSide(
                        progress: isRevealed ? 1 : 0,
                        showsRevealedFace: true,
                        reduceMotion: reduceMotion
                    )
                )
        }
        .aspectRatio(0.75, contentMode: .fit)
        .frame(maxWidth: size.maximumWidth)
        .background {
            CutCornerShape(cut: size.cornerCut)
                .fill(Color.black.opacity(0.001))
                .shadow(
                    color: Color.black.opacity(0.72),
                    radius: size == .hero ? 22 : 14,
                    y: size == .hero ? 12 : 8
                )
        }
        .contentShape(CutCornerShape(cut: size.cornerCut))
        .animation(
            reduceMotion
                ? .linear(duration: 0.01)
                : .timingCurve(0.42, 0, 0.20, 1, duration: 0.68),
            value: isRevealed
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            role.onlineAccessibilityLabel(
                category: category,
                language: language,
                revealed: isRevealed
            )
        )
        .accessibilityValue(isRevealed ? copy.revealed : copy.concealed)
    }

    private var cardBack: some View {
        cardShell(stroke: Color.white.opacity(0.18), rail: cardAccent) {
            ZStack {
                cardBase(isSpy: false)

                VStack(spacing: size == .hero ? 16 : 9) {
                    Spacer(minLength: 0)

                    MissionCardBrandMark(compact: size == .compact)

                    SpyWordmark(fontSize: size == .hero ? 17 : 10)

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, cardAccent.opacity(0.86), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: size == .hero ? 76 : 42, height: 1)

                    if size == .hero {
                        Text(copy.tapToReveal)
                            .font(SpyTheme.brandFont(size: 14))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.94))
                            .lineLimit(1)
                            .minimumScaleFactor(0.64)
                    }

                    Spacer(minLength: 0)
                }
                .padding(size == .hero ? 32 : 18)
            }
        }
    }

    private var cardFace: some View {
        cardShell(
            stroke: role == .spy ? SpyTheme.red.opacity(0.82) : Color.white.opacity(0.20),
            rail: role == .spy ? SpyTheme.red : cardAccent
        ) {
            ZStack {
                cardBase(isSpy: role == .spy)

                faceContent
                    .padding(size == .hero ? 34 : 20)

                VStack {
                    SpyWordmark(fontSize: size == .hero ? 10 : 7)
                        .opacity(0.56)
                    Spacer()
                }
                .padding(.top, size == .hero ? 24 : 15)
            }
        }
    }

    @ViewBuilder
    private var faceContent: some View {
        switch role {
        case .spy:
            VStack(spacing: size == .hero ? 18 : 10) {
                Spacer(minLength: 0)

                Text(copy.spy)
                    .font(SpyTheme.brandFont(size: size == .hero ? 46 : 31))
                    .tracking(size == .hero ? 4.2 : 2.7)
                    .foregroundStyle(SpyTheme.red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)

                Rectangle()
                    .fill(SpyTheme.red.opacity(0.82))
                    .frame(width: size == .hero ? 52 : 34, height: 1)

                VStack(spacing: 4) {
                    Text(copy.theme)
                        .font(.system(size: size == .hero ? 9 : 7, weight: .black, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(SpyTheme.dim)

                    Text(normalizedCategory ?? copy.unknownTheme)
                        .font(SpyTheme.brandFont(size: size == .hero ? 17 : 11))
                        .tracking(1.3)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                }

                Spacer(minLength: 0)
            }

        case let .detective(word):
            Text(word.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
                .font(SpyTheme.brandFont(size: size == .hero ? 44 : 29))
                .tracking(size == .hero ? 2.0 : 1.3)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.34)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .spectator:
            Text(copy.spectator)
                .font(SpyTheme.brandFont(size: size == .hero ? 34 : 23))
                .tracking(2)
                .foregroundStyle(SpyTheme.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cardShell<Content: View>(
        stroke: Color,
        rail: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .clipShape(CutCornerShape(cut: size.cornerCut))
            .overlay {
                CutCornerShape(cut: size.cornerCut)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.28),
                                stroke,
                                Color.black.opacity(0.82)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: size == .hero ? 1.1 : 0.9
                    )
            }
            .overlay {
                MissionCardEdgeRails(accent: rail, compact: size == .compact)
                    .clipShape(CutCornerShape(cut: size.cornerCut))
            }
    }

    private func cardBase(isSpy: Bool) -> some View {
        ZStack {
            (isSpy ? Color(red: 0.048, green: 0.010, blue: 0.014) : Color(red: 0.035, green: 0.036, blue: 0.039))

            LinearGradient(
                colors: [
                    Color.white.opacity(0.032),
                    (isSpy ? SpyTheme.red : cardAccent).opacity(isSpy ? 0.045 : 0.018),
                    Color.black.opacity(0.34)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Color.white.opacity(0.045), .clear],
                center: UnitPoint(x: 0.16, y: 0.08),
                startRadius: 0,
                endRadius: size == .hero ? 230 : 150
            )

            SpyCardSurfacePattern(theme: theme, accent: isSpy ? SpyTheme.red : cardAccent)
                .opacity(isSpy ? 0.20 : 0.16)

            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.34)],
                startPoint: UnitPoint(x: 0.5, y: 0.52),
                endPoint: .bottom
            )
        }
    }

    private var normalizedCategory: String? {
        guard let category else { return nil }
        let value = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value.uppercased()
    }

    private var cardAccent: Color {
        role == .spy && isRevealed ? SpyTheme.red : accent
    }

    private var copy: SpyGameExperienceCopy { SpyGameExperienceCopy(language: language) }
}

private struct MissionCardFlipSide: @MainActor AnimatableModifier {
    var progress: Double
    let showsRevealedFace: Bool
    let reduceMotion: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let clampedProgress = min(max(progress, 0), 1)
        let angle = showsRevealedFace
            ? -180 + (clampedProgress * 180)
            : clampedProgress * 180
        let isVisible = showsRevealedFace
            ? clampedProgress >= 0.5
            : clampedProgress < 0.5

        content
            .compositingGroup()
            .opacity(isVisible ? 1 : 0)
            .rotation3DEffect(
                .degrees(reduceMotion ? 0 : angle),
                axis: (x: 0, y: 1, z: 0),
                anchor: .center,
                perspective: 0.78
            )
    }
}

private struct MissionCardBrandMark: View {
    let compact: Bool

    var body: some View {
        SpyBrandMark()
            .frame(width: compact ? 27 : 48, height: compact ? 31 : 55)
        .accessibilityHidden(true)
    }
}

private struct MissionCardEdgeRails: View {
    let accent: Color
    let compact: Bool

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = compact ? 10 : 15
            let railLength = size.width * (compact ? 0.19 : 0.23)

            var topRail = Path()
            topRail.move(to: CGPoint(x: inset, y: 1))
            topRail.addLine(to: CGPoint(x: inset + railLength, y: 1))
            context.stroke(topRail, with: .color(accent.opacity(0.72)), lineWidth: compact ? 1 : 1.3)

            var bottomRail = Path()
            bottomRail.move(to: CGPoint(x: size.width - inset - railLength, y: size.height - 1))
            bottomRail.addLine(to: CGPoint(x: size.width - inset, y: size.height - 1))
            context.stroke(bottomRail, with: .color(accent.opacity(0.28)), lineWidth: 1)

            var registration = Path()
            let bracket = compact ? CGFloat(9) : CGFloat(13)
            registration.move(to: CGPoint(x: inset, y: inset + bracket))
            registration.addLine(to: CGPoint(x: inset, y: inset))
            registration.addLine(to: CGPoint(x: inset + bracket, y: inset))
            registration.move(to: CGPoint(x: size.width - inset - bracket, y: size.height - inset))
            registration.addLine(to: CGPoint(x: size.width - inset, y: size.height - inset))
            registration.addLine(to: CGPoint(x: size.width - inset, y: size.height - inset - bracket))
            context.stroke(registration, with: .color(Color.white.opacity(0.10)), lineWidth: compact ? 0.6 : 0.8)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct SpyCinematicBackdrop: View {
    var intensity: CGFloat = 1

    @SpyReduceMotion private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion)) { timeline in
            GeometryReader { proxy in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate

                ZStack {
                    SpyBackground()

                    RadialGradient(
                        colors: [SpyTheme.red.opacity(0.035 * intensity), .clear],
                        center: UnitPoint(
                            x: 0.5 + sin(time * 0.13) * 0.09,
                            y: 0.52 + cos(time * 0.11) * 0.06
                        ),
                        startRadius: 0,
                        endRadius: max(proxy.size.width, proxy.size.height) * 0.62
                    )

                    RadialGradient(
                        colors: [Color.white.opacity(0.018 * intensity), .clear],
                        center: UnitPoint(
                            x: 0.72 + cos(time * 0.09) * 0.08,
                            y: 0.25 + sin(time * 0.08) * 0.05
                        ),
                        startRadius: 0,
                        endRadius: max(proxy.size.width, proxy.size.height) * 0.48
                    )

                    CinematicParticleField(time: time, intensity: intensity)
                        .opacity(0.44)
                        .mask {
                            RadialGradient(
                                colors: [.white, .white.opacity(0.72), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: max(proxy.size.width, proxy.size.height) * 0.72
                            )
                        }

                    LinearGradient(
                        colors: [Color.black.opacity(0.22), .clear, Color.black.opacity(0.24)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct CinematicParticleField: View {
    let time: TimeInterval
    let intensity: CGFloat

    var body: some View {
        Canvas { context, size in
            for index in 0..<22 {
                let seed = Double(index + 1)
                let baseX = (seed * 0.61803398875).truncatingRemainder(dividingBy: 1)
                let speed = 0.007 + (seed.truncatingRemainder(dividingBy: 5)) * 0.0016
                let baseY = (seed * 0.38196601125 + time * speed).truncatingRemainder(dividingBy: 1)
                let drift = sin(time * (0.18 + seed * 0.003) + seed) * 0.025
                let x = CGFloat(baseX + drift) * size.width
                let y = CGFloat(1 - baseY) * size.height
                let radius = CGFloat(index.isMultiple(of: 7) ? 1.9 : (index.isMultiple(of: 3) ? 1.1 : 0.65))
                let color = index.isMultiple(of: 5)
                    ? SpyTheme.red.opacity(0.20 * intensity)
                    : Color.white.opacity(0.10 * intensity)

                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: radius, height: radius)),
                    with: .color(color)
                )

                if index.isMultiple(of: 6) {
                    var trail = Path()
                    trail.move(to: CGPoint(x: x, y: y + radius))
                    trail.addLine(to: CGPoint(x: x, y: y + radius + 16))
                    context.stroke(trail, with: .linearGradient(
                        Gradient(colors: [color, .clear]),
                        startPoint: CGPoint(x: x, y: y),
                        endPoint: CGPoint(x: x, y: y + 18)
                    ), lineWidth: 0.5)
                }
            }
        }
    }
}

struct SpyCinematicButtonStyle: ButtonStyle {
    enum Variant {
        case primary
        case secondary
        case quiet
    }

    let variant: Variant

    @SpyReduceMotion private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SpyTheme.brandFont(size: 14))
            .tracking(1.25)
            .textCase(.uppercase)
            .foregroundStyle(foreground)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(background(configuration: configuration))
            .overlay(border)
            .clipShape(CutCornerShape(cut: 10))
            .contentShape(CutCornerShape(cut: 10))
            .shadow(
                color: shadowColor.opacity(configuration.isPressed ? 0.10 : 0.18),
                radius: configuration.isPressed ? 4 : 10,
                y: configuration.isPressed ? 2 : 5
            )
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.975 : 1))
            .offset(y: reduceMotion ? 0 : (configuration.isPressed ? 1.5 : 0))
            .animation(
                reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72),
                value: configuration.isPressed
            )
    }

    private var foreground: Color {
        switch variant {
        case .primary: .white
        case .secondary: .white.opacity(0.88)
        case .quiet: SpyTheme.dim
        }
    }

    private var shadowColor: Color {
        variant == .primary ? SpyTheme.red : .black
    }

    @ViewBuilder
    private func background(configuration: Configuration) -> some View {
        switch variant {
        case .primary:
            configuration.isPressed ? SpyTheme.redDeep : SpyTheme.red
        case .secondary:
            SpyTheme.control
        case .quiet:
            Color.clear
        }
    }

    @ViewBuilder
    private var border: some View {
        switch variant {
        case .primary:
            CutCornerShape(cut: 10)
                .stroke(SpyTheme.red, lineWidth: 1)
        case .secondary:
            CutCornerShape(cut: 10)
                .stroke(SpyTheme.strokeStrong, lineWidth: 1)
        case .quiet:
            EmptyView()
        }
    }
}

// MARK: - Synchronized start ritual

struct OnlineGameIntroScene: View {
    static let totalDuration: TimeInterval = 8

    let room: GameRoom
    let language: AppLanguage

    @SpyReduceMotion private var reduceMotion

    var body: some View {
        SpyGameIntroScene(
            participants: room.playersList.map {
                SpyGameIntroParticipant(id: $0.id, name: $0.name, avatar: $0.avatar)
            },
            spyCount: room.lobbySpyCountValue,
            language: language,
            startedAt: OnlineExperienceClock.date(from: room.introStartedAt) ?? .distantFuture,
            duration: Self.totalDuration,
            fixedProgress: debugFixedProgress,
            accessibilityIdentifier: "onlineExperience.intro"
        )
    }

    private func introStage(size: CGSize, progress: Double) -> some View {
        let deckPoint = CGPoint(x: size.width / 2, y: size.height * 0.65)
        let warningProgress = SpyExperienceMotion.segment(progress, from: 0.72, to: 0.84)
        let warningExit = SpyExperienceMotion.segment(progress, from: 0.90, to: 0.96)
        let warningOpacity = warningProgress * (1 - warningExit)
        let dimmedOpacity = 1 - warningProgress * 0.88
        let outro = SpyExperienceMotion.segment(progress, from: 0.94, to: 1)
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
            .blur(radius: warningProgress * 5)
            .offset(y: -warningProgress * 10)

            ForEach(Array(room.playersList.enumerated()), id: \.element.id) { index, player in
                let target = playerPosition(index: index, count: room.playersList.count, size: size)
                let appearance = reduceMotion
                    ? 1
                    : SpyExperienceMotion.easeOut(
                        SpyExperienceMotion.segment(
                            progress,
                            from: 0.11 + Double(index) * 0.018,
                            to: 0.29 + Double(index) * 0.018
                        )
                    )
                let window = dealWindow(index: index, count: room.playersList.count)
                let rawDeal = reduceMotion ? 1 : SpyExperienceMotion.segment(progress, from: window.start, to: window.end)
                let deal = reduceMotion ? 1 : SpyExperienceMotion.spring(rawDeal)
                let cardPoint = SpyExperienceMotion.arcPoint(
                    from: deckPoint,
                    to: CGPoint(x: target.x, y: target.y + 72),
                    progress: min(max(deal, 0), 1),
                    lift: 56 + abs(target.x - deckPoint.x) * 0.18
                )
                let landingPulse = SpyExperienceMotion.pulse(rawDeal, center: 0.88, width: 0.18)

                IntroOperativeIdentity(
                    player: player,
                    isReady: rawDeal > 0.82,
                    illumination: CGFloat(min(max(deal, 0), 1))
                )
                    .scaleEffect(0.82 + 0.18 * appearance + landingPulse * 0.035)
                    .opacity(appearance * dimmedOpacity)
                    .position(target)
                    .blur(radius: warningProgress * 3)

                CutCornerShape(cut: 10)
                    .stroke(SpyTheme.red.opacity(0.62), lineWidth: 1)
                    .frame(width: 66 + landingPulse * 24, height: 66 + landingPulse * 24)
                    .position(x: target.x, y: target.y + 12)
                    .opacity(landingPulse * dimmedOpacity)
                    .accessibilityHidden(true)

                IntroRoleCardBack()
                    .frame(width: min(42, size.width * 0.108))
                    .rotation3DEffect(
                        .degrees((Double(index % 3) - 1) * 12 * (1 - rawDeal)),
                        axis: (x: 0.22, y: 1, z: 0),
                        perspective: 0.72
                    )
                    .rotationEffect(.degrees((Double(index % 3) - 1) * 10 * (1 - rawDeal) + sin(rawDeal * .pi) * 7))
                    .scaleEffect(0.78 + min(max(deal, 0), 1) * 0.22)
                    .position(cardPoint)
                    .shadow(color: SpyTheme.red.opacity(0.28 * sin(rawDeal * .pi)), radius: 16)
                    .opacity((rawDeal > 0 ? 1 : 0) * dimmedOpacity)
                    .accessibilityHidden(true)
            }

            IntroCardDeck()
                .position(deckPoint)
                .scaleEffect(0.72 + 0.28 * deckReveal)
                .rotation3DEffect(.degrees((1 - deckReveal) * 26), axis: (x: 1, y: 0, z: 0), perspective: 0.68)
                .opacity(deckReveal * (1 - SpyExperienceMotion.segment(progress, from: 0.68, to: 0.78)) * dimmedOpacity)
                .shadow(color: SpyTheme.red.opacity(0.22), radius: 24, y: 14)

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
                .opacity((1 - warningProgress) * warningProgress * 2.2)
                .position(x: size.width / 2, y: size.height * 0.49)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                Text(copy.spyTeam(spyCount: room.lobbySpyCountValue))
                    .foregroundStyle(SpyTheme.red)
                Text(copy.amongYou)
                    .foregroundStyle(.white)
            }
            .font(SpyTheme.brandFont(size: min(48, size.width * 0.125)))
            .tracking(2.5)
            .multilineTextAlignment(.center)
            .shadow(color: SpyTheme.red.opacity(0.28), radius: 30)
            .scaleEffect(0.72 + 0.28 * SpyExperienceMotion.spring(warningProgress))
            .blur(radius: (1 - warningProgress) * 14 + warningExit * 6)
            .opacity(warningOpacity)
            .position(x: size.width / 2, y: size.height * 0.49)

            Color.black
                .opacity(outro)
                .allowsHitTesting(false)
        }
    }

    private func dealWindow(index: Int, count: Int) -> (start: Double, end: Double) {
        let intervals = max(count - 1, 1)
        let spacing = min(0.058, 0.22 / Double(intervals))
        let start = 0.29 + Double(index) * spacing
        return (start, start + 0.24)
    }

    private func playerPosition(index: Int, count: Int, size: CGSize) -> CGPoint {
        guard count > 0 else { return CGPoint(x: size.width / 2, y: size.height * 0.26) }
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
        if let debugFixedProgress { return debugFixedProgress }
        if reduceMotion { return 0.82 }
        guard let startedAt = OnlineExperienceClock.date(from: room.introStartedAt) else { return 0 }
        return min(max(date.timeIntervalSince(startedAt) / Self.totalDuration, 0), 1)
    }

    @MainActor
    private func playIntroHaptics() async {
        guard !reduceMotion,
              debugFixedProgress == nil,
              let startedAt = OnlineExperienceClock.date(from: room.introStartedAt) else { return }

        let count = max(room.playersList.count, 1)
        for index in room.playersList.indices {
            let window = dealWindow(index: index, count: count)
            let targetDate = startedAt.addingTimeInterval(Self.totalDuration * (window.start + 0.18))
            let delay = targetDate.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            HapticManager.shared.fire(.navigation)
        }

        let warningDate = startedAt.addingTimeInterval(Self.totalDuration * 0.74)
        let warningDelay = warningDate.timeIntervalSinceNow
        if warningDelay > 0 {
            try? await Task.sleep(for: .seconds(warningDelay))
        }
        guard !Task.isCancelled else { return }
        HapticManager.shared.fire(.reveal)
    }

    private var debugFixedProgress: Double? {
#if DEBUG
        let prefix = "--spyclash-online-intro-progress="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }),
              let value = Double(argument.dropFirst(prefix.count)) else { return nil }
        return min(max(value, 0), 1)
#else
        return nil
#endif
    }

    private var copy: SpyGameExperienceCopy { SpyGameExperienceCopy(language: language) }
}

private struct IntroOperativeIdentity: View {
    let player: Player
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

                Text(player.avatar.isEmpty ? String(player.name.prefix(1)).uppercased() : player.avatar)
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

            Text(player.name.uppercased())
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
}

private struct IntroRoleCardBack: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                SpyTheme.card

                SpyCardSurfacePattern(theme: .field, accent: SpyTheme.red)
                    .opacity(0.44)

                VStack(spacing: 3) {
                    MissionCardBrandMark(compact: true)
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
    }
}

private struct IntroCardDeck: View {
    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                IntroRoleCardBack()
                    .frame(width: 76)
                    .offset(x: CGFloat(index) * 2.4 - 4, y: CGFloat(index) * -2.8 + 5)
                    .rotationEffect(.degrees(Double(index) * 1.55 - 2.3))
            }
        }
    }
}

// MARK: - Role reveal and ready gate

enum OnlineRoleRevealInteractionPolicy {
    static func canToggleRoleCard(isConfirmed _: Bool, isConfirming: Bool) -> Bool {
        !isConfirming
    }
}

struct OnlineRoleRevealScene: View {
    let room: GameRoom
    let language: AppLanguage
    let role: MissionRoleCardContent
    let cardTheme: SpyCardThemeID
    let cardAccent: Color
    let currentUserEmail: String?
    let isRevealed: Bool
    var isConfirming = false
    let onReveal: () -> Void
    let onConfirm: () -> Void
    let onLeave: () -> Void

    @SpyReduceMotion private var reduceMotion
    @State private var hasEntered = false

    init(
        room: GameRoom,
        language: AppLanguage,
        role: MissionRoleCardContent,
        cardTheme: SpyCardThemeID = .field,
        cardAccent: Color = SpyTheme.red,
        currentUserEmail: String?,
        isRevealed: Bool,
        isConfirming: Bool = false,
        onReveal: @escaping () -> Void,
        onConfirm: @escaping () -> Void,
        onLeave: @escaping () -> Void
    ) {
        self.room = room
        self.language = language
        self.role = role
        self.cardTheme = cardTheme
        self.cardAccent = cardAccent
        self.currentUserEmail = currentUserEmail
        self.isRevealed = isRevealed
        self.isConfirming = isConfirming
        self.onReveal = onReveal
        self.onConfirm = onConfirm
        self.onLeave = onLeave
    }

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(286, proxy.size.width * 0.73, max(180, (proxy.size.height - 260) * 0.75))

            ZStack {
                SpyCinematicBackdrop(intensity: isRevealed ? 0.92 : 0.70)

                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        SpyWordmark(fontSize: 24)

                        Spacer(minLength: 10)

                        Text("// \(room.code.uppercased())")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1.8)
                            .foregroundStyle(SpyTheme.dim)
                    }
                    .padding(.horizontal, 22)
                    .frame(height: 64)
                    .background(Color.black.opacity(0.82))
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(SpyTheme.stroke)
                            .frame(height: 1)
                    }
                    .opacity(hasEntered ? 1 : 0)
                    .offset(y: hasEntered ? 0 : -12)

                    ZStack(alignment: .top) {
                        VStack(spacing: 0) {
                            VStack(spacing: 4) {
                                Text(copy.personalCard)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .tracking(2.2)
                                    .foregroundStyle(SpyTheme.red)

                                if let currentPlayer {
                                    HStack(spacing: 8) {
                                        Text(currentPlayer.avatar)
                                            .font(.system(size: 24))
                                        Text(currentPlayer.name.uppercased())
                                            .font(SpyTheme.brandFont(size: 21))
                                            .tracking(1.2)
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .padding(.top, 18)
                            .opacity(hasEntered ? 1 : 0)
                            .blur(radius: hasEntered ? 0 : 8)

                            Spacer(minLength: 10)

                            Button(action: toggleReveal) {
                                MissionRoleCard(
                                    role: displayedRole,
                                    category: room.category,
                                    theme: cardTheme,
                                    accent: cardAccent,
                                    language: language,
                                    isRevealed: isRevealed,
                                    size: .hero
                                )
                                .frame(width: cardWidth)
                            }
                            .buttonStyle(SpyWebPressStyle(pressedScale: 0.98))
                            .scaleEffect(hasEntered ? 1 : 0.78)
                            .offset(y: hasEntered ? 0 : 86)
                            .rotation3DEffect(
                                .degrees(hasEntered ? 0 : 18),
                                axis: (x: 1, y: 0.08, z: 0),
                                perspective: 0.66
                            )
                            .disabled(
                                !OnlineRoleRevealInteractionPolicy.canToggleRoleCard(
                                    isConfirmed: isCurrentPlayerConfirmed,
                                    isConfirming: isConfirming
                                )
                            )
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(
                                displayedRole.onlineAccessibilityLabel(
                                    category: room.category,
                                    language: language,
                                    revealed: isRevealed
                                )
                            )
                            .accessibilityValue(isRevealed ? copy.revealed : copy.concealed)
                            .accessibilityHint(isRevealed ? copy.tapToConceal : copy.tapToReveal)
                            .accessibilityIdentifier("onlineExperience.roleCard")

                            if isRevealed, !revealedSpyTeammates.isEmpty {
                                SpyRoleCardTeammateStrip(
                                    teammates: revealedSpyTeammates.map {
                                        SpyRoleCardIdentity(id: $0.id, name: $0.name, avatar: $0.avatar)
                                    },
                                    language: language
                                )
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            Spacer(minLength: 10)

                            bottomState
                                .padding(.horizontal, 20)
                                .animation(.spring(response: 0.52, dampingFraction: 0.82), value: isRevealed)
                                .animation(.spring(response: 0.52, dampingFraction: 0.82), value: isCurrentPlayerConfirmed)

                            Button(action: onLeave) {
                                Text(copy.leaveGame)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .tracking(1.2)
                                    .foregroundStyle(SpyTheme.dim)
                                    .frame(minHeight: 42)
                            }
                            .buttonStyle(SpyWebPressStyle())
                            .accessibilityIdentifier("onlineExperience.leave")
                            .padding(.bottom, 6)
                        }

                    }
                }
            }
        }
        .task {
            if reduceMotion {
                hasEntered = true
                return
            }

            withAnimation(.spring(response: 0.86, dampingFraction: 0.78)) {
                hasEntered = true
            }
        }
    }

    @ViewBuilder
    private var bottomState: some View {
        if isCurrentPlayerConfirmed {
            VStack(spacing: 14) {
                Text(copy.waitingCount(room.cardsReadList.count, room.playersList.count))
                    .font(SpyTheme.brandFont(size: 20))
                    .tracking(1.4)
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(room.playersList) { player in
                            let checked = room.cardsReadList.contains(player.email)
                            ZStack(alignment: .bottomTrailing) {
                                CutCornerShape(cut: 6)
                                    .fill(SpyTheme.control)
                                    .frame(width: 42, height: 42)
                                    .overlay {
                                        CutCornerShape(cut: 6)
                                            .stroke(checked ? SpyTheme.green.opacity(0.72) : SpyTheme.strokeStrong, lineWidth: 1)
                                    }
                                Text(player.avatar)
                                    .font(.system(size: 20))
                                    .frame(width: 42, height: 42)
                                    .saturation(checked ? 1 : 0.18)
                                    .opacity(checked ? 1 : 0.48)
                                Rectangle()
                                    .fill(checked ? SpyTheme.green : SpyTheme.dim)
                                    .frame(width: 7, height: 7)
                                    .offset(x: 2, y: 2)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(copy.waitingCount(room.cardsReadList.count, room.playersList.count))
                .accessibilityIdentifier("onlineExperience.cardsReadRoster")
            }
            .accessibilityIdentifier("onlineExperience.waiting")
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if isRevealed {
            Button(action: confirmRole) {
                HStack(spacing: 9) {
                    if isConfirming {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .black))
                    }
                    Text(copy.cardViewed)
                }
            }
            .buttonStyle(SpyCinematicButtonStyle(variant: .primary))
            .disabled(isConfirming)
            .accessibilityIdentifier("onlineExperience.confirmRole")
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else {
            Color.clear
                .frame(height: 56)
                .accessibilityHidden(true)
        }
    }

    private func toggleReveal() {
        guard OnlineRoleRevealInteractionPolicy.canToggleRoleCard(
            isConfirmed: isCurrentPlayerConfirmed,
            isConfirming: isConfirming
        ) else { return }
        onReveal()
    }

    private func confirmRole() {
        guard !isConfirming, !isCurrentPlayerConfirmed else { return }
        HapticManager.shared.fire(.milestone)
        onConfirm()
    }

    private var currentPlayer: Player? {
        guard let currentUserEmail else { return nil }
        return room.playersList.first { $0.email == currentUserEmail }
    }

    private var isCurrentPlayerConfirmed: Bool {
        guard let currentUserEmail else { return false }
        return room.spectatorsList.contains(currentUserEmail) || room.cardsReadList.contains(currentUserEmail)
    }

    private var displayedRole: MissionRoleCardContent {
        guard let currentUserEmail, !room.spectatorsList.contains(currentUserEmail) else { return .spectator }
        return role
    }

    private var revealedSpyTeammates: [Player] {
        guard isRevealed,
              room.spiesKnowEachOther == true,
              room.isSpy(email: currentUserEmail) else { return [] }
        return room.spyPlayers.filter {
            !OnlineVoteIdentityPolicy.matches($0.email, currentUserEmail)
        }
    }

    private var copy: SpyGameExperienceCopy { SpyGameExperienceCopy(language: language) }
}

// MARK: - Active online game

struct OnlineVoteRequestFeedback: Equatable {
    let displayedCount: Int
    let isAwaitingServer: Bool
    let isRecorded: Bool

    static func resolve(
        serverRequestEmails: [String],
        currentUserEmail: String?,
        submissionPending: Bool,
        threshold: Int
    ) -> OnlineVoteRequestFeedback {
        let isRecorded = serverRequestEmails.contains {
            OnlineVoteIdentityPolicy.matches($0, currentUserEmail)
        }
        let isAwaitingServer = submissionPending && !isRecorded
        let displayedCount = min(
            max(serverRequestEmails.count + (isAwaitingServer ? 1 : 0), 0),
            max(threshold, 0)
        )
        return OnlineVoteRequestFeedback(
            displayedCount: displayedCount,
            isAwaitingServer: isAwaitingServer,
            isRecorded: isRecorded
        )
    }
}

enum OnlineVoteCandidateFeedback: Equatable {
    case idle
    case awaitingServer
    case recorded

    static func resolve(
        candidateEmail: String,
        authoritativeVoteEmail: String?,
        pendingVoteEmail: String?
    ) -> OnlineVoteCandidateFeedback {
        if OnlineVoteIdentityPolicy.matches(authoritativeVoteEmail, candidateEmail) {
            return .recorded
        }
        if authoritativeVoteEmail == nil,
           OnlineVoteIdentityPolicy.matches(pendingVoteEmail, candidateEmail) {
            return .awaitingServer
        }
        return .idle
    }
}

struct OnlineActiveGameScene: View {
    let room: GameRoom
    let language: AppLanguage
    let role: MissionRoleCardContent
    let cardTheme: SpyCardThemeID
    let cardAccent: Color
    let currentUserEmail: String?
    let isHost: Bool
    let isRoleRevealed: Bool
    let roundCommand: OnlineRoundCommand?
    let isRoundTransitioning: Bool
    let canStopAssociationSpin: Bool
    let showsVoteRequest: Bool
    let canRequestVote: Bool
    let isVoteRequestPending: Bool
    let canSpyGuess: Bool
    let canCastVote: Bool
    let pendingVoteTargetEmail: String?
    let lobbyReturn: ActiveLobbyReturnPresentation
    let onToggleRole: () -> Void
    let onTogglePause: () -> Void
    let onRoundCommand: (OnlineRoundCommand) -> Void
    let onCountdownElapsed: () -> Void
    let onAssociationSpinElapsed: () -> Void
    let onRequestVote: () -> Void
    let onCastVote: (String) -> Void
    let onSpyGuess: () -> Void
    let onToggleLobbyReturn: () -> Void
    let onLeave: () -> Void

    @State private var isConfirmingLeave = false
    @State private var handledCountdownEventID: String?
    @State private var handledAssociationSpinEventID: String?

    init(
        room: GameRoom,
        language: AppLanguage,
        role: MissionRoleCardContent,
        cardTheme: SpyCardThemeID = .field,
        cardAccent: Color = SpyTheme.red,
        currentUserEmail: String?,
        isHost: Bool,
        isRoleRevealed: Bool,
        roundCommand: OnlineRoundCommand?,
        isRoundTransitioning: Bool,
        canStopAssociationSpin: Bool,
        showsVoteRequest: Bool,
        canRequestVote: Bool,
        isVoteRequestPending: Bool = false,
        canSpyGuess: Bool,
        canCastVote: Bool = true,
        pendingVoteTargetEmail: String? = nil,
        lobbyReturn: ActiveLobbyReturnPresentation = .unavailable,
        onToggleRole: @escaping () -> Void,
        onTogglePause: @escaping () -> Void,
        onRoundCommand: @escaping (OnlineRoundCommand) -> Void,
        onCountdownElapsed: @escaping () -> Void,
        onAssociationSpinElapsed: @escaping () -> Void,
        onRequestVote: @escaping () -> Void,
        onCastVote: @escaping (String) -> Void,
        onSpyGuess: @escaping () -> Void,
        onToggleLobbyReturn: @escaping () -> Void = {},
        onLeave: @escaping () -> Void
    ) {
        self.room = room
        self.language = language
        self.role = role
        self.cardTheme = cardTheme
        self.cardAccent = cardAccent
        self.currentUserEmail = currentUserEmail
        self.isHost = isHost
        self.isRoleRevealed = isRoleRevealed
        self.roundCommand = roundCommand
        self.isRoundTransitioning = isRoundTransitioning
        self.canStopAssociationSpin = canStopAssociationSpin
        self.showsVoteRequest = showsVoteRequest
        self.canRequestVote = canRequestVote
        self.isVoteRequestPending = isVoteRequestPending
        self.canSpyGuess = canSpyGuess
        self.canCastVote = canCastVote
        self.pendingVoteTargetEmail = pendingVoteTargetEmail
        self.lobbyReturn = lobbyReturn
        self.onToggleRole = onToggleRole
        self.onTogglePause = onTogglePause
        self.onRoundCommand = onRoundCommand
        self.onCountdownElapsed = onCountdownElapsed
        self.onAssociationSpinElapsed = onAssociationSpinElapsed
        self.onRequestVote = onRequestVote
        self.onCastVote = onCastVote
        self.onSpyGuess = onSpyGuess
        self.onToggleLobbyReturn = onToggleLobbyReturn
        self.onLeave = onLeave
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            GeometryReader { proxy in
                ZStack {
                    SpyCinematicBackdrop(intensity: room.isVotingActive ? 1.02 : 0.84)

                    VStack(spacing: 0) {
                        gameBrandHeader

                        if lobbyReturn.isAvailable {
                            lobbyReturnControl(
                                accessibilityID: "onlineExperience.returnToLobbyVote"
                            )
                        }

                        ZStack(alignment: .top) {
                            VStack(spacing: 0) {
                                timerHeader(at: timeline.date)
                                    .padding(.horizontal, 22)
                                    .padding(.top, 14)

                                operativeRail
                                    .padding(.top, 4)

                                centralStage(
                                    maxCardWidth: min(205, max(164, (proxy.size.height - 480) * 0.76)),
                                    maxVotingHeight: min(284, max(180, proxy.size.height * 0.31))
                                )
                                    .frame(maxHeight: .infinity)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 8)
                                    .layoutPriority(1)

                                commandArea
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 8)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .layoutPriority(3)
                                    .zIndex(10)
                            }

                        }
                    }

                    if room.isGamePaused {
                        pausedOverlay
                            .transition(.opacity)
                            .zIndex(20)
                    }
                }
            }
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.84), value: room.isGamePaused)
        .animation(.spring(response: 0.54, dampingFraction: 0.82), value: room.isVotingActive)
        .animation(.spring(response: 0.54, dampingFraction: 0.82), value: room.currentAskerEmail)
        .animation(.spring(response: 0.54, dampingFraction: 0.82), value: room.currentAnswererEmail)
        .animation(.spring(response: 0.44, dampingFraction: 0.84), value: room.questionPhase)
        .confirmationDialog(
            isHost ? copy.closeGame : copy.leaveGame,
            isPresented: $isConfirmingLeave,
            titleVisibility: .visible
        ) {
            Button(isHost ? copy.closeGame : copy.leaveGame, role: .destructive, action: leave)
            Button(copy.cancel, role: .cancel) {}
        }
        .task(id: countdownTaskID) {
            await advanceCountdownIfNeeded()
        }
        .task(id: associationSpinTaskID) {
            await stopAssociationSpinIfNeeded()
        }
    }

    private func timerHeader(at date: Date) -> some View {
        let timer = OnlineTimerSnapshot(room: room, now: date)

        return VStack(spacing: 6) {
            Text(
                timer.isExpired
                    ? copy.spyWinsAtDeadline(spyCount: room.lobbySpyCountValue)
                    : copy.playingRound(max(room.roundNumber ?? 1, 1))
            )
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(timer.isExpired ? SpyTheme.red : SpyTheme.dim)

            Text(timer.formatted)
                .font(SpyTheme.brandFont(size: 58))
                .tracking(1.4)
                .monospacedDigit()
                .foregroundStyle(timer.isCritical ? SpyTheme.red : .white)
                .contentTransition(.numericText(countsDown: true))

            GeometryReader { bar in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(SpyTheme.stroke)
                    Rectangle()
                        .fill(timer.isCritical ? SpyTheme.red : SpyTheme.redDeep)
                        .frame(width: bar.size.width * timer.progress)
                        .animation(.linear(duration: 0.9), value: timer.progress)
                }
            }
            .frame(height: 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onlineExperience.timer")
    }

    private var gameBrandHeader: some View {
        HStack(spacing: 10) {
            SpyWordmark(fontSize: 24)

            Spacer(minLength: 10)

            headerControl(
                systemImage: "rectangle.portrait.and.arrow.right",
                accessibilityLabel: isHost ? copy.closeGame : copy.leaveGame,
                accessibilityID: "onlineExperience.leave",
                action: requestLeave
            )

            if isHost {
                headerControl(
                    systemImage: room.isGamePaused ? "play.fill" : "pause.fill",
                    accessibilityLabel: room.isGamePaused ? copy.resume : copy.pause,
                    accessibilityID: "onlineExperience.pauseResume",
                    action: togglePause
                )
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
        .background(Color.black.opacity(0.82))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SpyTheme.stroke)
                .frame(height: 1)
        }
    }

    private func lobbyReturnControl(accessibilityID: String) -> some View {
        let accent = lobbyReturn.hasFailed
            ? SpyTheme.amber
            : (lobbyReturn.isSelected ? SpyTheme.red : Color.white.opacity(0.72))

        return HStack(spacing: 10) {
            Button(action: toggleLobbyReturn) {
                HStack(spacing: 8) {
                    ZStack {
                        if lobbyReturn.isPending {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(accent)
                        } else {
                            Image(
                                systemName: lobbyReturn.hasFailed
                                    ? "arrow.clockwise"
                                    : (lobbyReturn.isSelected ? "checkmark.circle.fill" : "arrow.uturn.backward.circle")
                            )
                            .font(.system(size: 13, weight: .black))
                        }
                    }
                    .frame(width: 16, height: 16)

                    Text(copy.returnToLobby)
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(0.75)
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 11)
                .frame(minHeight: OnlineInteractionHitTargetPolicy.minimumSize)
                .background(accent.opacity(lobbyReturn.isSelected ? 0.13 : 0.055), in: CutCornerShape(cut: 6))
                .overlay {
                    CutCornerShape(cut: 6)
                        .stroke(accent.opacity(lobbyReturn.isSelected ? 0.72 : 0.32), lineWidth: 1)
                }
                .contentShape(CutCornerShape(cut: 6))
            }
            .buttonStyle(SpyWebPressStyle(pressedScale: 0.96))
            .disabled(lobbyReturn.isPending)
            .accessibilityIdentifier(accessibilityID)
            .accessibilityLabel(
                lobbyReturn.hasFailed
                    ? copy.retryReturnToLobby
                    : (lobbyReturn.isSelected ? copy.cancelReturnToLobby : copy.returnToLobby)
            )
            .accessibilityValue(
                copy.returnToLobbyAccessibilityValue(
                    votes: lobbyReturn.voteCount,
                    players: lobbyReturn.playerCount,
                    selected: lobbyReturn.isSelected,
                    pending: lobbyReturn.isPending,
                    failed: lobbyReturn.hasFailed
                )
            )

            Spacer(minLength: 8)

            Text("\(lobbyReturn.voteCount) / \(lobbyReturn.playerCount)")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(lobbyReturn.isSelected ? SpyTheme.red : SpyTheme.dim)
                .contentTransition(.numericText())
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(Color.black.opacity(0.88))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SpyTheme.stroke)
                .frame(height: 1)
        }
        .animation(.easeOut(duration: 0.16), value: lobbyReturn)
    }

    private func headerControl(
        systemImage: String,
        accessibilityLabel: String,
        accessibilityID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color.white.opacity(0.88))
                .frame(width: 38, height: 38)
                .background(SpyTheme.control, in: CutCornerShape(cut: 6))
                .overlay {
                    CutCornerShape(cut: 6)
                        .stroke(SpyTheme.strokeStrong, lineWidth: 1)
                }
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.94))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityID)
    }

    private var operativeRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(room.playersList) { player in
                    let isCurrent = player.email == currentUserEmail
                    let isTurn = player.email == room.currentAskerEmail || player.email == room.currentAnswererEmail
                    let isEliminated = room.eliminatedEmails?.contains(player.email) ?? false
                    let isRevealedSpy = room.revealedSpyEmails?.contains(where: {
                        OnlineVoteIdentityPolicy.matches($0, player.email)
                    }) == true

                    VStack(spacing: 4) {
                        ZStack {
                            CutCornerShape(cut: 6)
                                .fill(SpyTheme.control)
                                .frame(width: 38, height: 38)
                                .overlay {
                                    CutCornerShape(cut: 6)
                                        .stroke(
                                            isTurn
                                                ? SpyTheme.red
                                                : (isCurrent ? Color.white.opacity(0.38) : SpyTheme.strokeStrong),
                                            lineWidth: isTurn ? 1.5 : 1
                                        )
                                }

                            Text(player.avatar.isEmpty ? String(player.name.prefix(1)).uppercased() : player.avatar)
                                .font(.system(size: 20))
                                .frame(width: 38, height: 38)
                                .saturation(isEliminated ? 0 : 1)
                        }

                        Text(player.name.uppercased())
                            .font(SpyTheme.brandFont(size: 9))
                            .tracking(0.7)
                            .foregroundStyle(isEliminated ? SpyTheme.dim : .white)
                            .strikethrough(isEliminated, color: SpyTheme.red)
                            .lineLimit(1)
                            .frame(width: 64)

                        if isRevealedSpy {
                            Text(copy.spy)
                                .font(.system(size: 7, weight: .black, design: .monospaced))
                                .tracking(0.6)
                                .foregroundStyle(SpyTheme.red)
                        } else {
                            Rectangle()
                                .fill(isTurn ? SpyTheme.red : (isCurrent ? Color.white.opacity(0.58) : SpyTheme.stroke))
                                .frame(width: isTurn ? 24 : 10, height: 1)
                        }
                    }
                    .opacity(isEliminated ? 0.48 : 1)
                    .scaleEffect(isTurn ? 1.04 : 1)
                    .accessibilityValue(isRevealedSpy ? copy.spy : "")
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 66)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onlineExperience.players")
    }

    private func centralStage(maxCardWidth: CGFloat, maxVotingHeight: CGFloat) -> some View {
        ZStack {
            VStack(spacing: 12) {
                if room.onlineRoundPhase != .results {
                    VStack(spacing: 7) {
                        Button(action: onToggleRole) {
                            MissionRoleCard(
                                role: role,
                                category: room.category,
                                theme: cardTheme,
                                accent: cardAccent,
                                language: language,
                                isRevealed: isRoleRevealed,
                                size: .compact
                            )
                            .frame(width: maxCardWidth)
                        }
                        .buttonStyle(SpyWebPressStyle(pressedScale: 0.98))
                        .accessibilityIdentifier("onlineExperience.compactRoleCard")

                        if isRoleRevealed, !revealedSpyTeammates.isEmpty {
                            SpyRoleCardTeammateStrip(
                                teammates: revealedSpyTeammates.map {
                                    SpyRoleCardIdentity(id: $0.id, name: $0.name, avatar: $0.avatar)
                                },
                                language: language,
                                compact: true
                            )
                            .transition(.opacity)
                        }
                    }
                }

                if !room.isVotingActive {
                    roundStage(maxHeight: maxVotingHeight)
                }
            }
            .opacity(room.isVotingActive ? 0 : 1)

            if room.isVotingActive {
                votingStage(maxHeight: maxVotingHeight)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
    }

    @ViewBuilder
    private func roundStage(maxHeight: CGFloat) -> some View {
        if room.onlineRoundPhase == .results {
            roundResultsStage(maxHeight: maxHeight)
        } else if room.gameModeValue == .associations {
            associationStage
        } else {
            activePairStrip
        }
    }

    private var associationStage: some View {
        let state = room.associationRoundState
        let speaker = player(email: room.currentAskerEmail)

        return VStack(spacing: 10) {
            Text(state.spinning ? copy.selectingSpeaker : copy.currentSpeaker)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(state.spinning ? SpyTheme.red : SpyTheme.dim)

            ZStack {
                CutCornerShape(cut: 8)
                    .fill(SpyTheme.control)
                    .frame(width: 58, height: 58)
                    .overlay {
                        CutCornerShape(cut: 8)
                            .stroke(state.spinning ? SpyTheme.red : SpyTheme.strokeStrong, lineWidth: 1)
                    }

                if state.spinning {
                    ProgressView()
                        .tint(SpyTheme.red)
                        .controlSize(.large)
                } else {
                    Text(speaker?.avatar ?? "?")
                        .font(.system(size: 30))
                }
            }

            Text(state.spinning ? copy.signalScanning : (speaker?.name.uppercased() ?? copy.pending))
                .font(SpyTheme.brandFont(size: 16))
                .tracking(1)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.58)

            Text(copy.associationProgress(state.spoken.count, room.activePlayers.count))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(SpyTheme.dim)
        }
        .frame(maxWidth: .infinity, minHeight: 142)
        .background(Color.black.opacity(0.76), in: CutCornerShape(cut: 9))
        .overlay {
            CutCornerShape(cut: 9)
                .stroke(state.spinning ? SpyTheme.red.opacity(0.54) : SpyTheme.strokeStrong, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onlineExperience.associationState")
    }

    private func roundResultsStage(maxHeight: CGFloat) -> some View {
        VStack(spacing: 10) {
            Text(copy.roundResults)
                .font(SpyTheme.brandFont(size: 23))
                .tracking(1.4)
                .foregroundStyle(.white)

            ScrollView(.vertical, showsIndicators: roundResultPlayers.count > 4) {
                LazyVStack(spacing: 7) {
                    ForEach(roundResultPlayers.indices, id: \.self) { index in
                        let player = roundResultPlayers[index]
                        HStack(spacing: 10) {
                            Text(String(format: "%02d", index + 1))
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .foregroundStyle(index == 0 ? SpyTheme.red : SpyTheme.dim)

                            Text(player.avatar)
                                .font(.system(size: 20))

                            Text(player.name.uppercased())
                                .font(SpyTheme.brandFont(size: 13))
                                .tracking(0.8)
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            Text(formattedRoundScore(for: player))
                                .font(.system(size: 12, weight: .black, design: .monospaced))
                                .foregroundStyle(roundScore(for: player) >= 0 ? SpyTheme.green : SpyTheme.red)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(Color.black.opacity(0.52), in: CutCornerShape(cut: 6))
                        .overlay {
                            CutCornerShape(cut: 6)
                                .stroke(index == 0 ? SpyTheme.red.opacity(0.34) : SpyTheme.stroke, lineWidth: 1)
                        }
                    }
                }
            }
            .frame(maxHeight: maxHeight)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onlineExperience.roundResults")
    }

    private var activePairStrip: some View {
        HStack(spacing: 10) {
            pairIdentity(
                title: copy.asks,
                player: player(email: room.currentAskerEmail),
                color: SpyTheme.red,
                alignment: .leading
            )

            ZStack {
                Rectangle()
                    .fill(SpyTheme.red.opacity(0.72))
                    .frame(width: 44, height: 1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(SpyTheme.red)
                    .padding(.horizontal, 6)
                    .background(SpyTheme.control)
            }

            pairIdentity(
                title: copy.answers,
                player: player(email: room.currentAnswererEmail),
                color: .white,
                alignment: .trailing
            )
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 76)
        .background(Color.black.opacity(0.76), in: CutCornerShape(cut: 9))
        .overlay {
            CutCornerShape(cut: 9)
                .stroke(SpyTheme.strokeStrong, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func pairIdentity(
        title: String,
        player: Player?,
        color: Color,
        alignment: HorizontalAlignment
    ) -> some View {
        HStack(spacing: 8) {
            if alignment == .trailing {
                pairText(title: title, player: player, color: color, alignment: .trailing)
            }

            ZStack {
                CutCornerShape(cut: 7)
                    .fill(SpyTheme.control)
                    .frame(width: 42, height: 42)
                    .overlay {
                        CutCornerShape(cut: 7)
                            .stroke(color.opacity(0.66), lineWidth: 1)
                    }
                Text(player?.avatar ?? "•")
                    .font(.system(size: 21))
            }

            if alignment == .leading {
                pairText(title: title, player: player, color: color, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id("\(title)-\(player?.email ?? "pending")")
        .transition(.opacity.combined(with: .scale(scale: 0.90)))
    }

    private func pairText(
        title: String,
        player: Player?,
        color: Color,
        alignment: TextAlignment
    ) -> some View {
        VStack(alignment: alignment == .leading ? .leading : .trailing, spacing: 3) {
            Text(title)
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(color)
            Text(player?.name.uppercased() ?? copy.pending)
                .font(SpyTheme.brandFont(size: 14))
                .tracking(0.7)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.58)
        }
    }

    private func votingStage(maxHeight: CGFloat) -> some View {
        VStack(spacing: 12) {
            Text(copy.chooseSuspect)
                .font(SpyTheme.brandFont(size: 22))
                .tracking(1.2)
                .foregroundStyle(.white)

            VStack(spacing: 3) {
                Text(
                    copy.exclusionRequirement(
                        required: room.exclusionVoteThreshold,
                        total: room.activePlayers.count
                    )
                )
                .foregroundStyle(SpyTheme.red)

                Text(copy.impossibleVoteCancels)
                    .foregroundStyle(SpyTheme.dim)
            }
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.64)

            ScrollView(.vertical, showsIndicators: votingCandidates.count > 6) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(votingCandidates) { candidate in
                    let feedback = OnlineVoteCandidateFeedback.resolve(
                        candidateEmail: candidate.email,
                        authoritativeVoteEmail: myVote?.votedForEmail,
                        pendingVoteEmail: pendingVoteTargetEmail
                    )
                    let selected = feedback != .idle
                    Button {
                        castVote(candidate.email)
                    } label: {
                        VStack(spacing: 7) {
                            ZStack {
                                CutCornerShape(cut: 8)
                                    .fill(SpyTheme.control)
                                    .frame(width: 52, height: 52)
                                    .overlay {
                                        CutCornerShape(cut: 8)
                                            .stroke(selected ? SpyTheme.red : Color.white.opacity(0.14), lineWidth: selected ? 1.5 : 1)
                                    }

                                Text(candidate.avatar)
                                    .font(.system(size: 26))

                                if feedback == .recorded {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .black))
                                        .foregroundStyle(.black)
                                        .frame(width: 17, height: 17)
                                        .background(SpyTheme.green, in: CutCornerShape(cut: 4))
                                        .offset(x: 20, y: 20)
                                } else if feedback == .awaitingServer {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .tint(.white)
                                        .frame(width: 17, height: 17)
                                        .background(SpyTheme.red, in: CutCornerShape(cut: 4))
                                        .offset(x: 20, y: 20)
                                }
                            }

                            Text(candidate.name.uppercased())
                                .font(SpyTheme.brandFont(size: 13))
                                .tracking(0.8)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.58)
                        }
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .background(selected ? SpyTheme.red.opacity(0.06) : Color.black.opacity(0.44), in: CutCornerShape(cut: 8))
                        .overlay {
                            CutCornerShape(cut: 8)
                                .stroke(selected ? SpyTheme.red.opacity(0.72) : SpyTheme.stroke, lineWidth: 1)
                        }
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .disabled(!canCastVote || myVote != nil || pendingVoteTargetEmail != nil)
                    .accessibilityIdentifier("onlineExperience.vote.\(accessibilityKey(candidate.email))")
                    .accessibilityValue(candidateAccessibilityValue(feedback))
                    }
                }
            }
            .frame(maxHeight: maxHeight)

            Text(voteSubmissionStatus)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(
                    pendingVoteTargetEmail != nil
                        ? SpyTheme.red
                        : (myVote == nil ? SpyTheme.dim : SpyTheme.green)
                )
        }
        .accessibilityIdentifier("onlineExperience.votingCandidates")
    }

    @ViewBuilder
    private var commandArea: some View {
        VStack(spacing: 8) {
            if let roundCommand {
                Button {
                    perform(roundCommand)
                } label: {
                    HStack(spacing: 9) {
                        if isRoundTransitioning {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: roundCommand.systemImage)
                        }
                        Text(roundCommand.title(copy: copy))
                    }
                }
                .buttonStyle(SpyCinematicButtonStyle(variant: .primary))
                .disabled(isRoundTransitioning)
                .accessibilityIdentifier(roundCommand.accessibilityIdentifier)
            } else if canSpyGuess && !suppressesFallbackPrimaryAction {
                Button(action: spyGuess) {
                    HStack(spacing: 9) {
                        Image(systemName: "target")
                        Text(copy.guessWord)
                    }
                }
                .buttonStyle(SpyCinematicButtonStyle(variant: .primary))
                .accessibilityIdentifier("onlineExperience.action.spyGuess")
            } else if showsVoteRequest && !room.isVotingActive && !suppressesFallbackPrimaryAction {
                Button(action: requestVote) {
                    HStack(spacing: 9) {
                        voteRequestStatusIcon
                        Text(
                            copy.startVoteProgress(
                                voteRequestFeedback.displayedCount,
                                room.voteThreshold
                            )
                        )
                    }
                }
                .buttonStyle(SpyCinematicButtonStyle(variant: .primary))
                .disabled(
                    !canRequestVote ||
                        voteRequestFeedback.isAwaitingServer ||
                        voteRequestFeedback.isRecorded
                )
                .accessibilityIdentifier("onlineExperience.action.vote")
                .accessibilityValue(voteRequestAccessibilityValue)
            }

            HStack(spacing: 8) {
                secondaryCommand(
                    title: isRoleRevealed ? copy.hideCard : copy.showCard,
                    systemImage: isRoleRevealed ? "eye.slash.fill" : "rectangle.portrait.fill",
                    accessibilityID: "onlineExperience.action.reveal",
                    action: toggleRole
                )

                if showsVoteRequest && !room.isVotingActive && !showsRoundResults && (roundCommand != nil || canSpyGuess) {
                    secondaryCommand(
                        title: copy.voteProgress(
                            voteRequestFeedback.displayedCount,
                            room.voteThreshold
                        ),
                        systemImage: voteRequestFeedback.isRecorded
                            ? "checkmark.circle.fill"
                            : "person.3.fill",
                        accessibilityID: "onlineExperience.action.vote",
                        isDisabled: !canRequestVote ||
                            voteRequestFeedback.isAwaitingServer ||
                            voteRequestFeedback.isRecorded,
                        isPending: voteRequestFeedback.isAwaitingServer,
                        accessibilityValue: voteRequestAccessibilityValue,
                        action: requestVote
                    )
                }

                if canSpyGuess && roundCommand != nil && !showsRoundResults {
                    secondaryCommand(
                        title: copy.guess,
                        systemImage: "target",
                        accessibilityID: "onlineExperience.action.spyGuess",
                        action: spyGuess
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onlineExperience.actionTray")
    }

    private var showsRoundResults: Bool {
        room.onlineRoundPhase == .results
    }

    private var suppressesFallbackPrimaryAction: Bool {
        showsRoundResults ||
            (room.gameModeValue == .questions && room.onlineRoundPhase == .countdown) ||
            (room.gameModeValue == .associations && room.associationRoundState.spinning)
    }

    private func secondaryCommand(
        title: String,
        systemImage: String,
        accessibilityID: String,
        isDisabled: Bool = false,
        isPending: Bool = false,
        accessibilityValue: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isPending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 10, weight: .black))
                    .tracking(0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }
        }
        .buttonStyle(SpyCinematicButtonStyle(variant: .secondary))
        .disabled(isDisabled)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityValue(accessibilityValue ?? "")
    }

    private var pausedOverlay: some View {
        ZStack {
            SpyCinematicBackdrop(intensity: 1.12)

            Color.black.opacity(0.72)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                AnimatedTitle(
                    text: copy.paused,
                    redPrefixCount: copy.paused.count,
                    fontSize: 44,
                    letterSpacing: 3
                )

                Text(copy.timerStopped)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(Color.white.opacity(0.58))

                if isHost {
                    Button(action: togglePause) {
                        HStack(spacing: 9) {
                            Image(systemName: "play.fill")
                            Text(copy.resumeGame)
                        }
                    }
                    .buttonStyle(SpyCinematicButtonStyle(variant: .primary))
                    .frame(width: 250)
                    .padding(.top, 12)
                    .accessibilityIdentifier("onlineExperience.pauseResume")
                }

                Button(action: requestLeave) {
                    HStack(spacing: 9) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text(isHost ? copy.closeGame : copy.leaveGame)
                    }
                }
                .buttonStyle(SpyCinematicButtonStyle(variant: .secondary))
                .frame(width: 250)
                .accessibilityIdentifier("onlineExperience.leave")

                if lobbyReturn.isAvailable {
                    lobbyReturnControl(
                        accessibilityID: "onlineExperience.returnToLobbyVote.paused"
                    )
                    .frame(width: 250)
                    .clipShape(CutCornerShape(cut: 7))
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func toggleRole() {
        onToggleRole()
    }

    private func togglePause() {
        HapticManager.shared.fire(room.isGamePaused ? .navigation : .buttonPress)
        onTogglePause()
    }

    private func requestVote() {
        HapticManager.shared.fire(.buttonPress)
        onRequestVote()
    }

    private func castVote(_ email: String) {
        guard canCastVote, myVote == nil else { return }
        HapticManager.shared.fire(.milestone)
        onCastVote(email)
    }

    private func spyGuess() {
        onSpyGuess()
    }

    private func toggleLobbyReturn() {
        guard lobbyReturn.isAvailable, !lobbyReturn.isPending else { return }
        HapticManager.shared.fire(.buttonPress)
        onToggleLobbyReturn()
    }

    private func requestLeave() {
        HapticManager.shared.fire(.buttonPress)
        isConfirmingLeave = true
    }

    private func leave() {
        HapticManager.shared.fire(.notification(.warning))
        onLeave()
    }

    private func player(email: String?) -> Player? {
        guard let email else { return nil }
        return room.playersList.first { $0.email == email }
    }

    private var revealedSpyTeammates: [Player] {
        guard isRoleRevealed,
              room.spiesKnowEachOther == true,
              room.isSpy(email: currentUserEmail) else { return [] }
        return room.spyPlayers.filter {
            !OnlineVoteIdentityPolicy.matches($0.email, currentUserEmail)
        }
    }

    private var roundResultPlayers: [Player] {
        let eliminated = Set(room.eliminatedEmails ?? [])
        return room.playersList
            .filter { !eliminated.contains($0.email) }
            .sorted { left, right in
                let leftScore = roundScore(for: left)
                let rightScore = roundScore(for: right)
                if leftScore == rightScore {
                    return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
                }
                return leftScore > rightScore
            }
    }

    private func roundScore(for player: Player) -> Int {
        guard let feedback = room.playerFeedback?.first(where: { $0.email == player.email }) else {
            return 0
        }
        return feedback.likes - feedback.dislikes
    }

    private func formattedRoundScore(for player: Player) -> String {
        let score = roundScore(for: player)
        return score > 0 ? "+\(score)" : "\(score)"
    }

    private func perform(_ command: OnlineRoundCommand) {
        guard !isRoundTransitioning else { return }
        HapticManager.shared.fire(.buttonPress)
        onRoundCommand(command)
    }

    private var countdownTaskID: String {
        [
            countdownEventID ?? "inactive",
            String(room.isGamePaused),
            String(isRoundTransitioning)
        ].joined(separator: "|")
    }

    private var countdownEventID: String? {
        guard room.gameModeValue == .questions,
              room.onlineRoundPhase == .countdown,
              room.containsPlayer(email: currentUserEmail) else { return nil }
        return [
            room.id,
            room.countdownStartedAt ?? "legacy",
            room.currentAskerEmail ?? "",
            String(room.roundNumber ?? 0),
            String(room.questionsInRound ?? 0),
            currentUserEmail ?? ""
        ].joined(separator: "|")
    }

    private func advanceCountdownIfNeeded() async {
        guard let eventID = countdownEventID,
              !room.isGamePaused,
              !isRoundTransitioning,
              handledCountdownEventID != eventID else { return }

        let delay = room.countdownRemaining(at: Date())
        if delay > 0 {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
        }
        guard !Task.isCancelled,
              room.shouldAdvanceQuestionAfterCountdown(
                for: currentUserEmail,
                at: Date()
              ) else { return }
        handledCountdownEventID = eventID
        onCountdownElapsed()
    }

    private var associationSpinTaskID: String {
        [
            associationSpinEventID ?? "inactive",
            String(room.isGamePaused),
            String(isRoundTransitioning)
        ].joined(separator: "|")
    }

    private var associationSpinEventID: String? {
        guard canStopAssociationSpin else { return nil }
        return [
            room.id,
            room.currentAskerEmail ?? "",
            room.currentAnswer ?? "",
            String(room.roundNumber ?? 0),
            currentUserEmail ?? ""
        ].joined(separator: "|")
    }

    private func stopAssociationSpinIfNeeded() async {
        guard let eventID = associationSpinEventID,
              !room.isGamePaused,
              !isRoundTransitioning,
              handledAssociationSpinEventID != eventID,
              let delay = room.associationSpinSettlementDelay(for: currentUserEmail) else { return }
        do {
            try await Task.sleep(for: .seconds(delay))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        handledAssociationSpinEventID = eventID
        onAssociationSpinElapsed()
    }

    private var votingCandidates: [Player] {
        OnlineVoteIdentityPolicy.candidates(
            from: room.activePlayers,
            currentUserEmail: currentUserEmail,
            eliminatedEmails: room.eliminatedEmails ?? []
        )
    }

    private var myVote: VoteRecord? {
        OnlineVoteIdentityPolicy.currentUserVote(
            in: room.detectiveVotesList,
            currentUserEmail: currentUserEmail
        )
    }

    private var voteRequestFeedback: OnlineVoteRequestFeedback {
        OnlineVoteRequestFeedback.resolve(
            serverRequestEmails: room.activeVoteRequests,
            currentUserEmail: currentUserEmail,
            submissionPending: isVoteRequestPending,
            threshold: room.voteThreshold
        )
    }

    @ViewBuilder
    private var voteRequestStatusIcon: some View {
        if voteRequestFeedback.isAwaitingServer {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        } else {
            Image(
                systemName: voteRequestFeedback.isRecorded
                    ? "checkmark.circle.fill"
                    : "person.3.fill"
            )
        }
    }

    private var voteRequestAccessibilityValue: String {
        if voteRequestFeedback.isAwaitingServer {
            return copy.voteRequestSending
        }
        if voteRequestFeedback.isRecorded {
            return copy.voteRequestRecorded
        }
        return ""
    }

    private var voteSubmissionStatus: String {
        if pendingVoteTargetEmail != nil {
            return copy.voteSending
        }
        return myVote == nil ? copy.voteIsFinal : copy.voteRecorded
    }

    private func candidateAccessibilityValue(
        _ feedback: OnlineVoteCandidateFeedback
    ) -> String {
        switch feedback {
        case .idle:
            ""
        case .awaitingServer:
            copy.voteSending
        case .recorded:
            copy.voteRecorded
        }
    }

    private func accessibilityKey(_ value: String) -> String {
        value.map { $0.isLetter || $0.isNumber ? $0 : "_" }.reduce("") { $0 + String($1) }
    }

    private var copy: SpyGameExperienceCopy { SpyGameExperienceCopy(language: language) }
}

// MARK: - Timing, accessibility, and copy

struct OnlineTimerSnapshot {
    let remaining: TimeInterval
    let progress: CGFloat
    let hasDeadline: Bool

    init(room: GameRoom, now: Date) {
        let duration = TimeInterval(max(room.gameDurationSeconds ?? 0, 0))
        guard duration > 0, let startedAt = OnlineExperienceClock.date(from: room.gameStartedAt) else {
            remaining = duration
            progress = duration > 0 ? 1 : 0
            hasDeadline = false
            return
        }

        let referenceDate = OnlineExperienceClock.date(from: room.gamePausedAt) ?? now
        let pausedTotal = TimeInterval(max(room.gamePausedTotalSeconds ?? 0, 0))
        let elapsed = max(referenceDate.timeIntervalSince(startedAt) - pausedTotal, 0)
        remaining = max(duration - elapsed, 0)
        progress = CGFloat(min(max(remaining / duration, 0), 1))
        hasDeadline = true
    }

    var formatted: String {
        let seconds = displayedSeconds
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var displayedSeconds: Int {
        max(Int(ceil(remaining)), 0)
    }

    var isExpired: Bool {
        hasDeadline && remaining <= 0
    }

    var isCritical: Bool {
        remaining > 0 && remaining <= 30
    }
}

private enum OnlineExperienceClock {
    static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: normalized) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: normalized)
    }
}

enum SpyExperienceMotion {
    static func segment(_ value: Double, from start: Double, to end: Double) -> Double {
        guard end > start else { return value >= end ? 1 : 0 }
        return min(max((value - start) / (end - start), 0), 1)
    }

    static func easeOut(_ value: Double) -> Double {
        1 - pow(1 - value, 3)
    }

    static func easeInOut(_ value: Double) -> Double {
        value < 0.5
            ? 4 * value * value * value
            : 1 - pow(-2 * value + 2, 3) / 2
    }

    static func spring(_ value: Double) -> Double {
        guard value > 0 else { return 0 }
        guard value < 1 else { return 1 }
        let response = 1 - exp(-7.2 * value) * cos(10.5 * value)
        return min(max(response, 0), 1.06)
    }

    static func pulse(_ value: Double, center: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        let distance = abs(value - center) / width
        guard distance < 1 else { return 0 }
        return 0.5 + 0.5 * cos(distance * .pi)
    }

    static func arcPoint(
        from start: CGPoint,
        to end: CGPoint,
        progress: Double,
        lift: CGFloat
    ) -> CGPoint {
        let t = CGFloat(min(max(progress, 0), 1))
        let control = CGPoint(
            x: (start.x + end.x) / 2,
            y: min(start.y, end.y) - lift
        )
        let inverse = 1 - t
        return CGPoint(
            x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x,
            y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y
        )
    }
}

private extension MissionRoleCardContent {
    func onlineAccessibilityLabel(
        category: String?,
        language: AppLanguage,
        revealed: Bool
    ) -> String {
        let copy = SpyGameExperienceCopy(language: language)
        guard revealed else { return copy.roleCard }

        switch self {
        case .spy:
            let normalizedCategory = category?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalizedCategory, !normalizedCategory.isEmpty {
                return "\(copy.spy). \(copy.theme) \(normalizedCategory)"
            }
            return copy.spy
        case let .detective(word):
            return "\(copy.detective). \(copy.secretWord): \(word)"
        case .spectator:
            return copy.spectator
        }
    }
}

struct SpyGameExperienceCopy {
    let language: AppLanguage

    private func text(_ en: String, _ es: String, _ ru: String, _ uk: String) -> String {
        switch language {
        case .en: en
        case .es: es
        case .ru: ru
        case .uk: uk
        }
    }

    var spy: String { text("SPY", "ESPÍA", "ШПИОН", "ШПИГУН") }
    var detective: String { text("DETECTIVE", "DETECTIVE", "ДЕТЕКТИВ", "ДЕТЕКТИВ") }
    var secretWord: String { text("Secret word", "Palabra secreta", "Секретное слово", "Секретне слово") }
    var amongYou: String { text("AMONG YOU", "ENTRE USTEDES", "СРЕДИ ВАС", "СЕРЕД ВАС") }
    var theme: String { text("THEME", "TEMA", "ТЕМА", "ТЕМА") }
    var unknownTheme: String { text("UNKNOWN", "DESCONOCIDO", "НЕИЗВЕСТНО", "НЕВІДОМО") }
    var spectator: String { text("SPECTATOR", "ESPECTADOR", "НАБЛЮДАТЕЛЬ", "СПОСТЕРІГАЧ") }
    var roleCard: String { text("Role card", "Tarjeta de rol", "Карточка роли", "Картка ролі") }
    var revealed: String { text("Revealed", "Revelada", "Открыта", "Відкрита") }
    var concealed: String { text("Concealed", "Oculta", "Закрыта", "Прихована") }
    var tapToReveal: String { text("TAP TO REVEAL", "TOCA PARA REVELAR", "НАЖМИ, ЧТОБЫ ОТКРЫТЬ", "НАТИСНИ, ЩОБ ВІДКРИТИ") }
    var tapToConceal: String { text("TAP TO CONCEAL", "TOCA PARA OCULTAR", "НАЖМИ, ЧТОБЫ СКРЫТЬ", "НАТИСНИ, ЩОБ ПРИХОВАТИ") }

    var gameStarting: String { text("// THE GAME BEGINS", "// EL JUEGO EMPIEZA", "// ИГРА НАЧИНАЕТСЯ", "// ГРА ПОЧИНАЄТЬСЯ") }
    func spyTeam(spyCount: Int) -> String {
        spyCount > 1 ? text("SPIES", "ESPÍAS", "ШПИОНЫ", "ШПИГУНИ") : spy
    }

    func introAccessibility(spyCount: Int) -> String {
        spyCount > 1
            ? text("The game begins. Cards are dealt. The spies are among you.", "El juego comienza. Las cartas están repartidas. Los espías están entre ustedes.", "Игра начинается. Карты розданы. Шпионы среди вас.", "Гра починається. Карти роздано. Шпигуни серед вас.")
            : text("The game begins. Cards are dealt. The spy is among you.", "El juego comienza. Las cartas están repartidas. El espía está entre ustedes.", "Игра начинается. Карты розданы. Шпион среди вас.", "Гра починається. Карти роздано. Шпигун серед вас.")
    }

    var personalCard: String { text("// YOUR CARD", "// TU TARJETA", "// ТВОЯ КАРТА", "// ТВОЯ КАРТКА") }
    var cardViewed: String { text("I VIEWED THE CARD", "HE VISTO LA TARJETA", "КАРТОЧКУ ПРОСМОТРЕЛ", "КАРТКУ ПЕРЕГЛЯНУТО") }
    var leaveGame: String { text("LEAVE GAME", "SALIR DEL JUEGO", "ВЫЙТИ ИЗ ИГРЫ", "ВИЙТИ З ГРИ") }
    var closeGame: String { text("CLOSE GAME", "CERRAR JUEGO", "ЗАКРЫТЬ ИГРУ", "ЗАКРИТИ ГРУ") }
    var cancel: String { text("CANCEL", "CANCELAR", "ОТМЕНА", "СКАСУВАТИ") }
    var returnToLobby: String { text("RETURN TO LOBBY", "VOLVER AL LOBBY", "ВЕРНУТЬСЯ В ЛОББИ", "ПОВЕРНУТИСЯ ДО ЛОБІ") }
    var cancelReturnToLobby: String { text("CANCEL RETURN VOTE", "CANCELAR VOTO DE REGRESO", "ОТМЕНИТЬ ГОЛОС ЗА ВОЗВРАТ", "СКАСУВАТИ ГОЛОС ЗА ПОВЕРНЕННЯ") }
    var retryReturnToLobby: String { text("RETRY RETURN VOTE", "REINTENTAR VOTO DE REGRESO", "ПОВТОРИТЬ ГОЛОС ЗА ВОЗВРАТ", "ПОВТОРИТИ ГОЛОС ЗА ПОВЕРНЕННЯ") }
    func returnToLobbyAccessibilityValue(
        votes: Int,
        players: Int,
        selected: Bool,
        pending: Bool,
        failed: Bool
    ) -> String {
        let progress = text(
            "\(votes) of \(players) players",
            "\(votes) de \(players) jugadores",
            "\(votes) из \(players) игроков",
            "\(votes) із \(players) гравців"
        )
        let state: String
        if pending {
            state = text("pending", "pendiente", "отправляется", "надсилається")
        } else if failed {
            state = text("failed, retry available", "falló, reintento disponible", "ошибка, доступен повтор", "помилка, доступний повтор")
        } else if selected {
            state = text("selected", "seleccionado", "выбрано", "вибрано")
        } else {
            state = text("not selected", "no seleccionado", "не выбрано", "не вибрано")
        }
        return "\(progress), \(state)"
    }
    func waitingCount(_ ready: Int, _ total: Int) -> String {
        text("WAITING FOR OTHERS", "ESPERANDO A LOS DEMÁS", "ЖДЁМ ОСТАЛЬНЫХ", "ЧЕКАЄМО НА ІНШИХ") + "  \(ready)/\(total)"
    }

    func playingRound(_ round: Int) -> String {
        text("// PLAYING", "// JUGANDO", "// ИГРА", "// ГРА") + "  •  " + text("ROUND", "RONDA", "РАУНД", "РАУНД") + " " + String(format: "%02d", round)
    }
    var pause: String { text("Pause timer", "Pausar temporizador", "Поставить таймер на паузу", "Призупинити таймер") }
    var resume: String { text("Resume timer", "Reanudar temporizador", "Продолжить таймер", "Продовжити таймер") }
    var exit: String { text("Exit", "Salir", "Выйти", "Вийти") }
    var asks: String { text("ASKS", "PREGUNTA", "СПРАШИВАЕТ", "ЗАПИТУЄ") }
    var answers: String { text("ANSWERS", "RESPONDE", "ОТВЕЧАЕТ", "ВІДПОВІДАЄ") }
    var pending: String { text("PENDING", "PENDIENTE", "ОЖИДАНИЕ", "ОЧІКУВАННЯ") }
    var chooseSuspect: String { text("CHOOSE A SUSPECT", "ELIGE UN SOSPECHOSO", "ВЫБЕРИ ПОДОЗРЕВАЕМОГО", "ОБЕРИ ПІДОЗРЮВАНОГО") }
    var voteIsFinal: String { text("THE VOTE IS FINAL", "EL VOTO ES DEFINITIVO", "ГОЛОС НЕЛЬЗЯ ИЗМЕНИТЬ", "ГОЛОС НЕ МОЖНА ЗМІНИТИ") }
    var voteRecorded: String { text("VOTE RECORDED", "VOTO REGISTRADO", "ГОЛОС ПРИНЯТ", "ГОЛОС ПРИЙНЯТО") }
    var voteSending: String { text("SENDING VOTE", "ENVIANDO VOTO", "ОТПРАВЛЯЕМ ГОЛОС", "НАДСИЛАЄМО ГОЛОС") }
    var voteRequestSending: String { text("SENDING REQUEST", "ENVIANDO SOLICITUD", "ОТПРАВЛЯЕМ ЗАПРОС", "НАДСИЛАЄМО ЗАПИТ") }
    var voteRequestRecorded: String { text("REQUEST RECORDED", "SOLICITUD REGISTRADA", "ЗАПРОС ПРИНЯТ", "ЗАПИТ ПРИЙНЯТО") }
    var nextTurn: String { text("NEXT TURN", "SIGUIENTE TURNO", "СЛЕДУЮЩИЙ ХОД", "НАСТУПНИЙ ХІД") }
    var answerReceived: String { text("ANSWER RECEIVED", "RESPUESTA RECIBIDA", "ОТВЕТ ПОЛУЧЕН", "ВІДПОВІДЬ ОТРИМАНО") }
    var continueRound: String { text("CONTINUE ROUND", "CONTINUAR RONDA", "ПРОДОЛЖИТЬ РАУНД", "ПРОДОВЖИТИ РАУНД") }
    var startAssociations: String { text("START ASSOCIATIONS", "INICIAR ASOCIACIONES", "НАЧАТЬ АССОЦИАЦИИ", "ПОЧАТИ АСОЦІАЦІЇ") }
    var associationGiven: String { text("ASSOCIATION GIVEN", "ASOCIACIÓN DADA", "АССОЦИАЦИЯ НАЗВАНА", "АСОЦІАЦІЮ НАЗВАНО") }
    var nextQuestionIn: String { text("NEXT QUESTION IN", "SIGUIENTE PREGUNTA EN", "СЛЕДУЮЩИЙ ВОПРОС ЧЕРЕЗ", "НАСТУПНЕ ЗАПИТАННЯ ЧЕРЕЗ") }
    var waitForNextTurn: String { text("SYNCHRONIZING ALL OPERATIVES", "SINCRONIZANDO OPERATIVOS", "СИНХРОНИЗАЦИЯ ИГРОКОВ", "СИНХРОНІЗАЦІЯ ГРАВЦІВ") }
    var selectingSpeaker: String { text("SELECTING NEXT SPEAKER", "ELIGIENDO AL SIGUIENTE", "ВЫБИРАЕМ СЛЕДУЮЩЕГО", "ОБИРАЄМО НАСТУПНОГО") }
    var currentSpeaker: String { text("CURRENT SPEAKER", "HABLA AHORA", "СЕЙЧАС ГОВОРИТ", "ЗАРАЗ ГОВОРИТЬ") }
    var signalScanning: String { text("SIGNAL SCANNING", "ESCANEANDO SEÑAL", "СКАНИРУЕМ СИГНАЛ", "СКАНУЄМО СИГНАЛ") }
    var roundResults: String { text("ROUND RESULTS", "RESULTADOS DE RONDA", "ИТОГИ РАУНДА", "ПІДСУМКИ РАУНДУ") }
    func associationProgress(_ spoken: Int, _ total: Int) -> String {
        text("ASSOCIATIONS", "ASOCIACIONES", "АССОЦИАЦИИ", "АСОЦІАЦІЇ") + "  \(spoken)/\(max(total, 0))"
    }
    var guessWord: String { text("GUESS THE WORD", "ADIVINAR PALABRA", "УГАДАТЬ СЛОВО", "ВГАДАТИ СЛОВО") }
    func spyWinsAtDeadline(spyCount: Int) -> String {
        spyCount > 1
            ? text("TIME EXPIRED — SPIES WIN", "TIEMPO AGOTADO — GANAN LOS ESPÍAS", "ВРЕМЯ ВЫШЛО — ШПИОНЫ ПОБЕДИЛИ", "ЧАС ВИЙШОВ — ШПИГУНИ ПЕРЕМОГЛИ")
            : text("TIME EXPIRED — SPY WINS", "TIEMPO AGOTADO — GANA EL ESPÍA", "ВРЕМЯ ВЫШЛО — ШПИОН ПОБЕДИЛ", "ЧАС ВИЙШОВ — ШПИГУН ПЕРЕМІГ")
    }
    var startVote: String { text("START VOTE", "INICIAR VOTACIÓN", "НАЧАТЬ ГОЛОСОВАНИЕ", "ПОЧАТИ ГОЛОСУВАННЯ") }
    func startVoteProgress(_ count: Int, _ threshold: Int) -> String {
        "\(startVote) \(min(max(count, 0), max(threshold, 0)))/\(max(threshold, 0))"
    }
    var hideCard: String { text("HIDE CARD", "OCULTAR TARJETA", "СКРЫТЬ КАРТУ", "ПРИХОВАТИ КАРТКУ") }
    var showCard: String { text("SHOW CARD", "MOSTRAR TARJETA", "ПОКАЗАТЬ КАРТУ", "ПОКАЗАТИ КАРТКУ") }
    var vote: String { text("VOTE", "VOTAR", "ГОЛОСОВАНИЕ", "ГОЛОСУВАННЯ") }
    func voteProgress(_ count: Int, _ threshold: Int) -> String {
        "\(vote) \(min(max(count, 0), max(threshold, 0)))/\(max(threshold, 0))"
    }
    var guess: String { text("GUESS", "ADIVINAR", "УГАДАТЬ", "ВГАДАТИ") }

    func exclusionRequirement(required: Int, total: Int) -> String {
        text(
            "EXCLUSION REQUIRES \(required) OF \(total) VOTES FOR ONE SUSPECT",
            "LA EXCLUSIÓN REQUIERE \(required) DE \(total) VOTOS POR UN SOSPECHOSO",
            "ДЛЯ ИСКЛЮЧЕНИЯ НУЖНО \(required) ИЗ \(total) ГОЛОСОВ ЗА ОДНОГО ИГРОКА",
            "ДЛЯ ВИКЛЮЧЕННЯ ПОТРІБНО \(required) ІЗ \(total) ГОЛОСІВ ЗА ОДНОГО ГРАВЦЯ"
        )
    }

    var impossibleVoteCancels: String {
        text(
            "THE SERVER CANCELS THE VOTE WHEN THAT RESULT BECOMES IMPOSSIBLE",
            "EL SERVIDOR CANCELA LA VOTACIÓN CUANDO ESE RESULTADO YA ES IMPOSIBLE",
            "СЕРВЕР ОТМЕНИТ ГОЛОСОВАНИЕ, КОГДА ТАКОЙ РЕЗУЛЬТАТ СТАНЕТ НЕВОЗМОЖЕН",
            "СЕРВЕР СКАСУЄ ГОЛОСУВАННЯ, КОЛИ ТАКИЙ РЕЗУЛЬТАТ СТАНЕ НЕМОЖЛИВИМ"
        )
    }

    var paused: String { text("PAUSED", "PAUSA", "ПАУЗА", "ПАУЗА") }
    var timerStopped: String { text("THE TIMER IS STOPPED", "EL TEMPORIZADOR ESTÁ DETENIDO", "ТАЙМЕР ОСТАНОВЛЕН", "ТАЙМЕР ЗУПИНЕНО") }
    var resumeGame: String { text("RESUME GAME", "CONTINUAR JUEGO", "ПРОДОЛЖИТЬ ИГРУ", "ПРОДОВЖИТИ ГРУ") }
}

private extension OnlineRoundCommand {
    func title(copy: SpyGameExperienceCopy) -> String {
        switch self {
        case .markAnswerHeard:
            copy.answerReceived
        case .continueRound:
            copy.continueRound
        case .startAssociation:
            copy.startAssociations
        case .advanceAssociation:
            copy.associationGiven
        }
    }

    var systemImage: String {
        switch self {
        case .markAnswerHeard:
            "ear.fill"
        case .continueRound:
            "arrow.right"
        case .startAssociation:
            "shuffle"
        case .advanceAssociation:
            "checkmark"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .markAnswerHeard:
            "onlineExperience.action.answerReceived"
        case .continueRound:
            "onlineExperience.action.continueRound"
        case .startAssociation:
            "onlineExperience.action.startAssociation"
        case .advanceAssociation:
            "onlineExperience.action.advanceAssociation"
        }
    }
}
