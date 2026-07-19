import Foundation
import SocketIO

@MainActor
final class MembershipRealtimeService {
    var onMembershipSignal: (() -> Void)?

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var room: String?
    private var userID: String?
    private var connectionGeneration: UInt64 = 0

    func start(appID: String, token: String, userID: String) {
        stop()

        let room = "entities:\(appID):MembershipGrant"
        connectionGeneration &+= 1
        let generation = connectionGeneration
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
            guard self?.connectionGeneration == generation else { return }
            socket?.emit("join", room)
        }
        socket.on("update_model") { [weak self] payload, _ in
            let signalUserID = Self.userID(from: payload)
            Task { @MainActor [weak self] in
                guard let self,
                      self.connectionGeneration == generation,
                      signalUserID == nil || signalUserID == self.userID else { return }
                self.onMembershipSignal?()
            }
        }

        self.manager = manager
        self.socket = socket
        self.room = room
        self.userID = userID
        socket.connect()
    }

    func resume() {
        guard let socket, !socket.status.active else { return }
        socket.connect()
    }

    func stop() {
        connectionGeneration &+= 1
        if let room, socket?.status == .connected {
            socket?.emit("leave", room)
        }
        socket?.removeAllHandlers()
        socket?.disconnect()
        manager?.disconnect()
        socket = nil
        manager = nil
        room = nil
        userID = nil
    }

    private nonisolated static func userID(from payload: [Any]) -> String? {
        guard let envelope = payload.first as? [String: Any],
              let dataString = envelope["data"] as? String,
              let data = dataString.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (event["data"] as? [String: Any])?["user_id"] as? String
    }
}
