import Foundation

enum OnlineRoundPhase: String, Codable, CaseIterable {
    case asking
    case answering
    case countdown
    case results

    init(serverValue: String?) {
        let normalized = serverValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self = OnlineRoundPhase(rawValue: normalized ?? "") ?? .asking
    }
}

struct AssociationRoundState: Codable, Equatable {
    var spoken: [String]
    var spinning: Bool

    static let idle = AssociationRoundState(spoken: [], spinning: false)

    static func decode(from value: String?) -> AssociationRoundState {
        guard let value,
              let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AssociationRoundState.self, from: data) else {
            return .idle
        }
        return decoded
    }

    var encodedValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let value = String(data: data, encoding: .utf8) else {
            return #"{"spoken":[],"spinning":false}"#
        }
        return value
    }
}

struct QuestionTurnOrderState<ID: Hashable>: Equatable {
    let order: [ID]
    let step: Int

    var currentAskerID: ID? {
        order.indices.contains(step) ? order[step] : nil
    }

    var currentAnswererID: ID? {
        guard order.count >= 2, order.indices.contains(step) else { return nil }
        return order[(step + 1) % order.count]
    }
}

private struct QuestionTurnOrderPayload: Codable {
    let kind: String
    let order: [String]
}

enum QuestionTurnOrderPolicy {
    static func initial<ID: Hashable>(
        activeIDs: [ID],
        shuffle: ([ID]) -> [ID] = { $0.shuffled() }
    ) -> QuestionTurnOrderState<ID> {
        let active = unique(activeIDs)
        return QuestionTurnOrderState(
            order: normalizedShuffle(active, shuffle: shuffle),
            step: 0
        )
    }

    static func anchored<ID: Hashable>(
        activeIDs: [ID],
        currentAskerID: ID?,
        currentAnswererID: ID?,
        shuffle: ([ID]) -> [ID] = { $0.shuffled() }
    ) -> QuestionTurnOrderState<ID> {
        let active = unique(activeIDs)
        let activeSet = Set(active)
        var seen = Set<ID>()
        var order: [ID] = []

        for candidate in [currentAskerID, currentAnswererID].compactMap({ $0 }) {
            guard activeSet.contains(candidate), seen.insert(candidate).inserted else { continue }
            order.append(candidate)
        }

        let remaining = active.filter { !seen.contains($0) }
        order.append(contentsOf: normalizedShuffle(remaining, shuffle: shuffle))
        return QuestionTurnOrderState(order: order, step: 0)
    }

    static func reconciled<ID: Hashable>(
        state: QuestionTurnOrderState<ID>,
        activeIDs: [ID],
        currentAskerID: ID? = nil,
        currentAnswererID: ID? = nil,
        shuffle: ([ID]) -> [ID] = { $0.shuffled() }
    ) -> QuestionTurnOrderState<ID> {
        let active = unique(activeIDs)
        guard !active.isEmpty else {
            return QuestionTurnOrderState(order: [], step: 0)
        }

        let activeSet = Set(active)
        var seen = Set<ID>()
        var order = state.order.filter { activeSet.contains($0) && seen.insert($0).inserted }
        if order.isEmpty {
            return anchored(
                activeIDs: active,
                currentAskerID: currentAskerID,
                currentAnswererID: currentAnswererID,
                shuffle: shuffle
            )
        }
        order.append(contentsOf: active.filter { seen.insert($0).inserted })

        if let currentAskerID,
           let askerStep = order.firstIndex(of: currentAskerID) {
            return QuestionTurnOrderState(order: order, step: askerStep)
        }

        if let currentAnswererID,
           let answererStep = order.firstIndex(of: currentAnswererID) {
            return QuestionTurnOrderState(order: order, step: answererStep)
        }

        if let retainedAsker = state.currentAskerID,
           let retainedStep = order.firstIndex(of: retainedAsker) {
            return QuestionTurnOrderState(order: order, step: retainedStep)
        }

        if state.order.indices.contains(state.step) {
            for offset in 1...state.order.count {
                let candidate = state.order[(state.step + offset) % state.order.count]
                if let successorStep = order.firstIndex(of: candidate) {
                    return QuestionTurnOrderState(order: order, step: successorStep)
                }
            }
        }

        return QuestionTurnOrderState(order: order, step: 0)
    }

    static func advanced<ID: Hashable>(
        state: QuestionTurnOrderState<ID>,
        activeIDs: [ID],
        shuffle: ([ID]) -> [ID] = { $0.shuffled() }
    ) -> QuestionTurnOrderState<ID> {
        let active = unique(activeIDs)
        let activeSet = Set(active)
        let hadActiveAsker = state.currentAskerID.map(activeSet.contains) ?? false
        let current = reconciled(
            state: state,
            activeIDs: active,
            shuffle: shuffle
        )
        guard hadActiveAsker, current.order.count > 1 else { return current }
        return QuestionTurnOrderState(
            order: current.order,
            step: (current.step + 1) % current.order.count
        )
    }

