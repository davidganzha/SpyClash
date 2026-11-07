import SwiftUI

struct LocalPrivateVote: Equatable, Hashable {
    let voterIndex: Int
    let targetIndex: Int
}

enum LocalPrivateVoteDecision: Equatable {
    case continueVoting(threshold: Int, viableCandidateIndices: [Int])
    case eject(index: Int, threshold: Int)
    case cancel(threshold: Int)
}

enum LocalPrivateVotePolicy {
    static func appendingImmutableVote(
        voterIndex: Int,
        targetIndex: Int,
        activeIndices: [Int],
        existingVotes: [LocalPrivateVote]
    ) -> [LocalPrivateVote]? {
        let active = canonicalActiveIndices(activeIndices)
        guard active.contains(voterIndex),
              active.contains(targetIndex),
              voterIndex != targetIndex,
              !existingVotes.contains(where: { $0.voterIndex == voterIndex }) else {
            return nil
        }

        return canonicalVotes(existingVotes, activeIndices: active) + [
            LocalPrivateVote(voterIndex: voterIndex, targetIndex: targetIndex)
        ]
    }

    static func decision(
        activeIndices: [Int],
        activeSpyIndices: Set<Int>,
        votes rawVotes: [LocalPrivateVote]
    ) -> LocalPrivateVoteDecision {
        let active = canonicalActiveIndices(activeIndices)
        let activeSet = Set(active)
        let spyCount = activeSpyIndices.intersection(activeSet).count
        let threshold = active.isEmpty ? 1 : max(1, active.count - spyCount)
        let votes = canonicalVotes(rawVotes, activeIndices: active)
        let counts = Dictionary(grouping: votes, by: \.targetIndex).mapValues(\.count)

        if let ejectedIndex = active.first(where: { (counts[$0] ?? 0) >= threshold }) {
            return .eject(index: ejectedIndex, threshold: threshold)
        }

        let voters = Set(votes.map(\.voterIndex))
        let unvoted = active.filter { !voters.contains($0) }
        let viable = active.filter { candidateIndex in
            let currentVotes = counts[candidateIndex] ?? 0
            let eligibleRemaining = unvoted.filter { $0 != candidateIndex }.count
            return currentVotes + eligibleRemaining >= threshold
        }

        return viable.isEmpty
            ? .cancel(threshold: threshold)
            : .continueVoting(threshold: threshold, viableCandidateIndices: viable)
    }

    static func threshold(activeIndices: [Int], activeSpyIndices: Set<Int>) -> Int {
        let active = canonicalActiveIndices(activeIndices)
        let spyCount = activeSpyIndices.intersection(Set(active)).count
        return active.isEmpty ? 1 : max(1, active.count - spyCount)
    }

    private static func canonicalActiveIndices(_ values: [Int]) -> [Int] {
        var seen = Set<Int>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func canonicalVotes(
        _ values: [LocalPrivateVote],
        activeIndices: [Int]
    ) -> [LocalPrivateVote] {
        let active = Set(activeIndices)
        var seenVoters = Set<Int>()
        return values.filter { vote in
            guard active.contains(vote.voterIndex),
                  active.contains(vote.targetIndex),
                  vote.voterIndex != vote.targetIndex,
                  seenVoters.insert(vote.voterIndex).inserted else {
                return false
            }
            return true
        }
    }
}

struct LocalPrivateDecisionParticipant: Identifiable, Equatable, Hashable {
    let index: Int
    let name: String
    let avatar: String

    var id: Int { index }
}

enum LocalPrivateVoteStage: Hashable {
    case handoff
    case ballot
    case sealed
}

struct LocalPrivateVoteView: View {
    let participants: [LocalPrivateDecisionParticipant]
    let voterIndex: Int
    let votesCast: Int
    let threshold: Int
    let stage: LocalPrivateVoteStage
    let selectedTargetIndex: Int?
    let language: AppLanguage
    let onConfirmHandoff: () -> Void
    let onSelectTarget: (Int) -> Void
    let onConfirmVote: () -> Void

    @SpyReduceMotion private var reduceMotion
    @AccessibilityFocusState private var headingFocused: Bool

