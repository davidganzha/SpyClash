import SwiftUI

struct LocalCinematicParticipant: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let avatar: String
    let isActive: Bool
    let isEliminated: Bool
    let isRevealedSpy: Bool
}

struct LocalCinematicHeader: View {
    let language: AppLanguage
    let isPaused: Bool
    let onStop: () -> Void
    let onTogglePause: () -> Void
    let onShowCard: () -> Void

    private var copy: LocalCinematicCopy { LocalCinematicCopy(language: language) }

    var body: some View {
        HStack(spacing: 8) {
            SpyWordmark(fontSize: 24)
                .dynamicTypeSize(...DynamicTypeSize.large)

            Spacer(minLength: 8)

            headerButton(
                systemImage: "xmark",
                label: copy.stop,
                accessibilityID: "localCinematic.stop",
                action: onStop
            )

            headerButton(
                systemImage: isPaused ? "play.fill" : "pause.fill",
                label: isPaused ? copy.resume : copy.pause,
                accessibilityID: "localCinematic.pause",
                action: onTogglePause
            )

            headerButton(
                systemImage: "rectangle.portrait.fill",
                label: copy.card,
                accessibilityID: "localCinematic.card",
                action: onShowCard
            )
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        .background(Color.black.opacity(0.84))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SpyTheme.stroke)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("localCinematic.header")
    }

    private func headerButton(
        systemImage: String,
        label: String,
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
                .accessibilityHidden(true)
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.94))
        .frame(width: 44, height: 44)
        .accessibilityLabel(label)
        .accessibilityIdentifier(accessibilityID)
    }
}

struct LocalCinematicTimer: View {
    let language: AppLanguage
    let secondsRemaining: Int
    let totalSeconds: Int
    var turn: Int = 1

    @SpyReduceMotion private var reduceMotion

    private var copy: LocalCinematicCopy { LocalCinematicCopy(language: language) }
    private var clampedRemaining: Int { max(secondsRemaining, 0) }
    private var clampedTotal: Int { max(totalSeconds, 1) }
    private var progress: Double {
        min(max(Double(clampedRemaining) / Double(clampedTotal), 0), 1)
    }
    private var isCritical: Bool { clampedRemaining <= 60 }

    var body: some View {
        VStack(spacing: 6) {
            Text(copy.turn(turn))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(isCritical ? SpyTheme.red : SpyTheme.dim)

            ViewThatFits(in: .horizontal) {
                timerText(size: 58)
                timerText(size: 46)
                timerText(size: 36)
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(SpyTheme.stroke)

                    Rectangle()
                        .fill(isCritical ? SpyTheme.red : SpyTheme.redDeep)
                        .frame(width: proxy.size.width * progress)
                        .animation(reduceMotion ? nil : .linear(duration: 0.9), value: progress)
                }
            }
            .frame(height: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(copy.timeRemaining)
        .accessibilityValue(formattedTime)
        .accessibilityIdentifier("localCinematic.timer")
    }

    private var formattedTime: String {
        String(format: "%d:%02d", clampedRemaining / 60, clampedRemaining % 60)
    }

    private func timerText(size: CGFloat) -> some View {
        Text(formattedTime)
            .font(SpyTheme.brandFont(size: size))
            .tracking(1.4)
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(isCritical ? SpyTheme.red : .white)
            .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
    }
}

struct LocalCinematicOperativeRail: View {
    let participants: [LocalCinematicParticipant]
    let language: AppLanguage

    @SpyReduceMotion private var reduceMotion

    private var copy: LocalCinematicCopy { LocalCinematicCopy(language: language) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 14) {
                ForEach(participants) { participant in
                    operative(participant)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 72)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("localCinematic.operatives")
    }

    private func operative(_ participant: LocalCinematicParticipant) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                CutCornerShape(cut: 6)
                    .fill(SpyTheme.control)
                    .frame(width: 40, height: 40)
                    .overlay {
                        CutCornerShape(cut: 6)
                            .stroke(
                                participant.isActive ? SpyTheme.red : SpyTheme.strokeStrong,
                                lineWidth: participant.isActive ? 1.5 : 1
                            )
                    }

                Text(participant.avatar.isEmpty ? fallbackAvatar(participant.name) : participant.avatar)
                    .font(.system(size: 21))
                    .frame(width: 40, height: 40)
                    .saturation(participant.isEliminated ? 0 : 1)