    private static func unique<ID: Hashable>(_ values: [ID]) -> [ID] {
        var seen = Set<ID>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func normalizedShuffle<ID: Hashable>(
        _ active: [ID],
        shuffle: ([ID]) -> [ID]
    ) -> [ID] {
        let activeSet = Set(active)
        var seen = Set<ID>()
        var result = shuffle(active).filter {
            activeSet.contains($0) && seen.insert($0).inserted
        }
        result.append(contentsOf: active.filter { seen.insert($0).inserted })
        return result
    }
}

enum OnlineQuestionPreviewRoundPolicy {
    private static let stateKind = "question_turn_order_v1"

    static func transition(
        _ command: OnlineRoundCommand,
        room: GameRoom,
        shuffle: ([String]) -> [String] = { $0.shuffled() }
    ) -> GameRoom? {
        guard room.gameModeValue == .questions,
              room.normalizedStatus == "playing" else { return nil }

        let activeEmails = activeQuestionEmails(in: room)
        guard activeEmails.count >= 2 else { return nil }

        let phase = room.onlineRoundPhase
        guard (command == .markAnswerHeard && (phase == .asking || phase == .countdown)) ||
                (command == .continueRound && phase == .results) else { return nil }

        var turnOrder = preparedTurnOrder(
            room: room,
            activeEmails: activeEmails,
            shuffle: shuffle
        )

        var nextRoom = room
        nextRoom.countdownStartedAt = nil

        switch command {
        case .markAnswerHeard:
            let currentCount = max(room.questionsInRound ?? 0, 0)
            let nextCount = currentCount + 1
            if nextCount >= 8 {
                // Match production: the eighth answer opens results without
                // moving the pair or rewriting the persisted count of seven.
                nextRoom.questionPhase = "results"
            } else {
                turnOrder = QuestionTurnOrderPolicy.advanced(
                    state: turnOrder,
                    activeIDs: activeEmails,
                    shuffle: shuffle
                )
                nextRoom.currentAskerEmail = turnOrder.currentAskerID
                nextRoom.currentAnswererEmail = turnOrder.currentAnswererID
                nextRoom.questionsInRound = nextCount
                nextRoom.questionPhase = "asking"
            }
        case .continueRound:
            turnOrder = QuestionTurnOrderPolicy.advanced(
                state: turnOrder,
                activeIDs: activeEmails,
                shuffle: shuffle
            )
            nextRoom.currentAskerEmail = turnOrder.currentAskerID
            nextRoom.currentAnswererEmail = turnOrder.currentAnswererID
            nextRoom.questionPhase = "asking"
            nextRoom.roundNumber = (room.roundNumber ?? 1) + 1
            nextRoom.questionsInRound = 0
            nextRoom.currentAnswerFeedback = nil
            nextRoom.playerFeedback = []
        case .startAssociation, .advanceAssociation:
            return nil
        }

        nextRoom.currentAnswer = encodedValue(for: turnOrder)
        return nextRoom
    }

    private static func preparedTurnOrder(
        room: GameRoom,
        activeEmails: [String],
        shuffle: ([String]) -> [String]
    ) -> QuestionTurnOrderState<String> {
        let asker = normalizedEmail(room.currentAskerEmail)
        let answerer = normalizedEmail(room.currentAnswererEmail)
        let persistedOrder = decodedOrder(from: room.currentAnswer)
        guard !persistedOrder.isEmpty else {
            return QuestionTurnOrderPolicy.anchored(
                activeIDs: activeEmails,
                currentAskerID: asker,
                currentAnswererID: answerer,
                shuffle: shuffle
            )
        }

        let persistedStep = asker.flatMap { persistedOrder.firstIndex(of: $0) } ?? 0
        return QuestionTurnOrderPolicy.reconciled(
            state: QuestionTurnOrderState(order: persistedOrder, step: persistedStep),
            activeIDs: activeEmails,
            currentAskerID: asker,
            currentAnswererID: answerer,
            shuffle: shuffle
        )
    }

    private static func activeQuestionEmails(in room: GameRoom) -> [String] {
        let eliminated = Set((room.eliminatedEmails ?? []).compactMap(normalizedEmail))
        var seen = Set<String>()
        return room.activePlayers.compactMap { player in
            guard let email = normalizedEmail(player.email),
                  !eliminated.contains(email),
                  seen.insert(email).inserted else { return nil }
            return email
        }
    }