    private var copy: LocalPrivateDecisionCopy { LocalPrivateDecisionCopy(language: language) }
    private var voter: LocalPrivateDecisionParticipant? {
        participants.first(where: { $0.index == voterIndex })
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Group {
                switch stage {
                case .handoff:
                    handoff
                case .ballot:
                    ballot
                case .sealed:
                    sealed
                }
            }
            .id(stage)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.84), value: stage)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("localGame.privateVote")
        .onAppear(perform: focusHeading)
        .onChange(of: stage) { _, _ in focusHeading() }
    }

    private var handoff: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 42, weight: .black))
                .foregroundStyle(SpyTheme.red)
                .shadow(color: SpyTheme.red.opacity(0.28), radius: 20)
                .accessibilityHidden(true)

            Text(copy.passPhone)
                .font(SpyTheme.brandFont(size: 34))
                .tracking(1.8)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityHeading(.h1)
                .accessibilityFocused($headingFocused)

            if let voter {
                VStack(spacing: 7) {
                    Text(voter.avatar)
                        .font(.system(size: 42))
                    Text(voter.name.uppercased())
                        .font(SpyTheme.brandFont(size: 22))
                        .tracking(1.1)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.58)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .frame(maxWidth: 310)
                .background(Color.black.opacity(0.68), in: CutCornerShape(cut: 10))
                .overlay(CutCornerShape(cut: 10).stroke(SpyTheme.red.opacity(0.46), lineWidth: 1))
            }

            Text(copy.handoffBody)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SpyTheme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 360)

            Text(copy.progress(votesCast: votesCast, total: participants.count))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(SpyTheme.dim)

            Button(action: onConfirmHandoff) {
                Label(copy.continuePrivately, systemImage: "eye.slash.fill")
            }
            .buttonStyle(SpyCinematicButtonStyle(variant: .primary))
            .frame(maxWidth: 320)
            .padding(.top, 4)
            .accessibilityIdentifier("localGame.privateVote.handoff.confirm")
        }
    }

    private var ballot: some View {
        VStack(spacing: 14) {
            Text(copy.privateBallot)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2.1)
                .foregroundStyle(SpyTheme.red)
                .accessibilityHeading(.h1)
                .accessibilityFocused($headingFocused)

            Text(copy.chooseSuspect)
                .font(SpyTheme.brandFont(size: 31))
                .tracking(1.5)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text(copy.ballotBody(threshold: threshold))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(SpyTheme.dim)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 390)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132), spacing: 9)],
                spacing: 9
            ) {
                ForEach(participants.filter { $0.index != voterIndex }) { participant in
                    candidate(participant)
                }
            }
            .padding(.vertical, 4)

            Button(action: onConfirmVote) {
                Label(copy.lockVote, systemImage: "lock.fill")
            }
            .buttonStyle(SpyCinematicButtonStyle(variant: .primary))
            .frame(maxWidth: 320)
            .disabled(selectedTargetIndex == nil)
            .accessibilityIdentifier("localGame.privateVote.confirm")

            Text(copy.noVoteHistory)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(SpyTheme.dim)
                .multilineTextAlignment(.center)
        }
    }

    private var sealed: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 42, weight: .black))
                .foregroundStyle(SpyTheme.green)
                .accessibilityHidden(true)

            Text(copy.voteLocked)
                .font(SpyTheme.brandFont(size: 34))
                .tracking(1.8)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityHeading(.h1)
                .accessibilityFocused($headingFocused)

            Text(copy.sealedBody)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(SpyTheme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 360)

            ProgressView()
                .tint(SpyTheme.red)
                .accessibilityLabel(copy.preparingNextVote)
        }
        .padding(.vertical, 32)
    }

    private func candidate(_ participant: LocalPrivateDecisionParticipant) -> some View {
        let selected = selectedTargetIndex == participant.index
        return Button {
            onSelectTarget(participant.index)
        } label: {
            VStack(spacing: 7) {
                Text(participant.avatar)
                    .font(.system(size: 29))
                Text(participant.name.uppercased())
                    .font(SpyTheme.brandFont(size: 14))
                    .tracking(0.8)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.56)
                    .multilineTextAlignment(.center)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(selected ? SpyTheme.red : SpyTheme.dim)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 112)
            .background(selected ? SpyTheme.red.opacity(0.13) : Color.black.opacity(0.56), in: CutCornerShape(cut: 8))
            .overlay {
                CutCornerShape(cut: 8)
                    .stroke(selected ? SpyTheme.red : SpyTheme.strokeStrong, lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(CutCornerShape(cut: 8))
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.97))
        .accessibilityLabel(participant.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("localGame.privateVote.candidate.\(participant.index)")
    }

    private func focusHeading() {
        Task { @MainActor in
            await Task.yield()
            headingFocused = true
        }
    }
}