                if participant.isRevealedSpy {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 17, height: 17)
                        .background(SpyTheme.red, in: CutCornerShape(cut: 4))
                        .offset(x: 4, y: 4)
                        .accessibilityHidden(true)
                }
            }

            Text(participant.name.uppercased())
                .font(SpyTheme.brandFont(size: 9))
                .tracking(0.7)
                .foregroundStyle(participant.isEliminated ? SpyTheme.dim : .white)
                .strikethrough(participant.isEliminated, color: SpyTheme.red)
                .lineLimit(1)
                .minimumScaleFactor(0.58)
                .frame(width: 68)

            Rectangle()
                .fill(participant.isActive ? SpyTheme.red : SpyTheme.stroke)
                .frame(width: participant.isActive ? 24 : 10, height: 1)
        }
        .opacity(participant.isEliminated ? 0.48 : 1)
        .scaleEffect(reduceMotion || !participant.isActive ? 1 : 1.04)
        .animation(
            reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82),
            value: participant.isActive
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(participant.name)
        .accessibilityValue(accessibilityStatus(for: participant))
        .accessibilityIdentifier("localCinematic.operative.\(accessibilityKey(participant.id))")
    }

    private func fallbackAvatar(_ name: String) -> String {
        name.first.map { String($0).uppercased() } ?? "•"
    }

    private func accessibilityStatus(for participant: LocalCinematicParticipant) -> String {
        var states: [String] = []
        if participant.isActive { states.append(copy.active) }
        if participant.isEliminated { states.append(copy.eliminated) }
        if participant.isRevealedSpy { states.append(copy.revealedSpy) }
        return states.isEmpty ? copy.waiting : states.joined(separator: ", ")
    }

    private func accessibilityKey(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return String(scalars)
    }
}

struct LocalCinematicPausedOverlay: View {
    let language: AppLanguage
    let onResume: () -> Void
    let onShowCard: () -> Void
    let onStop: () -> Void

    @AccessibilityFocusState private var titleFocused: Bool

    private var copy: LocalCinematicCopy { LocalCinematicCopy(language: language) }

    var body: some View {
        ZStack {
            SpyCinematicBackdrop(intensity: 1.12)

            Color.black.opacity(0.76)
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 30, weight: .black))
                        .foregroundStyle(SpyTheme.red)
                        .accessibilityHidden(true)

                    Text(copy.paused)
                        .font(SpyTheme.brandFont(size: 44))
                        .tracking(3)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.58)
                        .accessibilityHeading(.h1)
                        .accessibilityFocused($titleFocused)

                    Text(copy.timerStopped)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(Color.white.opacity(0.58))
                        .multilineTextAlignment(.center)

                    Button(action: onResume) {
                        Label(copy.resumeGame, systemImage: "play.fill")
                    }
                    .buttonStyle(SpyCinematicButtonStyle(variant: .primary))
                    .frame(maxWidth: 280)
                    .padding(.top, 12)
                    .accessibilityIdentifier("localCinematic.paused.resume")

                    Button(action: onShowCard) {
                        Label(copy.card, systemImage: "rectangle.portrait.fill")
                    }
                    .buttonStyle(SpyCinematicButtonStyle(variant: .secondary))
                    .frame(maxWidth: 280)
                    .accessibilityIdentifier("localCinematic.paused.card")

                    Button(action: onStop) {
                        Label(copy.stopGame, systemImage: "xmark")
                    }
                    .buttonStyle(SpyCinematicButtonStyle(variant: .secondary))
                    .frame(maxWidth: 280)
                    .accessibilityIdentifier("localCinematic.paused.stop")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, minHeight: 520)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("localCinematic.paused")
        .task {
            await Task.yield()
            titleFocused = true
        }
    }
}

private struct LocalCinematicCopy {
    let language: AppLanguage

    init(language: AppLanguage) {
        self.language = language
    }

    private func text(_ en: String, _ es: String, _ ru: String, _ uk: String) -> String {
        switch language {
        case .en: en
        case .es: es
        case .ru: ru
        case .uk: uk
        }
    }

    var stop: String { text("Stop game", "Detener partida", "Остановить игру", "Зупинити гру") }
    var pause: String { text("Pause", "Pausa", "Пауза", "Пауза") }
    var resume: String { text("Resume", "Continuar", "Продолжить", "Продовжити") }
    var card: String { text("Show card", "Mostrar carta", "Показать карту", "Показати картку") }
    var timeRemaining: String { text("Time remaining", "Tiempo restante", "Осталось времени", "Залишилося часу") }
    var paused: String { text("PAUSED", "PAUSA", "ПАУЗА", "ПАУЗА") }
    var timerStopped: String {
        text("THE TIMER IS STOPPED", "EL TEMPORIZADOR ESTÁ DETENIDO", "ТАЙМЕР ОСТАНОВЛЕН", "ТАЙМЕР ЗУПИНЕНО")
    }
    var resumeGame: String { text("RESUME GAME", "CONTINUAR PARTIDA", "ПРОДОЛЖИТЬ ИГРУ", "ПРОДОВЖИТИ ГРУ") }
    var stopGame: String { text("STOP GAME", "DETENER PARTIDA", "ОСТАНОВИТЬ ИГРУ", "ЗУПИНИТИ ГРУ") }
    var active: String { text("Active", "Activo", "Активен", "Активний") }
    var eliminated: String { text("Eliminated", "Eliminado", "Исключён", "Виключений") }
    var revealedSpy: String { text("Revealed spy", "Espía revelado", "Раскрытый шпион", "Розкритий шпигун") }
    var waiting: String { text("Waiting", "En espera", "Ожидает", "Очікує") }

    func turn(_ value: Int) -> String {
        "\(text("TURN", "TURNO", "ХОД", "ХІД")) \(max(value, 1))"
    }
}