    private static func decodedOrder(from value: String?) -> [String] {
        guard let value,
              let data = value.data(using: .utf8),
              let payload = try? JSONDecoder().decode(QuestionTurnOrderPayload.self, from: data),
              payload.kind == stateKind else { return [] }
        var seen = Set<String>()
        return payload.order.compactMap { value in
            guard let email = normalizedEmail(value), seen.insert(email).inserted else { return nil }
            return email
        }
    }

    private static func encodedValue(for state: QuestionTurnOrderState<String>) -> String {
        let payload = QuestionTurnOrderPayload(kind: stateKind, order: state.order)
        guard let data = try? JSONEncoder().encode(payload),
              let value = String(data: data, encoding: .utf8) else {
            return #"{"kind":"question_turn_order_v1","order":[]}"#
        }
        return value
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        let email = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let email, !email.isEmpty else { return nil }
        return email
    }
}

enum OnlineRoundCommand: Equatable {
    case markAnswerHeard
    case continueRound
    case startAssociation
    case advanceAssociation
}

extension GameRoom {
    var onlineRoundPhase: OnlineRoundPhase {
        OnlineRoundPhase(serverValue: questionPhase)
    }

    var associationRoundState: AssociationRoundState {
        AssociationRoundState.decode(from: currentAnswer)
    }

    func containsPlayer(email: String?) -> Bool {
        guard let normalizedEmail = Self.normalizedPlayerEmail(email) else { return false }
        return playersList.contains {
            Self.normalizedPlayerEmail($0.email) == normalizedEmail
        }
    }

    func onlineRoundCommand(
        for userEmail: String?,
        isHost: Bool,
        isTransitioning: Bool
    ) -> OnlineRoundCommand? {
        guard normalizedStatus == "playing",
              !isGamePaused,
              !isTransitioning,
              containsPlayer(email: userEmail),
              let normalizedUserEmail = Self.normalizedPlayerEmail(userEmail) else {
            return nil
        }

        if onlineRoundPhase == .results {
            return .continueRound
        }

        if gameModeValue == .associations {
            let state = associationRoundState
            guard !state.spinning else { return nil }

            guard let speakerEmail = Self.normalizedPlayerEmail(currentAskerEmail) else {
                return isHost ? .startAssociation : nil
            }
            return speakerEmail == normalizedUserEmail ? .advanceAssociation : nil
        }

        guard onlineRoundPhase == .asking,
              Self.normalizedPlayerEmail(currentAskerEmail) == normalizedUserEmail else {
            return nil
        }
        return .markAnswerHeard
    }

    func canStopAssociationSpin(for userEmail: String?, isHost _: Bool) -> Bool {
        guard normalizedStatus == "playing",
              !isGamePaused,
              gameModeValue == .associations,
              associationRoundState.spinning else {
            return false
        }
        return associationSpinSettlementDelay(for: userEmail) != nil
    }

    func associationSpinSettlementDelay(for userEmail: String?) -> TimeInterval? {
        guard let normalizedUserEmail = Self.normalizedPlayerEmail(userEmail) else {
            return nil
        }
        let activeEmails = activePlayers.compactMap {
            Self.normalizedPlayerEmail($0.email)
        }
        guard activeEmails.contains(normalizedUserEmail) else { return nil }

        var prioritizedEmails: [String] = []
        func addCandidate(_ email: String?) {
            guard let normalized = Self.normalizedPlayerEmail(email),
                  activeEmails.contains(normalized),
                  !prioritizedEmails.contains(normalized) else { return }
            prioritizedEmails.append(normalized)
        }
        addCandidate(currentAskerEmail)
        addCandidate(hostEmail)
        activeEmails.forEach { addCandidate($0) }

        guard let rank = prioritizedEmails.firstIndex(of: normalizedUserEmail) else {
            return nil
        }
        let minimumDelay: TimeInterval = 0.5
        let maximumDelay: TimeInterval = 1.5
        guard prioritizedEmails.count > 1 else { return minimumDelay }
        let step = (maximumDelay - minimumDelay) / Double(prioritizedEmails.count - 1)
        return minimumDelay + Double(rank) * step
    }

    func countdownRemaining(
        at date: Date,
        duration: TimeInterval = 0
    ) -> TimeInterval {
        guard onlineRoundPhase == .countdown else { return 0 }
        guard let startedAt = OnlineRoundTimestamp.date(from: countdownStartedAt) else {
            return max(duration, 0)
        }
        return max(duration - date.timeIntervalSince(startedAt), 0)
    }

    func shouldAdvanceQuestionAfterCountdown(for userEmail: String?, at date: Date) -> Bool {
        onlineRoundPhase == .countdown &&
            countdownRemaining(at: date) <= 0 &&
            Self.normalizedPlayerEmail(currentAskerEmail) == Self.normalizedPlayerEmail(userEmail)
    }

    private static func normalizedPlayerEmail(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }
}

private enum OnlineRoundTimestamp {
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
