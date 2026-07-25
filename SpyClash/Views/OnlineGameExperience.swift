import Foundation
import SwiftUI

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

struct MissionRoleCard: View {
    let role: MissionRoleCardContent
    let category: String?
    let theme: SpyCardThemeID
    let accent: Color
    let language: AppLanguage
    let isRevealed: Bool
    var size: MissionRoleCardSize = .hero

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    private var copy: OnlineExperienceCopy { OnlineExperienceCopy(language: language) }
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

private struct OnlineCinematicBackdrop: View {
    var intensity: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

private struct OnlineCinematicButtonStyle: ButtonStyle {
    enum Variant {
        case primary
        case secondary
        case quiet
    }

    let variant: Variant

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
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .offset(y: configuration.isPressed ? 1.5 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || debugFixedProgress != nil)) { timeline in
            GeometryReader { proxy in
                introStage(
                    size: proxy.size,
                    progress: resolvedProgress(at: timeline.date)
                )
            }
        }
        .background(SpyTheme.black)
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(copy.introAccessibility)
        .accessibilityIdentifier("onlineExperience.intro")
        .task(id: room.introStartedAt) {
            await playIntroHaptics()
        }
    }

    private func introStage(size: CGSize, progress: Double) -> some View {
        let deckPoint = CGPoint(x: size.width / 2, y: size.height * 0.65)
        let warningProgress = OnlineExperienceMotion.segment(progress, from: 0.72, to: 0.84)
        let warningExit = OnlineExperienceMotion.segment(progress, from: 0.90, to: 0.96)
        let warningOpacity = warningProgress * (1 - warningExit)
        let dimmedOpacity = 1 - warningProgress * 0.88
        let outro = OnlineExperienceMotion.segment(progress, from: 0.94, to: 1)
        let deckReveal = OnlineExperienceMotion.spring(
            OnlineExperienceMotion.segment(progress, from: 0.16, to: 0.34)
        )

        return ZStack {
            OnlineCinematicBackdrop(intensity: CGFloat(0.72 + warningProgress * 0.34))
                .opacity(dimmedOpacity + warningProgress * 0.28)

            VStack(spacing: 7) {
                SpyWordmark(fontSize: 22)
                Text(copy.gameStarting)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(SpyTheme.dim)
            }
            .position(x: size.width / 2, y: max(68, size.height * 0.10))
            .opacity(OnlineExperienceMotion.segment(progress, from: 0, to: 0.14))
            .blur(radius: warningProgress * 5)
            .offset(y: -warningProgress * 10)

            ForEach(Array(room.playersList.enumerated()), id: \.element.id) { index, player in
                let target = playerPosition(index: index, count: room.playersList.count, size: size)
                let appearance = reduceMotion
                    ? 1
                    : OnlineExperienceMotion.easeOut(
                        OnlineExperienceMotion.segment(
                            progress,
                            from: 0.11 + Double(index) * 0.018,
                            to: 0.29 + Double(index) * 0.018
                        )
                    )
                let window = dealWindow(index: index, count: room.playersList.count)
                let rawDeal = reduceMotion ? 1 : OnlineExperienceMotion.segment(progress, from: window.start, to: window.end)
                let deal = reduceMotion ? 1 : OnlineExperienceMotion.spring(rawDeal)
                let cardPoint = OnlineExperienceMotion.arcPoint(
                    from: deckPoint,
                    to: CGPoint(x: target.x, y: target.y + 72),
                    progress: min(max(deal, 0), 1),
                    lift: 56 + abs(target.x - deckPoint.x) * 0.18
                )
                let landingPulse = OnlineExperienceMotion.pulse(rawDeal, center: 0.88, width: 0.18)

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
                .opacity(deckReveal * (1 - OnlineExperienceMotion.segment(progress, from: 0.68, to: 0.78)) * dimmedOpacity)
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
                Text(copy.spy)
                    .foregroundStyle(SpyTheme.red)
                Text(copy.amongYou)
                    .foregroundStyle(.white)
            }
            .font(SpyTheme.brandFont(size: min(48, size.width * 0.125)))
            .tracking(2.5)
            .multilineTextAlignment(.center)
            .shadow(color: SpyTheme.red.opacity(0.28), radius: 30)
            .scaleEffect(0.72 + 0.28 * OnlineExperienceMotion.spring(warningProgress))
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

    private var copy: OnlineExperienceCopy { OnlineExperienceCopy(language: language) }
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                OnlineCinematicBackdrop(intensity: isRevealed ? 0.92 : 0.70)

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

                            Button(action: revealIfNeeded) {
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
                            .buttonStyle(SpyWebPressStyle(pressedScale: isRevealed ? 1 : 0.98))
                            .scaleEffect(hasEntered ? 1 : 0.78)
                            .offset(y: hasEntered ? 0 : 86)
                            .rotation3DEffect(
                                .degrees(hasEntered ? 0 : 18),
                                axis: (x: 1, y: 0.08, z: 0),
                                perspective: 0.66
                            )
                            .disabled(isRevealed || isCurrentPlayerConfirmed)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(
                                displayedRole.onlineAccessibilityLabel(
                                    category: room.category,
                                    language: language,
                                    revealed: isRevealed
                                )
                            )
                            .accessibilityValue(isRevealed ? copy.revealed : copy.concealed)
                            .accessibilityHint(isRevealed || isCurrentPlayerConfirmed ? "" : copy.tapToReveal)
                            .accessibilityIdentifier("onlineExperience.roleCard")

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
            .buttonStyle(OnlineCinematicButtonStyle(variant: .primary))
            .disabled(isConfirming)
            .accessibilityIdentifier("onlineExperience.confirmRole")
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else {
            Color.clear
                .frame(height: 56)
                .accessibilityHidden(true)
        }
    }

    private func revealIfNeeded() {
        guard !isRevealed, !isCurrentPlayerConfirmed else { return }
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

    private var copy: OnlineExperienceCopy { OnlineExperienceCopy(language: language) }
}

// MARK: - Active online game

struct OnlineActiveGameScene: View {
    let room: GameRoom
    let language: AppLanguage
    let role: MissionRoleCardContent
    let cardTheme: SpyCardThemeID
    let cardAccent: Color
    let currentUserEmail: String?
    let isHost: Bool
    let isRoleRevealed: Bool
    let canAdvance: Bool
    let canRequestVote: Bool
    let canSpyGuess: Bool
    let canCastVote: Bool
    let onToggleRole: () -> Void
    let onTogglePause: () -> Void
    let onAdvance: () -> Void
    let onRequestVote: () -> Void
    let onCastVote: (String) -> Void
    let onSpyGuess: () -> Void
    let onLeave: () -> Void

    @State private var isConfirmingLeave = false

    init(
        room: GameRoom,
        language: AppLanguage,
        role: MissionRoleCardContent,
        cardTheme: SpyCardThemeID = .field,
        cardAccent: Color = SpyTheme.red,
        currentUserEmail: String?,
        isHost: Bool,
        isRoleRevealed: Bool,
        canAdvance: Bool,
        canRequestVote: Bool,
        canSpyGuess: Bool,
        canCastVote: Bool = true,
        onToggleRole: @escaping () -> Void,
        onTogglePause: @escaping () -> Void,
        onAdvance: @escaping () -> Void,
        onRequestVote: @escaping () -> Void,
        onCastVote: @escaping (String) -> Void,
        onSpyGuess: @escaping () -> Void,
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
        self.canAdvance = canAdvance
        self.canRequestVote = canRequestVote
        self.canSpyGuess = canSpyGuess
        self.canCastVote = canCastVote
        self.onToggleRole = onToggleRole
        self.onTogglePause = onTogglePause
        self.onAdvance = onAdvance
        self.onRequestVote = onRequestVote
        self.onCastVote = onCastVote
        self.onSpyGuess = onSpyGuess
        self.onLeave = onLeave
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            GeometryReader { proxy in
                ZStack {
                    OnlineCinematicBackdrop(intensity: room.isVotingActive ? 1.02 : 0.84)

                    VStack(spacing: 0) {
                        gameBrandHeader

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
        .confirmationDialog(
            isHost ? copy.closeGame : copy.leaveGame,
            isPresented: $isConfirmingLeave,
            titleVisibility: .visible
        ) {
            Button(isHost ? copy.closeGame : copy.leaveGame, role: .destructive, action: leave)
            Button(copy.cancel, role: .cancel) {}
        }
    }

    private func timerHeader(at date: Date) -> some View {
        let timer = OnlineTimerSnapshot(room: room, now: date)

        return VStack(spacing: 6) {
            Text(copy.playingRound(max(room.roundNumber ?? 1, 1)))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(SpyTheme.dim)

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

                        Rectangle()
                            .fill(isTurn ? SpyTheme.red : (isCurrent ? Color.white.opacity(0.58) : SpyTheme.stroke))
                            .frame(width: isTurn ? 24 : 10, height: 1)
                    }
                    .opacity(isEliminated ? 0.48 : 1)
                    .scaleEffect(isTurn ? 1.04 : 1)
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

                if !room.isVotingActive {
                    activePairStrip
                }
            }
            .opacity(room.isVotingActive ? 0 : 1)

            if room.isVotingActive {
                votingStage(maxHeight: maxVotingHeight)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
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

            ScrollView(.vertical, showsIndicators: votingCandidates.count > 6) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(votingCandidates) { candidate in
                    let selected = myVote?.votedForEmail == candidate.email
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

                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .black))
                                        .foregroundStyle(.black)
                                        .frame(width: 17, height: 17)
                                        .background(SpyTheme.green, in: CutCornerShape(cut: 4))
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
                    .disabled(!canCastVote || myVote != nil)
                    .accessibilityIdentifier("onlineExperience.vote.\(accessibilityKey(candidate.email))")
                    }
                }
            }
            .frame(maxHeight: maxHeight)

            Text(myVote == nil ? copy.voteIsFinal : copy.voteRecorded)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(myVote == nil ? SpyTheme.dim : SpyTheme.green)
        }
        .accessibilityIdentifier("onlineExperience.votingCandidates")
    }

    @ViewBuilder
    private var commandArea: some View {
        VStack(spacing: 8) {
            if canAdvance {
                Button(action: advance) {
                    HStack(spacing: 9) {
                        Image(systemName: "arrow.right")
                        Text(copy.nextTurn)
                    }
                }
                .buttonStyle(OnlineCinematicButtonStyle(variant: .primary))
                .accessibilityIdentifier("onlineExperience.action.next")
            } else if canSpyGuess {
                Button(action: spyGuess) {
                    HStack(spacing: 9) {
                        Image(systemName: "target")
                        Text(copy.guessWord)
                    }
                }
                .buttonStyle(OnlineCinematicButtonStyle(variant: .primary))
                .accessibilityIdentifier("onlineExperience.action.spyGuess")
            } else if canRequestVote && !room.isVotingActive {
                Button(action: requestVote) {
                    HStack(spacing: 9) {
                        Image(systemName: "person.3.fill")
                        Text(copy.startVote)
                    }
                }
                .buttonStyle(OnlineCinematicButtonStyle(variant: .primary))
                .accessibilityIdentifier("onlineExperience.action.vote")
            }

            HStack(spacing: 8) {
                secondaryCommand(
                    title: isRoleRevealed ? copy.hideCard : copy.showCard,
                    systemImage: isRoleRevealed ? "eye.slash.fill" : "rectangle.portrait.fill",
                    accessibilityID: "onlineExperience.action.reveal",
                    action: toggleRole
                )

                if canRequestVote && !room.isVotingActive && (canAdvance || canSpyGuess) {
                    secondaryCommand(
                        title: copy.vote,
                        systemImage: "person.3.fill",
                        accessibilityID: "onlineExperience.action.vote",
                        action: requestVote
                    )
                }

                if canSpyGuess && !(!canAdvance && canSpyGuess) {
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

    private func secondaryCommand(
        title: String,
        systemImage: String,
        accessibilityID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .bold))
                Text(title)
                    .font(.system(size: 10, weight: .black))
                    .tracking(0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }
        }
        .buttonStyle(OnlineCinematicButtonStyle(variant: .secondary))
        .accessibilityIdentifier(accessibilityID)
    }

    private var pausedOverlay: some View {
        ZStack {
            OnlineCinematicBackdrop(intensity: 1.12)

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
                    .buttonStyle(OnlineCinematicButtonStyle(variant: .primary))
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
                .buttonStyle(OnlineCinematicButtonStyle(variant: .secondary))
                .frame(width: 250)
                .accessibilityIdentifier("onlineExperience.leave")
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

    private func advance() {
        HapticManager.shared.fire(.navigation)
        onAdvance()
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

    private var votingCandidates: [Player] {
        let eliminated = Set(room.eliminatedEmails ?? [])
        return room.activePlayers.filter {
            !eliminated.contains($0.email) && $0.email != currentUserEmail
        }
    }

    private var myVote: VoteRecord? {
        guard let currentUserEmail else { return nil }
        return room.detectiveVotesList.first { $0.voterEmail == currentUserEmail }
    }

    private func accessibilityKey(_ value: String) -> String {
        value.map { $0.isLetter || $0.isNumber ? $0 : "_" }.reduce("") { $0 + String($1) }
    }

    private var copy: OnlineExperienceCopy { OnlineExperienceCopy(language: language) }
}

// MARK: - Timing, accessibility, and copy

private struct OnlineTimerSnapshot {
    let remaining: TimeInterval
    let progress: CGFloat

    init(room: GameRoom, now: Date) {
        let duration = TimeInterval(max(room.gameDurationSeconds ?? 0, 0))
        guard duration > 0, let startedAt = OnlineExperienceClock.date(from: room.gameStartedAt) else {
            remaining = duration
            progress = duration > 0 ? 1 : 0
            return
        }

        let referenceDate = OnlineExperienceClock.date(from: room.gamePausedAt) ?? now
        let pausedTotal = TimeInterval(max(room.gamePausedTotalSeconds ?? 0, 0))
        let elapsed = max(referenceDate.timeIntervalSince(startedAt) - pausedTotal, 0)
        remaining = max(duration - elapsed, 0)
        progress = CGFloat(min(max(remaining / duration, 0), 1))
    }

    var formatted: String {
        let seconds = Int(ceil(remaining))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
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

private enum OnlineExperienceMotion {
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
        let copy = OnlineExperienceCopy(language: language)
        guard revealed else { return copy.roleCard }

        switch self {
        case .spy:
            let normalizedCategory = category?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalizedCategory, !normalizedCategory.isEmpty {
                return "\(copy.spy). \(copy.theme) \(normalizedCategory)"
            }
            return copy.spy
        case let .detective(word):
            return word
        case .spectator:
            return copy.spectator
        }
    }
}

private struct OnlineExperienceCopy {
    let language: AppLanguage

    private func text(_ en: String, _ es: String, _ ru: String) -> String {
        switch language {
        case .en: en
        case .es: es
        case .ru: ru
        }
    }

    var spy: String { text("SPY", "ESPÍA", "ШПИОН") }
    var amongYou: String { text("AMONG YOU", "ENTRE USTEDES", "СРЕДИ ВАС") }
    var theme: String { text("THEME", "TEMA", "ТЕМА") }
    var unknownTheme: String { text("UNKNOWN", "DESCONOCIDO", "НЕИЗВЕСТНО") }
    var spectator: String { text("SPECTATOR", "ESPECTADOR", "НАБЛЮДАТЕЛЬ") }
    var roleCard: String { text("Role card", "Tarjeta de rol", "Карточка роли") }
    var revealed: String { text("Revealed", "Revelada", "Открыта") }
    var concealed: String { text("Concealed", "Oculta", "Закрыта") }
    var tapToReveal: String { text("TAP TO REVEAL", "TOCA PARA REVELAR", "НАЖМИ, ЧТОБЫ ОТКРЫТЬ") }

    var gameStarting: String { text("// THE GAME BEGINS", "// EL JUEGO EMPIEZA", "// ИГРА НАЧИНАЕТСЯ") }
    var introAccessibility: String { text("The game begins. Cards are dealt. The spy is among you.", "El juego comienza. Las cartas están repartidas. El espía está entre ustedes.", "Игра начинается. Карты розданы. Шпион среди вас.") }

    var personalCard: String { text("// YOUR CARD", "// TU TARJETA", "// ТВОЯ КАРТА") }
    var cardViewed: String { text("I VIEWED THE CARD", "HE VISTO LA TARJETA", "КАРТОЧКУ ПРОСМОТРЕЛ") }
    var leaveGame: String { text("LEAVE GAME", "SALIR DEL JUEGO", "ВЫЙТИ ИЗ ИГРЫ") }
    var closeGame: String { text("CLOSE GAME", "CERRAR JUEGO", "ЗАКРЫТЬ ИГРУ") }
    var cancel: String { text("CANCEL", "CANCELAR", "ОТМЕНА") }
    func waitingCount(_ ready: Int, _ total: Int) -> String {
        text("WAITING FOR OTHERS", "ESPERANDO A LOS DEMÁS", "ЖДЁМ ОСТАЛЬНЫХ") + "  \(ready)/\(total)"
    }

    func playingRound(_ round: Int) -> String {
        text("// PLAYING", "// JUGANDO", "// ИГРА") + "  •  " + text("ROUND", "RONDA", "РАУНД") + " " + String(format: "%02d", round)
    }
    var pause: String { text("Pause timer", "Pausar temporizador", "Поставить таймер на паузу") }
    var resume: String { text("Resume timer", "Reanudar temporizador", "Продолжить таймер") }
    var exit: String { text("Exit", "Salir", "Выйти") }
    var asks: String { text("ASKS", "PREGUNTA", "СПРАШИВАЕТ") }
    var answers: String { text("ANSWERS", "RESPONDE", "ОТВЕЧАЕТ") }
    var pending: String { text("PENDING", "PENDIENTE", "ОЖИДАНИЕ") }
    var chooseSuspect: String { text("CHOOSE A SUSPECT", "ELIGE UN SOSPECHOSO", "ВЫБЕРИ ПОДОЗРЕВАЕМОГО") }
    var voteIsFinal: String { text("THE VOTE IS FINAL", "EL VOTO ES DEFINITIVO", "ГОЛОС НЕЛЬЗЯ ИЗМЕНИТЬ") }
    var voteRecorded: String { text("VOTE RECORDED", "VOTO REGISTRADO", "ГОЛОС ПРИНЯТ") }
    var nextTurn: String { text("NEXT TURN", "SIGUIENTE TURNO", "СЛЕДУЮЩИЙ ХОД") }
    var guessWord: String { text("GUESS THE WORD", "ADIVINAR PALABRA", "УГАДАТЬ СЛОВО") }
    var startVote: String { text("START VOTE", "INICIAR VOTACIÓN", "НАЧАТЬ ГОЛОСОВАНИЕ") }
    var hideCard: String { text("HIDE CARD", "OCULTAR TARJETA", "СКРЫТЬ КАРТУ") }
    var showCard: String { text("SHOW CARD", "MOSTRAR TARJETA", "ПОКАЗАТЬ КАРТУ") }
    var vote: String { text("VOTE", "VOTAR", "ГОЛОСОВАНИЕ") }
    var guess: String { text("GUESS", "ADIVINAR", "УГАДАТЬ") }

    var paused: String { text("PAUSED", "PAUSA", "ПАУЗА") }
    var timerStopped: String { text("THE TIMER IS STOPPED", "EL TEMPORIZADOR ESTÁ DETENIDO", "ТАЙМЕР ОСТАНОВЛЕН") }
    var resumeGame: String { text("RESUME GAME", "CONTINUAR JUEGO", "ПРОДОЛЖИТЬ ИГРУ") }
}
