import ActivityKit
import Foundation

/// The cross-target contract for a SpyClash match Live Activity.
///
/// Add this file to both the application target and the widget-extension target.
/// All identifiers in this payload must be opaque, per-match identifiers. Never
/// place an email address, access token, room join code, or backend credential in
/// ActivityKit content.
struct SpyClashMatchActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var phase: MatchPhase
        var mode: MatchMode
        var participants: [Participant]
        var currentSpeakerID: String?
        var currentAskerID: String?
        var currentResponderID: String?
        var round: Int
        /// Public match category shown on glanceable system surfaces. This is
        /// deliberately separate from `privateIntel.secretWord`.
        var publicTopic: String?
        /// The language selected inside SpyClash. Widget extensions do not
        /// reliably inherit an app-managed language preference.
        var displayLanguageCode: String?
        /// Unix epoch seconds keep ActivityKit APNs JSON unambiguous. Apple
        /// decodes remote `content-state` using default Codable strategies.
        var timerEndsAtEpochSeconds: Int?
        var pausedSecondsRemaining: Int?
        var privateIntel: PrivateIntel?
        var revision: Int

        init(
            phase: MatchPhase,
            mode: MatchMode,
            participants: [Participant],
            currentSpeakerID: String? = nil,
            currentAskerID: String? = nil,
            currentResponderID: String? = nil,
            round: Int,
            publicTopic: String? = nil,
            displayLanguageCode: String? = nil,
            timerEndsAt: Date? = nil,
            pausedSecondsRemaining: Int? = nil,
            privateIntel: PrivateIntel? = nil,
            revision: Int = 0
        ) {
            self.phase = phase
            self.mode = mode
            self.participants = participants
            self.currentSpeakerID = currentSpeakerID
            self.currentAskerID = currentAskerID
            self.currentResponderID = currentResponderID
            self.round = max(1, round)
            self.publicTopic = publicTopic?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                .map { String($0.prefix(40)) }
            let normalizedLanguage = displayLanguageCode?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
                .split(separator: "-", maxSplits: 1)
                .first
                .map(String.init)
            self.displayLanguageCode = ["en", "es", "ru", "uk"].contains(normalizedLanguage ?? "")
                ? normalizedLanguage
                : nil
            self.timerEndsAtEpochSeconds = timerEndsAt.map {
                Int($0.timeIntervalSince1970.rounded())
            }
            self.pausedSecondsRemaining = pausedSecondsRemaining.map { max(0, $0) }
            self.privateIntel = privateIntel
            self.revision = max(0, revision)
        }

        var speaker: Participant? {
            participant(withID: currentSpeakerID)
                ?? participant(withID: mode == .questions ? currentAskerID : nil)
        }

        var asker: Participant? {
            participant(withID: currentAskerID)
        }

        var responder: Participant? {
            participant(withID: currentResponderID)
        }

        var isTimerRunning: Bool {
            timerEndsAt != nil && pausedSecondsRemaining == nil && phase == .playing
        }

        var timerEndsAt: Date? {
            get {
                timerEndsAtEpochSeconds.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                }
            }
            set {
                timerEndsAtEpochSeconds = newValue.map {
                    Int($0.timeIntervalSince1970.rounded())
                }
            }
        }

        func participant(withID id: String?) -> Participant? {
            guard let id else { return nil }
            return participants.first { $0.id == id }
        }

        /// Lock Screen and Dynamic Island are glanceable, shared surfaces.
        /// Legacy payloads may still contain private intel, so strip it at the
        /// shared contract boundary before either target can render the state.
        func sanitized(for viewerPlayerID: String) -> Self {
            var copy = self
            copy.privateIntel = nil
            return copy
        }
    }

    enum MatchPhase: String, Codable, Hashable, Sendable {
        case preparing
        case playing
        case voting
        case completed
    }

    enum MatchMode: String, Codable, Hashable, Sendable {
        case questions
        case associations

        var shortLabel: String {
            switch self {
            case .questions: "Q&A"
            case .associations: "ASSOCIATIONS"
            }
        }
    }

    struct Participant: Codable, Hashable, Identifiable, Sendable {
        enum Status: String, Codable, Hashable, Sendable {
            case active
            case spectator
            case eliminated
            case disconnected
        }

        /// An opaque, per-match player identifier. Do not use an email address.
        var id: String
        var displayName: String
        var avatarSymbol: String
        var status: Status

        init(
            id: String,
            displayName: String,
            avatarSymbol: String = "🕵️",
            status: Status = .active
        ) {
            self.id = id
            self.displayName = displayName
            self.avatarSymbol = avatarSymbol
            self.status = status
        }

        func resolvedDisplayName(fallback: String) -> String {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed.uppercased()
            guard !trimmed.isEmpty,
                  normalized != "AGENT",
                  normalized != "OPERATIVE" else {
                return fallback
            }
            return trimmed
        }

        func compactName(fallback: String) -> String {
            String(resolvedDisplayName(fallback: fallback).prefix(12)).uppercased()
        }
    }

    struct PrivateIntel: Codable, Hashable, Sendable {
        enum Role: String, Codable, Hashable, Sendable {
            case detective
            case spy
            case spectator
        }

        /// Must equal the attributes' `viewerPlayerID` or the UI won't render it.
        var ownerPlayerID: String
        var role: Role
        var secretWord: String?

        init(ownerPlayerID: String, role: Role, secretWord: String? = nil) {
            self.ownerPlayerID = ownerPlayerID
            self.role = role
            self.secretWord = role == .spy ? nil : secretWord
        }
    }

    /// Stable room identity used only for routing back into the authenticated app.
    var roomID: String

    /// Server-issued identity for exactly one game. A replay receives a new value.
    var matchID: String

    /// Identifies the player who owns this device's personalized Activity.
    var viewerPlayerID: String
    var startedAt: Date

    init(
        roomID: String,
        matchID: String,
        viewerPlayerID: String,
        startedAt: Date = .now
    ) {
        self.roomID = roomID
        self.matchID = matchID
        self.viewerPlayerID = viewerPlayerID
        self.startedAt = startedAt
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
