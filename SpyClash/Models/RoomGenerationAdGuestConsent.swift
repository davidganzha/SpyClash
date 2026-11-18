import Foundation

struct RoomGenerationAdGuestScope: Equatable {
    let roomID: String
    let userID: String
}

/// One explicit choice covers the next *new* host offer in this foreground
/// room membership. Replayed/existing signals and backgrounding never autoplay.
struct RoomGenerationAdGuestConsent {
    private(set) var scope: RoomGenerationAdGuestScope?
    private(set) var isArmed = false
    private(set) var observedOfferID: UUID?
    private var seenOfferIDs: [UUID] = []

    mutating func bind(_ scope: RoomGenerationAdGuestScope?, currentOfferID: UUID?) {
        guard self.scope != scope else { return }
        self = Self(); self.scope = scope; observedOfferID = currentOfferID
        if let currentOfferID { seenOfferIDs = [currentOfferID] }
    }

    mutating func setArmed(_ enabled: Bool, currentOfferID: UUID?, isForeground: Bool) {
        isArmed = enabled && scope != nil && currentOfferID == nil && isForeground
    }

    mutating func enteredBackground() { isArmed = false }

    mutating func receive(_ offerID: UUID?, isForeground: Bool) -> UUID? {
        defer { observedOfferID = offerID }
        guard let offerID, offerID != observedOfferID, !seenOfferIDs.contains(offerID) else { return nil }
        seenOfferIDs.append(offerID)
        if seenOfferIDs.count > 32 { seenOfferIDs.removeFirst() }
        guard isForeground else { isArmed = false; return nil }
        guard isArmed else { return nil }
        isArmed = false
        return offerID
    }
}
