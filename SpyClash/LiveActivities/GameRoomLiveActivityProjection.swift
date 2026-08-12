import CryptoKit
import Foundation

struct GameRoomLiveActivityProjection {
    let attributes: SpyClashMatchActivityAttributes
    let state: SpyClashMatchActivityAttributes.ContentState
}

extension GameRoom {
    func liveActivityProjection(
        for viewer: SpyUser,
        displayLanguage: AppLanguage? = nil
    ) -> GameRoomLiveActivityProjection? {
        guard let currentMatchID = matchID?.nilIfBlank,
              ["playing", "finished"].contains(normalizedStatus),
              playersList.contains(where: { normalizedEmail($0.email) == normalizedEmail(viewer.email) }) else {
            return nil
        }

        let viewerID = liveActivityPlayerID(email: viewer.email)
        var projectedPlayers = Array(playersList.prefix(12))
        if !projectedPlayers.contains(where: { normalizedEmail($0.email) == normalizedEmail(viewer.email) }),
           let viewerPlayer = playersList.first(where: { normalizedEmail($0.email) == normalizedEmail(viewer.email) }) {
            projectedPlayers = Array(projectedPlayers.prefix(11)) + [viewerPlayer]
        }

        let participants = projectedPlayers.map { player in
            SpyClashMatchActivityAttributes.Participant(
                id: liveActivityPlayerID(email: player.email),
                displayName: String(player.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24)),
                avatarSymbol: player.avatar.first.map(String.init) ?? "🕵️",
                status: participantStatus(email: player.email)
            )
        }

        let mode: SpyClashMatchActivityAttributes.MatchMode = gameModeValue == .associations
            ? .associations
            : .questions
        let phase = liveActivityPhase
        let askerID = currentAskerEmail.map(liveActivityPlayerID(email:))
        let responderID = currentAnswererEmail.map(liveActivityPlayerID(email:))
        let speakerID = askerID
        let startedAt = gameStartedAt.flatMap(Self.liveActivityDate(from:)) ?? .now
        let timer = liveActivityTimer(startedAt: startedAt, phase: phase)
        let revision = max(0, (roundNumber ?? 1) * 1_000 + (questionsInRound ?? 0) * 10 + phaseRevision)

        return GameRoomLiveActivityProjection(
            attributes: SpyClashMatchActivityAttributes(
                roomID: id,
                matchID: currentMatchID,
                viewerPlayerID: viewerID,
                startedAt: startedAt
            ),
            state: SpyClashMatchActivityAttributes.ContentState(
                phase: phase,
                mode: mode,
                participants: participants,
                currentSpeakerID: speakerID,
                currentAskerID: mode == .questions ? askerID : nil,
                currentResponderID: mode == .questions ? responderID : nil,
                round: roundNumber ?? 1,
                publicTopic: category?.nilIfBlank ?? "CLASSIC",
                displayLanguageCode: (
                    displayLanguage ?? AppLanguage.normalized(
                        viewer.language ?? AppLanguage.stored.rawValue
                    )
                ).rawValue,
                timerEndsAt: timer.endsAt,
                pausedSecondsRemaining: timer.pausedSecondsRemaining,
                // Lock Screen and Dynamic Island are glanceable surfaces.
                // Never project a player's role or secret word outside the app.
                privateIntel: nil,
                revision: revision
            )
        )
    }

    func liveActivityPlayerID(email: String) -> String {
        let input = "\(id)|\(normalizedEmail(email))"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private var liveActivityPhase: SpyClashMatchActivityAttributes.MatchPhase {
        if ["finished", "ended"].contains(normalizedStatus) {
            return .completed
        }
        if isVotingActive || questionPhase?.lowercased() == "results" {
            return .voting
        }
        if normalizedStatus == "playing" {
            return .playing
        }
        return .preparing
    }

    private var phaseRevision: Int {
        switch liveActivityPhase {
        case .preparing: 1
        case .playing: 2
        case .voting: 3
        case .completed: 4
        }
    }

    private func participantStatus(
        email: String
    ) -> SpyClashMatchActivityAttributes.Participant.Status {
        let normalized = normalizedEmail(email)
        if spectatorsList.contains(where: { normalizedEmail($0) == normalized }) {
            return .spectator
        }
        if (eliminatedEmails ?? []).contains(where: { normalizedEmail($0) == normalized }) {
            return .eliminated
        }
        return .active
    }

    private func liveActivityTimer(
        startedAt: Date,
        phase: SpyClashMatchActivityAttributes.MatchPhase
    ) -> (endsAt: Date?, pausedSecondsRemaining: Int?) {
        guard phase == .playing else { return (nil, nil) }

        let duration = max(0, gameDurationSeconds ?? 0)
        let accumulatedPause = max(0, gamePausedTotalSeconds ?? 0)
        if let rawPausedAt = gamePausedAt?.nilIfBlank,
           let pausedAt = Self.liveActivityDate(from: rawPausedAt) {
            let activeElapsed = max(
                0,
                Int(pausedAt.timeIntervalSince(startedAt).rounded(.down)) - accumulatedPause
            )
            return (nil, max(0, duration - activeElapsed))
        }

        return (
            startedAt.addingTimeInterval(TimeInterval(duration + accumulatedPause)),
            nil
        )
    }

    private func normalizedEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func liveActivityDate(from raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
