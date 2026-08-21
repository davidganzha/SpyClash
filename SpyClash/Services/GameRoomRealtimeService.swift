import Foundation
import SocketIO

struct GameRoomRealtimeSignal: Equatable, Sendable {
    let roomID: String
    let lobbyRevision: Int
    let roomRevision: Int?
    let roomUpdatedAt: String?
    let state: String
}

enum GameRoomRealtimeSignalParser {
    private static let maximumAcceptedRevision = 1_000_000_000

    static func parse(
        payload: [Any],
        expectedEntityRoom: String,
        expectedUserID: String,
        expectedRoomID: String
    ) -> GameRoomRealtimeSignal? {
        guard let envelope = payload.first as? [String: Any],
              envelope["room"] as? String == expectedEntityRoom,
              let dataString = envelope["data"] as? String,
              let data = dataString.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String,
              ["create", "update"].contains(type),
              let eventData = event["data"] as? [String: Any],
              eventData["user_id"] as? String == expectedUserID,
              eventData["room_id"] as? String == expectedRoomID,
              let revision = nonNegativeInteger(eventData["lobby_revision"]),
              let state = eventData["state"] as? String,
              ["active", "closed"].contains(state) else {
            return nil
        }

        let roomRevision: Int?
        if eventData.keys.contains("room_revision") {
            guard let parsed = nonNegativeInteger(eventData["room_revision"]) else {
                return nil
            }
            roomRevision = parsed
        } else {
            roomRevision = nil
        }

        return GameRoomRealtimeSignal(
            roomID: expectedRoomID,
            lobbyRevision: revision,
            roomRevision: roomRevision,
            roomUpdatedAt: (eventData["room_updated_at"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfBlank,
            state: state
        )
    }

    private static func nonNegativeInteger(_ value: Any?) -> Int? {
        let revision: Int?
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let candidate = number.doubleValue
            revision = candidate.isFinite &&
                    candidate >= 0 &&
                    candidate <= Double(maximumAcceptedRevision) &&
                    candidate.rounded(.towardZero) == candidate
                ? Int(candidate)
                : nil
        case let raw as String:
            revision = Int(raw)
        default:
            revision = nil
        }
        guard let revision,
              (0...maximumAcceptedRevision).contains(revision) else { return nil }
        return revision
    }
}

@MainActor
final class GameRoomRealtimeService {
    var onSignal: ((GameRoomRealtimeSignal) -> Void)?
    var onCatchUp: (() -> Void)?

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var entityRoom: String?
    private var userID: String?
    private var gameRoomID: String?
    private var accessToken: String?
    private var generation = UUID()

    func start(appID: String, token: String, userID: String, roomID: String) {
        if self.userID == userID,
           gameRoomID == roomID,
           accessToken == token,
           entityRoom == "entities:\(appID):GameRoomSignal" {
            resume()
            return
        }

        stop()

        let entityRoom = "entities:\(appID):GameRoomSignal"
        let generation = UUID()
        let manager = SocketManager(
            socketURL: URL(string: "https://base44.app")!,
            config: [
                .path("/ws-user-apps/socket.io/"),
                .connectParams([
                    "app_id": appID,
                    "token": token
                ]),
                .forceWebsockets(true),
                .reconnects(true),
                .reconnectAttempts(-1),
                .reconnectWait(1),
                .reconnectWaitMax(8),
                .log(false),
                .handleQueue(.main)
            ]
        )
        let socket = manager.defaultSocket

        socket.on(clientEvent: .connect) { [weak self, weak socket] _, _ in
            Task { @MainActor [weak self, weak socket] in
                guard let self, self.generation == generation else { return }
                socket?.emit("join", entityRoom)
                self.onCatchUp?()
            }
        }
        socket.on("update_model") { [weak self] payload, _ in
            let signal = GameRoomRealtimeSignalParser.parse(
                payload: payload,
                expectedEntityRoom: entityRoom,
                expectedUserID: userID,
                expectedRoomID: roomID
            )
            Task { @MainActor [weak self] in
                guard let self,
                      self.generation == generation,
                      let signal else { return }
                self.onSignal?(signal)
            }
        }

        self.manager = manager
        self.socket = socket
        self.entityRoom = entityRoom
        self.userID = userID
        self.gameRoomID = roomID
        self.accessToken = token
        self.generation = generation
        socket.connect()
    }

    func resume() {
        guard let socket else { return }
        if socket.status == .connected {
            onCatchUp?()
        } else {
            socket.connect()
        }
    }

    func stop() {
        generation = UUID()
        if let entityRoom, socket?.status == .connected {
            socket?.emit("leave", entityRoom)
        }
        socket?.removeAllHandlers()
        socket?.disconnect()
        manager?.disconnect()
        socket = nil
        manager = nil
        entityRoom = nil
        userID = nil
        gameRoomID = nil
        accessToken = nil
    }
}