struct LocalSpyGuessHandoffView: View {
    let language: AppLanguage
    let onContinue: () -> Void

    @AccessibilityFocusState private var headingFocused: Bool

    private var copy: LocalPrivateDecisionCopy { LocalPrivateDecisionCopy(language: language) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 18) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 48, weight: .black))
                    .foregroundStyle(SpyTheme.red)
                    .shadow(color: SpyTheme.red.opacity(0.30), radius: 22)
                    .accessibilityHidden(true)

                Text(copy.passToSpy)
                    .font(SpyTheme.brandFont(size: 36))
                    .tracking(1.8)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .accessibilityHeading(.h1)
                    .accessibilityFocused($headingFocused)

                Text(copy.spyHandoffBody)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SpyTheme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 360)

                Button(action: onContinue) {
                    Label(copy.iAmSpy, systemImage: "lock.shield.fill")
                }
                .buttonStyle(SpyCinematicButtonStyle(variant: .primary))
                .frame(maxWidth: 320)
                .padding(.top, 8)
                .accessibilityIdentifier("localGame.spyGuess.handoff.confirm")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 26)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("localGame.spyGuess.handoff")
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                headingFocused = true
            }
        }
    }
}

struct LocalPrivateReturnView: View {
    let language: AppLanguage
    let onContinue: () -> Void

    @AccessibilityFocusState private var headingFocused: Bool

    private var copy: LocalPrivateDecisionCopy { LocalPrivateDecisionCopy(language: language) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 48, weight: .black))
                        .foregroundStyle(SpyTheme.red)
                        .accessibilityHidden(true)

                    Text(copy.screenSealed)
                        .font(SpyTheme.brandFont(size: 36))
                        .tracking(1.8)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .accessibilityHeading(.h1)
                        .accessibilityFocused($headingFocused)

                    Text(copy.returnPhoneBody)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SpyTheme.muted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .frame(maxWidth: 360)

                    Button(action: onContinue) {
                        Label(copy.resumeRound, systemImage: "play.fill")
                    }
                    .buttonStyle(SpyCinematicButtonStyle(variant: .primary))
                    .frame(maxWidth: 320)
                    .padding(.top, 8)
                    .accessibilityIdentifier("localGame.spyGuess.sealed.resume")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 30)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("localGame.spyGuess.sealed")
        .task {
            await Task.yield()
            headingFocused = true
        }
    }
}

private struct LocalPrivateDecisionCopy {
    let language: AppLanguage

    private func text(_ en: String, _ es: String, _ ru: String, _ uk: String) -> String {
        switch language {
        case .en: en
        case .es: es
        case .ru: ru
        case .uk: uk
        }
    }

