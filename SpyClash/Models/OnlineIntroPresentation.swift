import Foundation

/// Owns the local visual sequence independently of the server's start deadline.
/// Server snapshots can arrive late or advance to gameplay while the cards are
/// still moving; neither event should fast-forward the presentation.
struct OnlineIntroPresentation {
    struct Session: Identifiable {
        fileprivate(set) var id = UUID().uuidString
        let room: GameRoom
        let startedAt: Date
        let duration: TimeInterval
        fileprivate(set) var exitingAt: Date?
        fileprivate let scope: Scope

        var readyAt: Date { startedAt.addingTimeInterval(duration) }

        func remainingDuration(at date: Date) -> TimeInterval {
            max(readyAt.timeIntervalSince(date), 0)
        }
    }

    fileprivate struct Scope: Equatable {
        let accountID: String
        let roomID: String
        let introToken: String

        init?(room: GameRoom, accountID: String?) {
            let account = accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !account.isEmpty else { return nil }
            self.accountID = account
            roomID = room.id
            let timestamp = room.introStartedAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            introToken = timestamp.isEmpty ? "pending" : timestamp
        }
    }

    let duration: TimeInterval
    let revealDuration: TimeInterval
    private(set) var active: Session?

    init(duration: TimeInterval = 3, revealDuration: TimeInterval = 0.45) {
        self.duration = max(duration, 0)
        self.revealDuration = max(revealDuration, 0)
    }

    mutating func update(room: GameRoom?, accountID: String?, now: Date) {
        guard let room, let scope = Scope(room: room, accountID: accountID) else {
            cancel()
            return
        }

        switch room.normalizedStatus {
        case "roulette":
            if active?.scope == scope {
                // Keep the original roster and local clock stable. If the
                // destination disappears during a dissolve, invalidate its
                // completion callback without restarting the card sequence.
                if active?.exitingAt != nil {
                    active?.exitingAt = nil
                    active?.id = UUID().uuidString
                }
                return
            }
            active = Session(room: room, startedAt: now, duration: duration, scope: scope)

        case "playing":
            // A direct join into gameplay never creates a new intro. A new
            // account, room or match must not inherit the old overlay.
            if active?.scope != scope {
                cancel()
            }

        default:
            cancel()
        }
    }

    /// Nil means the authoritative destination is unavailable or a dissolve
    /// is already running. Zero means it is safe to begin revealing gameplay.
    func revealDelay(room: GameRoom?, accountID: String?, now: Date) -> TimeInterval? {
        guard let active, active.exitingAt == nil,
              let room, room.normalizedStatus == "playing",
              Scope(room: room, accountID: accountID) == active.scope else {
            return nil
        }
        // The dissolve occupies the last part of the visual duration. If the
        // network is slower, hold the composed frame and give the dissolve its
        // full duration once the real destination becomes available.
        return max(active.readyAt.addingTimeInterval(-revealDuration).timeIntervalSince(now), 0)
    }

    @discardableResult
    mutating func beginRevealIfReady(room: GameRoom?, accountID: String?, now: Date) -> Bool {
        guard let delay = revealDelay(room: room, accountID: accountID, now: now),
              delay == 0 else { return false }
        active?.exitingAt = now
        return true
    }

    /// A canceled task from an earlier intro cannot remove a newer overlay.
    @discardableResult
    mutating func finishReveal(id: String, now: Date) -> Bool {
        guard let active, active.id == id,
              let exitingAt = active.exitingAt,
              now >= exitingAt.addingTimeInterval(revealDuration) else { return false }
        self.active = nil
        return true
    }

    mutating func cancel() {
        active = nil
    }
}
