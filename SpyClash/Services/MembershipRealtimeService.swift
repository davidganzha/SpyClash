import Foundation
import SocketIO

@MainActor
final class MembershipRealtimeService {
    var onMembershipSignal: (() -> Void)?
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var scope = MembershipScope(userID: nil, accessToken: nil)
    private var generation = UUID()

    func bind(_ next: MembershipScope) {
        guard scope != next else { return }
        stop()
        scope = next
        guard let userID = next.userID, let token = next.accessToken, next.isAuthenticated else { return }
        let expected = generation
        let rooms = ["MembershipSignal", "MembershipGrant"].map { "entities:\(Base44Client.appID):\($0)" }
        let manager = SocketManager(socketURL: URL(string: "https://base44.app")!, config: [
            .path("/ws-user-apps/socket.io/"), .connectParams(["app_id": Base44Client.appID, "token": token]),
            .forceWebsockets(true), .reconnects(true), .reconnectAttempts(-1),
            .reconnectWait(1), .reconnectWaitMax(8), .log(false), .handleQueue(.main),
        ])
        let socket = manager.defaultSocket
        socket.on(clientEvent: .connect) { [weak self, weak socket] _, _ in
            Task { @MainActor in
                guard let self, self.generation == expected else { return }
                for room in rooms { socket?.emit("join", room) }
                self.onMembershipSignal?()
            }
        }
        socket.on("update_model") { [weak self] payload, _ in
            let accepted = Self.accepts(payload, rooms: rooms, userID: userID)
            Task { @MainActor in
                guard accepted, let self, self.generation == expected else { return }
                // Realtime is only a hint, never evidence that access was granted.
                self.onMembershipSignal?()
            }
        }
        self.manager = manager
        self.socket = socket
        socket.connect()
    }

    func stop() {
        generation = UUID()
        socket?.removeAllHandlers()
        socket?.disconnect()
        manager?.disconnect()
        socket = nil
        manager = nil
        scope = MembershipScope(userID: nil, accessToken: nil)
    }

    nonisolated static func accepts(_ payload: [Any], rooms: [String], userID: String) -> Bool {
        guard let envelope = payload.first as? [String: Any],
              let room = envelope["room"] as? String, rooms.contains(room),
              let raw = envelope["data"] as? String,
              let data = raw.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String, ["create", "update", "delete"].contains(type),
              let record = event["data"] as? [String: Any],
              record["user_id"] as? String == userID else { return false }
        return true
    }
}