    var passPhone: String { text("PASS THE PHONE", "PASA EL TELÉFONO", "ПЕРЕДАЙТЕ ТЕЛЕФОН", "ПЕРЕДАЙТЕ ТЕЛЕФОН") }
    var handoffBody: String {
        text(
            "Everything after the next button is private. Do not show the ballot to the other players.",
            "Todo lo que aparece después del siguiente botón es privado. No muestres la papeleta a los demás.",
            "Всё после следующей кнопки — приватно. Не показывайте бюллетень другим игрокам.",
            "Усе після наступної кнопки — приватно. Не показуйте бюлетень іншим гравцям."
        )
    }
    var continuePrivately: String { text("CONTINUE PRIVATELY", "CONTINUAR EN PRIVADO", "ПРОДОЛЖИТЬ ПРИВАТНО", "ПРОДОВЖИТИ ПРИВАТНО") }
    var privateBallot: String { text("// PRIVATE BALLOT", "// VOTO PRIVADO", "// ПРИВАТНЫЙ ГОЛОС", "// ПРИВАТНИЙ ГОЛОС") }
    var chooseSuspect: String { text("CHOOSE A SUSPECT", "ELIGE UN SOSPECHOSO", "ВЫБЕРИТЕ ПОДОЗРЕВАЕМОГО", "ОБЕРІТЬ ПІДОЗРЮВАНОГО") }
    var lockVote: String { text("LOCK VOTE", "FIJAR VOTO", "ЗАФИКСИРОВАТЬ ГОЛОС", "ЗАФІКСУВАТИ ГОЛОС") }
    var noVoteHistory: String {
        text(
            "PREVIOUS CHOICES ARE NEVER SHOWN",
            "LAS ELECCIONES ANTERIORES NUNCA SE MUESTRAN",
            "ПРЕДЫДУЩИЕ ВЫБОРЫ НЕ ПОКАЗЫВАЮТСЯ",
            "ПОПЕРЕДНІ ВИБОРИ НЕ ПОКАЗУЮТЬСЯ"
        )
    }
    var voteLocked: String { text("VOTE LOCKED", "VOTO FIJADO", "ГОЛОС ПРИНЯТ", "ГОЛОС ПРИЙНЯТО") }
    var sealedBody: String {
        text(
            "The choice is hidden. Pass the phone on without discussing the ballot.",
            "La elección está oculta. Pasa el teléfono sin comentar el voto.",
            "Выбор скрыт. Передайте телефон дальше, не обсуждая голос.",
            "Вибір приховано. Передайте телефон далі, не обговорюючи голос."
        )
    }
    var preparingNextVote: String { text("Preparing next vote", "Preparando el siguiente voto", "Подготовка следующего голоса", "Підготовка наступного голосу") }
    var passToSpy: String { text("PASS TO A SPY", "PASA A UN ESPÍA", "ПЕРЕДАЙТЕ ШПИОНУ", "ПЕРЕДАЙТЕ ШПИГУНУ") }
    var spyHandoffBody: String {
        text(
            "Only an active spy may continue. Make sure nobody else can see the screen before opening the word list.",
            "Solo un espía activo puede continuar. Asegúrate de que nadie más vea la pantalla antes de abrir la lista de palabras.",
            "Продолжить может только активный шпион. Перед открытием списка слов убедитесь, что экран никто больше не видит.",
            "Продовжити може лише активний шпигун. Перед відкриттям списку слів переконайтеся, що екран більше ніхто не бачить."
        )
    }
    var iAmSpy: String { text("I'M A SPY — CONTINUE", "SOY ESPÍA — CONTINUAR", "Я ШПИОН — ПРОДОЛЖИТЬ", "Я ШПИГУН — ПРОДОВЖИТИ") }
    var screenSealed: String { text("SCREEN SEALED", "PANTALLA PROTEGIDA", "ЭКРАН ЗАКРЫТ", "ЕКРАН ЗАКРИТО") }
    var returnPhoneBody: String {
        text(
            "The private choice is no longer visible. Return the phone to the group before continuing.",
            "La elección privada ya no está visible. Devuelve el teléfono al grupo antes de continuar.",
            "Приватный выбор больше не виден. Верните телефон группе перед продолжением.",
            "Приватний вибір більше не видно. Поверніть телефон групі перед продовженням."
        )
    }
    var resumeRound: String { text("PHONE RETURNED — RESUME", "TELÉFONO DEVUELTO — SEGUIR", "ТЕЛЕФОН ВОЗВРАЩЁН — ПРОДОЛЖИТЬ", "ТЕЛЕФОН ПОВЕРНУТО — ПРОДОВЖИТИ") }

    func progress(votesCast: Int, total: Int) -> String {
        text("VOTE", "VOTO", "ГОЛОС", "ГОЛОС") + " \(min(max(votesCast + 1, 1), max(total, 1))) / \(max(total, 1))"
    }

    func ballotBody(threshold: Int) -> String {
        let prefix = text(
            "You cannot vote for yourself. The choice is locked after confirmation.",
            "No puedes votarte. La elección queda fijada después de confirmarla.",
            "Нельзя голосовать за себя. После подтверждения выбор фиксируется.",
            "Не можна голосувати за себе. Після підтвердження вибір фіксується."
        )
        let suffix = text("Required", "Se requieren", "Нужно голосов", "Потрібно голосів")
        return "\(prefix) \(suffix): \(threshold)."
    }
}
