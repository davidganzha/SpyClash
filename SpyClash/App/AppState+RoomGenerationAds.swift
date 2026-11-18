import Foundation

@MainActor
protocol RoomGenerationAdPublishingClient: AnyObject {
    func publishRoomGenerationAd(room: GameRoom, sessionID: UUID, isPresenting: Bool) async throws -> GameRoom
}
extension Base44Client: RoomGenerationAdPublishingClient {}

/// Serializes a host's begin/end signals without putting room networking in the
/// critical ad/reward path. Guest choices never enter this coordinator.
@MainActor
final class RoomGenerationAdPublicationCoordinator {
    private struct Publication { let room: GameRoom; let id: UUID }
    private var publication: Publication?
    private var task: Task<Void, Never>?
    var hasActivePublication: Bool { publication != nil }

    func reconcile(roomID: String?) {
        guard let publication, publication.room.id != roomID else { return }
        self.publication = nil
        task?.cancel()
    }

    func update(_ presenting: Bool, room: GameRoom?, client: any RoomGenerationAdPublishingClient,
                ownsContext: @escaping @MainActor () -> Bool,
                onSnapshot: @escaping @MainActor (GameRoom) -> Void) {
        let current: Publication
        if presenting {
            guard publication == nil, let room, room.normalizedStatus == "waiting" else { return }
            current = Publication(room: room, id: UUID())
            publication = current
        } else {
            guard let pending = publication else { return }
            current = pending
            publication = nil
        }
        let preceding = task
        task = Task { @MainActor in
            await preceding?.value
            guard !Task.isCancelled, ownsContext() else { return }
            do {
                let snapshot = try await client.publishRoomGenerationAd(room: current.room, sessionID: current.id, isPresenting: presenting)
                guard !Task.isCancelled, ownsContext() else { return }
                onSnapshot(snapshot)
            } catch {
                // This optional room offer must never prevent the host's ad or
                // S2S confirmation. Server TTL also bounds lost end signals.
            }
        }
    }

    func waitForPendingPublication() async { await task?.value }
}

extension AppState {
    func publishRoomGenerationAdPresentation(_ isPresenting: Bool, roomID: String? = nil) {
        guard !shouldUsePreviewData, let roomID, let room = activeRoom, room.id == roomID,
              let accountID = user?.id, let email = user?.email,
              room.hostEmail?.lowercased() == email.lowercased(),
              room.playersList.contains(where: { $0.email.lowercased() == email.lowercased() }) else { return }
        let generation = client.sessionGeneration
        roomGenerationAdPublication.update(isPresenting, room: room, client: client, ownsContext: { [weak self] in
            guard let self else { return false }
            return !self.shouldUsePreviewData && self.user?.id == accountID && self.client.sessionGeneration == generation
                && self.activeRoom?.id == roomID && self.activeRoom?.hostEmail?.lowercased() == email.lowercased()
        }, onSnapshot: { [weak self] snapshot in self?.adoptRoomGenerationAdSnapshot(snapshot) })
    }
}
