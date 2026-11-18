import Foundation

/// Public room presentation metadata. Host reward credentials never enter a room snapshot.
struct RoomGenerationAdOffer: Codable, Hashable, Identifiable {
    let id: UUID
    let hostEmail: String
    let startedAt: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case hostEmail = "host_email"
        case startedAt = "started_at"
        case expiresAt = "expires_at"
    }
}

enum RoomGenerationAdOfferPolicy {
    static func guestOffer(in room: GameRoom?, viewerEmail: String?, now: Date = Date()) -> RoomGenerationAdOffer? {
        guard let room, room.normalizedStatus == "waiting", let offer = room.roomGenerationAd,
              let viewer = viewerEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !viewer.isEmpty,
              room.playersList.contains(where: { $0.email.lowercased() == viewer }),
              let host = room.hostEmail?.lowercased(), offer.hostEmail.lowercased() == host,
              viewer != host,
              let started = timestamp(offer.startedAt), let expiry = timestamp(offer.expiresAt),
              expiry > now, started <= now.addingTimeInterval(30),
              expiry > started, expiry.timeIntervalSince(started) <= 180 else { return nil }
        return offer
    }

    static func expiration(of offer: RoomGenerationAdOffer) -> Date? { timestamp(offer.expiresAt) }

    private static func timestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
