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
        return 2 + Double(rank) * 1.5
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
