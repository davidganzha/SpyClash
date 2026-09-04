import Foundation
@preconcurrency import AVFoundation
import Observation
@preconcurrency import ARKit
@preconcurrency import MultipeerConnectivity
@preconcurrency import NearbyInteraction
import UIKit

enum RadarInvitePolicy: String, CaseIterable, Identifiable, Codable {
    case ask
    case automatic
    case blocked

    static let legacyStorageKey = "spyclash.radar.invite-policy"

    var id: String { rawValue }

    static let selectableCases: [RadarInvitePolicy] = [.ask, .automatic]

    var selectableValue: RadarInvitePolicy {
        self == .blocked ? .ask : self
    }

    static func stored(
        for userID: String,
        defaults: UserDefaults = .standard
    ) -> RadarInvitePolicy {
        let key = accountStorageKey(for: userID)
        if let rawValue = defaults.string(forKey: key) {
            let stored = (RadarInvitePolicy(rawValue: rawValue) ?? .ask).selectableValue
            defaults.set(stored.rawValue, forKey: key)
            return stored
        }

        // Migrate the one device-wide preference to the first account that
        // opens Radar after this update. Removing the legacy value prevents it
        // from leaking into another account on the same iPhone.
        let migrated = (
            defaults.string(forKey: legacyStorageKey)
                .flatMap(RadarInvitePolicy.init(rawValue:)) ?? .ask
        ).selectableValue
        defaults.set(migrated.rawValue, forKey: key)
        defaults.removeObject(forKey: legacyStorageKey)
        return migrated
    }

    func persist(
        for userID: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(rawValue, forKey: Self.accountStorageKey(for: userID))
    }

    private static func accountStorageKey(for userID: String) -> String {
        let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(legacyStorageKey).account.\(normalizedUserID)"
    }
}

enum RadarTransportSource: String, Equatable {
    case iphone
    case web
}

enum RadarPlayerAvailability: String, Equatable, Codable {
    case available
    case inGame = "in_game"
}

enum RadarOutgoingInvitationState: Equatable {
    case waiting
    case declined
    case accepted
    case inGame
    case blocked
    case unavailable
}

enum RadarPrecisionState: Equatable {
    case unsupported
    case available
    case measuring
    case unavailable
}

enum RadarDirectionGuidance: Equatable {
    case moveSideToSide
    case moveUpAndDown
    case keepMoving
    case improveLighting
    case moveCloser
}

enum RadarDirectionState: Equatable {
    case unsupported
    case waiting
    case calibrating(RadarDirectionGuidance)
    case tracking
    case unavailable
}

struct RadarRelativePosition: Equatable {
    /// Right (+) and left (-) in the ARKit world coordinate frame.
    let xMeters: Double
    /// Behind (+) and forward (-) in the ARKit world coordinate frame.
    let zMeters: Double
}

struct RadarNearbyPeer: Identifiable, Equatable {
    let id: String
    let spyID: String
    let spyCardTheme: SpyCardThemeID
    let spyCardAccent: SpyCardAccentID
    let spyCardBadge: SpyCardBadgeID
    let callSign: String
    let avatar: String
    let invitePolicy: RadarInvitePolicy
    let availability: RadarPlayerAvailability
    let source: RadarTransportSource
    let precisionState: RadarPrecisionState
    let directionState: RadarDirectionState
    let distanceMeters: Double?
    let horizontalAngleRadians: Double?
    let relativePosition: RadarRelativePosition?
}

struct RadarIncomingInvitation: Identifiable, Equatable {
    let id: UUID
    let wireInvitationID: String
    let sourcePeerID: String?
    let roomCode: String
    let hostCallSign: String
    let hostAvatar: String
    let hostSpyID: String
    let hostSpyCardTheme: SpyCardThemeID
    let hostSpyCardAccent: SpyCardAccentID
    let hostSpyCardBadge: SpyCardBadgeID
    let hostRating: Int
    let hostGamesPlayed: Int
    let hostWinRate: Int

    init(
        roomCode: String,
        hostCallSign: String,
        hostAvatar: String,
        hostSpyID: String = "000-000",
        hostSpyCardTheme: SpyCardThemeID = .field,
        hostSpyCardAccent: SpyCardAccentID = .signalRed,
        hostSpyCardBadge: SpyCardBadgeID = .operative,
        hostRating: Int = 0,
        hostGamesPlayed: Int = 0,
        hostWinRate: Int = 0,
        wireInvitationID: String = UUID().uuidString,
        sourcePeerID: String? = nil
    ) {
        self.id = UUID(uuidString: wireInvitationID) ?? UUID()
        self.wireInvitationID = wireInvitationID
        self.sourcePeerID = sourcePeerID
        self.roomCode = roomCode
        self.hostCallSign = PublicDisplayNameSafety.sanitizedForDisplay(
            hostCallSign,
            limit: 36
        )
        self.hostAvatar = hostAvatar
        self.hostSpyID = hostSpyID
        self.hostSpyCardTheme = hostSpyCardTheme
        self.hostSpyCardAccent = hostSpyCardAccent
        self.hostSpyCardBadge = hostSpyCardBadge
        self.hostRating = hostRating
        self.hostGamesPlayed = hostGamesPlayed
        self.hostWinRate = hostWinRate
    }
}

enum RadarScanState: Equatable {
    case idle
    case scanning
    case unavailable(String)
}

enum RadarRangefinderAccessState: Equatable {
    /// The current device cannot perform a supported permission probe. Radar's
    /// local directory remains available without precision ranging.
    case unsupported
    /// iOS exposes no standalone authorization status. A real nearby iPhone
    /// must supply its discovery token before SpyClash can verify access.
    case waitingForPeer
    /// A compatible physical peer is connected and automatic verification can
    /// begin.
    case ready
    case requesting
    case granted
    case denied
    case unavailable
}

enum RadarRangefinderAccessPolicy {
    static func initialState(
        canVerifyOnCurrentDevice: Bool
    ) -> RadarRangefinderAccessState {
        canVerifyOnCurrentDevice ? .waitingForPeer : .unsupported
    }

    static func stateAfterInvalidation(
        _ error: NSError,
        canVerifyOnCurrentDevice: Bool
    ) -> RadarRangefinderAccessState {
        guard canVerifyOnCurrentDevice else { return .unsupported }
        guard error.domain == NIErrorDomain else { return .unavailable }
        switch error.code {
        case NIError.Code.userDidNotAllow.rawValue:
            return .denied
        case NIError.Code.unsupportedPlatform.rawValue:
            return .unsupported
        default:
            return .unavailable
        }
    }

    static func stateAfterRangingInvalidation(
        _ error: NSError,
        currentState: RadarRangefinderAccessState,
        hasOtherActiveContext: Bool,
        canVerifyOnCurrentDevice: Bool
    ) -> RadarRangefinderAccessState {
        let mappedState = stateAfterInvalidation(
            error,
            canVerifyOnCurrentDevice: canVerifyOnCurrentDevice
        )
        switch mappedState {
        case .denied, .unsupported:
            // These are device-wide capability/authorization outcomes.
            return mappedState
        case .unavailable:
            // A transient failure belongs to this peer session. Do not turn a
            // previously proven grant, or another live ranging context, into a
            // global permission recovery screen.
            guard currentState != .granted,
                  !hasOtherActiveContext else { return currentState }
            return .unavailable
        case .waitingForPeer, .ready, .requesting, .granted:
            return mappedState
        }
    }

    static func stateAfterTransientPeerFailure(
        currentState: RadarRangefinderAccessState,
        hasOtherActiveContext: Bool
    ) -> RadarRangefinderAccessState {
        switch currentState {
        case .denied, .unsupported, .granted:
            return currentState
        case .waitingForPeer, .ready, .requesting, .unavailable:
            return hasOtherActiveContext ? currentState : .unavailable
        }
    }
}

enum RadarAutomaticRangefinderPolicy {
    static func shouldBeginProbe(
        from state: RadarRangefinderAccessState
    ) -> Bool {
        state == .waitingForPeer || state == .ready
    }
}

enum RadarTransportRetryPolicy {
    private static let retryDelaysMilliseconds = [1_000, 3_000, 8_000, 20_000]

    static func delayMilliseconds(afterFailureCount failureCount: Int) -> Int? {
        guard failureCount > 0,
              retryDelaysMilliseconds.indices.contains(failureCount - 1) else {
            return nil
        }
        return retryDelaysMilliseconds[failureCount - 1]
    }
}

enum RadarRangingTokenRetryPolicy {
    private static let retryDelaysMilliseconds = [750, 2_000]

    static func delayMilliseconds(afterFailureCount failureCount: Int) -> Int? {
        guard failureCount > 0,
              retryDelaysMilliseconds.indices.contains(failureCount - 1) else {
            return nil
        }
        return retryDelaysMilliseconds[failureCount - 1]
    }
}

enum RadarLegacyRangingRetryPolicy {
    private static let retryDelaysMilliseconds = [2_000, 5_000]

    static func delayMilliseconds(afterFailureCount failureCount: Int) -> Int? {
        guard failureCount > 0,
              retryDelaysMilliseconds.indices.contains(failureCount - 1) else {
            return nil
        }
        return retryDelaysMilliseconds[failureCount - 1]
    }

    static func allowsAttempt(afterFailureCount failureCount: Int) -> Bool {
        failureCount <= retryDelaysMilliseconds.count
    }
}

enum RadarPeerConnectionStrategy: Equatable {
    case presence
    case legacyRanging
}

enum RadarPeerProtocolPolicy {
    /// Continue advertising version 4 so build 132 can discover updated
    /// iPhones in either direction. Updated clients use the connected-ranging
    /// capability flag to distinguish one another while still accepting the
    /// transitional version-5 advertisement used by build 133.
    static let advertisedVersion = "4"
    static let acceptedVersions: Set<String> = ["4", "5"]

    static func connectionStrategy(
        peerVersion: String,
        supportsPrecision: Bool,
        supportsRangefinderProbe: Bool,
        supportsConnectedRanging: Bool
    ) -> RadarPeerConnectionStrategy {
        if peerVersion == "4",
           supportsPrecision,
           supportsRangefinderProbe,
           !supportsConnectedRanging {
            return .legacyRanging
        }
        return .presence
    }
}

enum RadarRangefinderProbeCollisionDecision: Equatable {
    case continueLocalProbe
    case yieldAndRespond
}

enum RadarRangefinderProbeCollisionPolicy {
    static func decision(
        localPeerID: String,
        localProbeID: String,
        incomingPeerID: String,
        incomingProbeID: String
    ) -> RadarRangefinderProbeCollisionDecision {
        let localProposal = "\(localPeerID)\u{0}\(localProbeID)"
        let incomingProposal = "\(incomingPeerID)\u{0}\(incomingProbeID)"
        return localProposal <= incomingProposal
            ? .continueLocalProbe
            : .yieldAndRespond
    }
}

enum RadarRangingExchangeCollisionPolicy {
    static func shouldAcceptIncoming(
        currentInitiatorPeerID: String,
        currentExchangeID: String,
        currentSupersedesExchangeID: String?,
        incomingInitiatorPeerID: String,
        incomingExchangeID: String,
        incomingSupersedesExchangeID: String?
    ) -> Bool {
        if incomingSupersedesExchangeID == currentExchangeID {
            return true
        }
        if currentSupersedesExchangeID == incomingExchangeID {
            return false
        }
        let currentProposal = "\(currentInitiatorPeerID)\u{0}\(currentExchangeID)"
        let incomingProposal = "\(incomingInitiatorPeerID)\u{0}\(incomingExchangeID)"
        return incomingProposal < currentProposal
    }
}

enum RadarRangefinderResumePolicy {
    static func canRun(
        wasSuspended: Bool,
        suspensionDidEnd: Bool,
        isApplicationActive: Bool
    ) -> Bool {
        wasSuspended && suspensionDidEnd && isApplicationActive
    }
}

enum RadarInviteDispatchResult: Equatable {
    case sent
    case cancelled
    case blocked
    case unavailable
}

enum RadarInvitationTapAction: Equatable {
    case send
    case cancel
    case none
}

enum RadarInvitationInteractionPolicy {
    static func action(
        invitePolicy: RadarInvitePolicy,
        availability: RadarPlayerAvailability,
        invitationState: RadarOutgoingInvitationState?
    ) -> RadarInvitationTapAction {
        guard invitePolicy != .blocked, availability == .available else { return .none }
        if invitationState == .waiting { return .cancel }
        guard invitationState == nil else { return .none }
        return .send
    }

    static func state(
        after availability: RadarPlayerAvailability,
        invitePolicy: RadarInvitePolicy,
        currentState: RadarOutgoingInvitationState?
    ) -> RadarOutgoingInvitationState? {
        if availability == .inGame {
            return .inGame
        }
        if invitePolicy == .blocked {
            return .blocked
        }
        return currentState == .accepted
            || currentState == .inGame
            || currentState == .blocked
            ? nil
            : currentState
    }

    static func state(
        after availability: RadarPlayerAvailability,
        currentState: RadarOutgoingInvitationState?
    ) -> RadarOutgoingInvitationState? {
        state(
            after: availability,
            invitePolicy: .ask,
            currentState: currentState
        )
    }
}

struct RadarPresenceSnapshot: Codable, Equatable {
    let availability: RadarPlayerAvailability
    let invitePolicy: RadarInvitePolicy
    let revision: UInt64?
}

enum RadarPresenceVersionPolicy {
    static func shouldApply(incoming: UInt64?, current: UInt64?) -> Bool {
        guard let current else { return true }
        guard let incoming else { return current == 0 }
        return incoming >= current
    }
}

enum RadarRoomInviteDeliveryPolicy {
    static func shouldQueueForActiveConnectionAttempt(
        hasRangingAttempt: Bool,
        hasPresenceAttempt: Bool,
        isConnecting: Bool
    ) -> Bool {
        hasRangingAttempt || hasPresenceAttempt || isConnecting
    }
}

enum RadarInvitationCancellationPolicy {
    static func matches(
        invitation: RadarIncomingInvitation?,
        invitationID: String,
        sourcePeerID: String
    ) -> Bool {
        invitation?.wireInvitationID == invitationID
            && invitation?.sourcePeerID == sourcePeerID
    }
}

private enum RadarWireKind: String, Codable {
    case rangingRequest = "ranging_request"
    case presenceSubscription = "presence_subscription"
    case nearbyToken = "nearby_token"
    case rangefinderProbeRequest = "rangefinder_probe_request"
    case rangefinderProbeToken = "rangefinder_probe_token"
    case rangefinderProbeComplete = "rangefinder_probe_complete"
    case roomInvite = "room_invite"
    case roomInviteResponse = "room_invite_response"
    case roomInviteCancel = "room_invite_cancel"
    case availabilityUpdate = "availability_update"
}

private enum RadarWireInviteResponse: String, Codable {
    case accepted
    case declined
    case inGame = "in_game"
    case blocked
}

private struct RadarReceivedRoomInviteKey: Hashable {
    let sourcePeerID: String
    let invitationID: String
}

private struct RadarRangingExchange: Equatable {
    let id: String
    let initiatorPeerID: String
    let supersedesExchangeID: String?
}

private struct RadarPendingRangingRecovery {
    let peerID: MCPeerID
    let preservedRemoteToken: NIDiscoveryToken?
    let preservedRemoteTokenData: Data?
    let supersedingExchangeID: String?
    let retryingExchange: RadarRangingExchange?
    let reason: String
}

private struct RadarPendingWireMessage {
    let message: RadarWireMessage
    let connectionEpoch: UInt64
    let receiveSequence: UInt64
}

private struct RadarReceiveCursor {
    let connectionEpoch: UInt64
    let receiveSequence: UInt64
}

private struct RadarConnectionDelivery {
    let connectionEpoch: UInt64
    let receiveSequence: UInt64
}

private final class RadarConnectionEpochTracker: @unchecked Sendable {
    private struct Key: Hashable {
        let sessionID: ObjectIdentifier
        let peerID: String
    }

    private let lock = NSLock()
    private var epochs: [Key: UInt64] = [:]
    private var receiveSequences: [Key: UInt64] = [:]

    func record(
        _ state: MCSessionState,
        for peerID: String,
        in session: MCSession
    ) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(sessionID: ObjectIdentifier(session), peerID: peerID)
        var epoch = epochs[key, default: 0]
        switch state {
        case .connected, .notConnected:
            epoch &+= 1
            receiveSequences[key] = 0
        case .connecting:
            break
        @unknown default:
            epoch &+= 1
            receiveSequences[key] = 0
        }
        epochs[key] = epoch
        return epoch
    }

    func recordReceive(for peerID: String, in session: MCSession) -> RadarConnectionDelivery {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(sessionID: ObjectIdentifier(session), peerID: peerID)
        let epoch = epochs[key, default: 0]
        let sequence = receiveSequences[key, default: 0] &+ 1
        receiveSequences[key] = sequence
        return RadarConnectionDelivery(
            connectionEpoch: epoch,
            receiveSequence: sequence
        )
    }

    func current(for peerID: String, in session: MCSession) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(sessionID: ObjectIdentifier(session), peerID: peerID)
        return epochs[key, default: 0]
    }
}

private enum RadarReceivedRoomInviteState {
    case pending
    case responded(RadarWireInviteResponse)
    case cancelled
}

private struct RadarWireMessage: Codable {
    let version: Int
    let kind: RadarWireKind
    let token: Data?
    let roomCode: String?
    let hostCallSign: String?
    let hostAvatar: String?
    let hostSpyID: String?
    let hostSpyCardTheme: String?
    let hostSpyCardAccent: String?
    let hostSpyCardBadge: String?
    let hostRating: Int?
    let hostGamesPlayed: Int?
    let hostWinRate: Int?
    let invitationID: String?
    let inviteResponse: RadarWireInviteResponse?
    let availability: String?
    let presence: RadarPresenceSnapshot?
    let rangingExchangeID: String?
    let rangingExchangeInitiatorPeerID: String?
    let supersedesRangingExchangeID: String?

    static var rangingRequest: RadarWireMessage {
        rangingRequest(exchange: nil)
    }

    static func rangingRequest(exchange: RadarRangingExchange?) -> RadarWireMessage {
        RadarWireMessage(
            version: 1,
            kind: .rangingRequest,
            token: nil,
            roomCode: nil,
            hostCallSign: nil,
            hostAvatar: nil,
            hostSpyID: nil,
            hostSpyCardTheme: nil,
            hostSpyCardAccent: nil,
            hostSpyCardBadge: nil,
            hostRating: nil,
            hostGamesPlayed: nil,
            hostWinRate: nil,
            invitationID: nil,
            inviteResponse: nil,
            availability: nil,
            presence: nil,
            rangingExchangeID: exchange?.id,
            rangingExchangeInitiatorPeerID: exchange?.initiatorPeerID,
            supersedesRangingExchangeID: exchange?.supersedesExchangeID
        )
    }

    static var presenceSubscription: RadarWireMessage {
        RadarWireMessage(
            version: 1,
            kind: .presenceSubscription,
            token: nil,
            roomCode: nil,
            hostCallSign: nil,
            hostAvatar: nil,
            hostSpyID: nil,
            hostSpyCardTheme: nil,
            hostSpyCardAccent: nil,
            hostSpyCardBadge: nil,
            hostRating: nil,
            hostGamesPlayed: nil,
            hostWinRate: nil,
            invitationID: nil,
            inviteResponse: nil,
            availability: nil,
            presence: nil,
            rangingExchangeID: nil,
            rangingExchangeInitiatorPeerID: nil,
            supersedesRangingExchangeID: nil
        )
    }

    static func nearbyToken(
        _ token: Data,
        exchange: RadarRangingExchange? = nil
    ) -> RadarWireMessage {
        RadarWireMessage(
            version: 1,
            kind: .nearbyToken,
            token: token,
            roomCode: nil,
            hostCallSign: nil,
            hostAvatar: nil,
            hostSpyID: nil,
            hostSpyCardTheme: nil,
            hostSpyCardAccent: nil,
            hostSpyCardBadge: nil,
            hostRating: nil,
            hostGamesPlayed: nil,
            hostWinRate: nil,
            invitationID: nil,
            inviteResponse: nil,
            availability: nil,
            presence: nil,
            rangingExchangeID: exchange?.id,
            rangingExchangeInitiatorPeerID: exchange?.initiatorPeerID,
            supersedesRangingExchangeID: exchange?.supersedesExchangeID
        )
    }

    static func rangefinderProbeRequest(id: String) -> RadarWireMessage {
        rangefinderProbeMessage(
            kind: .rangefinderProbeRequest,
            id: id,
            token: nil
        )
    }

    static func rangefinderProbeToken(id: String, token: Data) -> RadarWireMessage {
        rangefinderProbeMessage(
            kind: .rangefinderProbeToken,
            id: id,
            token: token
        )
    }

    static func rangefinderProbeComplete(id: String) -> RadarWireMessage {
        rangefinderProbeMessage(
            kind: .rangefinderProbeComplete,
            id: id,
            token: nil
        )
    }

    private static func rangefinderProbeMessage(
        kind: RadarWireKind,
        id: String,
        token: Data?
    ) -> RadarWireMessage {
        RadarWireMessage(
            version: 1,
            kind: kind,
            token: token,
            roomCode: nil,
            hostCallSign: nil,
            hostAvatar: nil,
            hostSpyID: nil,
            hostSpyCardTheme: nil,
            hostSpyCardAccent: nil,
            hostSpyCardBadge: nil,
            hostRating: nil,
            hostGamesPlayed: nil,
            hostWinRate: nil,
            invitationID: id,
            inviteResponse: nil,
            availability: nil,
            presence: nil,
            rangingExchangeID: nil,
            rangingExchangeInitiatorPeerID: nil,
            supersedesRangingExchangeID: nil
        )
    }

    static func roomInvite(
        invitationID: String,
        code: String,
        hostCallSign: String,
        hostAvatar: String,
        hostSpyID: String,
        hostSpyCardTheme: SpyCardThemeID,
        hostSpyCardAccent: SpyCardAccentID,
        hostSpyCardBadge: SpyCardBadgeID,
        hostRating: Int,
        hostGamesPlayed: Int,
        hostWinRate: Int
    ) -> RadarWireMessage {
        RadarWireMessage(
            version: 1,
            kind: .roomInvite,
            token: nil,
            roomCode: code,
            hostCallSign: hostCallSign,
            hostAvatar: hostAvatar,
            hostSpyID: hostSpyID,
            hostSpyCardTheme: hostSpyCardTheme.rawValue,
            hostSpyCardAccent: hostSpyCardAccent.rawValue,
            hostSpyCardBadge: hostSpyCardBadge.rawValue,
            hostRating: hostRating,
            hostGamesPlayed: hostGamesPlayed,
            hostWinRate: hostWinRate,
            invitationID: invitationID,
            inviteResponse: nil,
            availability: nil,
            presence: nil,
            rangingExchangeID: nil,
            rangingExchangeInitiatorPeerID: nil,
            supersedesRangingExchangeID: nil
        )
    }

    static func roomInviteResponse(
        invitationID: String,
        response: RadarWireInviteResponse
    ) -> RadarWireMessage {
        RadarWireMessage(
            version: 1,
            kind: .roomInviteResponse,
            token: nil,
            roomCode: nil,
            hostCallSign: nil,
            hostAvatar: nil,
            hostSpyID: nil,
            hostSpyCardTheme: nil,
            hostSpyCardAccent: nil,
            hostSpyCardBadge: nil,
            hostRating: nil,
            hostGamesPlayed: nil,
            hostWinRate: nil,
            invitationID: invitationID,
            inviteResponse: response,
            availability: nil,
            presence: nil,
            rangingExchangeID: nil,
            rangingExchangeInitiatorPeerID: nil,
            supersedesRangingExchangeID: nil
        )
    }

    static func roomInviteCancellation(invitationID: String) -> RadarWireMessage {
        RadarWireMessage(
            version: 1,
            kind: .roomInviteCancel,
            token: nil,
            roomCode: nil,
            hostCallSign: nil,
            hostAvatar: nil,
            hostSpyID: nil,
            hostSpyCardTheme: nil,
            hostSpyCardAccent: nil,
            hostSpyCardBadge: nil,
            hostRating: nil,
            hostGamesPlayed: nil,
            hostWinRate: nil,
            invitationID: invitationID,
            inviteResponse: nil,
            availability: nil,
            presence: nil,
            rangingExchangeID: nil,
            rangingExchangeInitiatorPeerID: nil,
            supersedesRangingExchangeID: nil
        )
    }

    static func presenceUpdate(_ presence: RadarPresenceSnapshot) -> RadarWireMessage {
        RadarWireMessage(
            version: 1,
            kind: .availabilityUpdate,
            token: nil,
            roomCode: nil,
            hostCallSign: nil,
            hostAvatar: nil,
            hostSpyID: nil,
            hostSpyCardTheme: nil,
            hostSpyCardAccent: nil,
            hostSpyCardBadge: nil,
            hostRating: nil,
            hostGamesPlayed: nil,
            hostWinRate: nil,
            invitationID: nil,
            inviteResponse: nil,
            availability: presence.availability.rawValue,
            presence: presence,
            rangingExchangeID: nil,
            rangingExchangeInitiatorPeerID: nil,
            supersedesRangingExchangeID: nil
        )
    }
}

enum RadarCameraAssistanceGate {
    static func canEnable(
        hasExplicitRadarIntent: Bool,
        wantsScanning: Bool,
        authorizationStatus: AVAuthorizationStatus,
        supportsCameraAssistance: Bool,
        supportsWorldTracking: Bool
    ) -> Bool {
        hasExplicitRadarIntent
            && wantsScanning
            && authorizationStatus == .authorized
            && supportsCameraAssistance
            && supportsWorldTracking
    }
}

@MainActor
@Observable
final class RadarNearbyService: NSObject {
    private static let serviceType = "spyclash-radar"
    // MCSession supports eight participants including the local device. Keep
    // one of the seven remote slots free for an explicit room invitation or
    // ranging request; additional Radar cards use versioned Bonjour snapshots.
    private static let maximumRemoteControlPeers = 6
    private static let maximumRemoteSessionPeers = 7
    private static let maximumRememberedRoomInvites = 64
    // Bump discovery independently from the wire-message version whenever the
    // Multipeer identity contract changes. This prevents cached Bonjour peers
    // from an older random-ID build appearing as duplicate live devices.
    private static let protocolVersion = RadarPeerProtocolPolicy.advertisedVersion
    private static let peerIDStorageKey = "spyclash.radar.multipeer-id"

    private static var canVerifyRangefinderAccess: Bool {
#if targetEnvironment(simulator)
        false
#else
        NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
#endif
    }

    private(set) var peers: [RadarNearbyPeer] = []
    private(set) var scanState: RadarScanState = .idle
    private(set) var incomingInvitation: RadarIncomingInvitation?
    private(set) var outgoingInvitationStates: [String: RadarOutgoingInvitationState] = [:]
    private(set) var supportsPreciseDistance: Bool
    private(set) var supportsDirectionMeasurement: Bool
    private(set) var supportsCameraAssistance: Bool
    private(set) var rangefinderAccessState: RadarRangefinderAccessState

    private(set) var invitePolicy: RadarInvitePolicy {
        didSet {
            guard oldValue != invitePolicy else { return }
            if let userID = identity?.userID {
                invitePolicy.persist(for: userID)
            }
            guard !isApplyingIdentityConfiguration else { return }
            advanceLocalPresenceRevision()
            publishLocalPresence()
        }
    }

    var onAutomaticInvitation: ((RadarIncomingInvitation) -> Void)?

    private var identity: RadarLocalIdentity?
    private var localAvailability: RadarPlayerAvailability = .available
    private var isApplicationActive = false
    private var allowsTransport = false
    private var wantsScanning = false
    private var wantsCameraAssistance = false
    private var cameraAuthorizationRequestID: UUID?
    private var localPeerID: MCPeerID?
    private var multipeerSession: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var discoveredPeerIDs: [String: MCPeerID] = [:]
    private var browsedPeerIDs: Set<String> = []
    private var connectingPeerIDs: Set<String> = []
    private var presenceControlPeerIDs: Set<String> = []
    private var presenceInviteAttempts: [String: UUID] = [:]
    private var presenceRetryCounts: [String: Int] = [:]
    private var peerPresenceRevisions: [String: UInt64] = [:]
    private var rangefinderProbeCapablePeerIDs: Set<String> = []
    private var connectedRangingCapablePeerIDs: Set<String> = []
    private var rangingControlPeerIDs: Set<String> = []
    /// Per-peer generations protect the async request send from reviving a
    /// connection that was stopped or replaced while `send` was suspended.
    private var connectedRangingRequestAttempts: [String: UUID] = [:]
    private var rangingTokenExchangeFailureCounts: [String: Int] = [:]
    private var rangingRecoveryFailureCounts: [String: Int] = [:]
    private var rangingExchanges: [String: RadarRangingExchange] = [:]
    private var retiredRangingExchangeIDs: [String: Set<String>] = [:]
    private var rangingRecoveryRunIDs: [String: UUID] = [:]
    @ObservationIgnored private var rangingRecoveryTasks: [String: Task<Void, Never>] = [:]
    private var pendingRangingRecoveries: [String: RadarPendingRangingRecovery] = [:]
    private var pendingRangingSessionStartPeerIDs: Set<String> = []
    private var pendingRangingContextRetryPeerIDs: Set<String> = []
    private var pendingConnectedRangingRequests: [String: [RadarPendingWireMessage]] = [:]
    private var pendingNearbyTokens: [String: [RadarPendingWireMessage]] = [:]
    private var pendingRangefinderProbeRequests: [String: [RadarPendingWireMessage]] = [:]
    private var pendingRangefinderProbeTokens: [String: [RadarPendingWireMessage]] = [:]
    private var pendingLegacyRangingPeerIDs: Set<String> = []
    private var terminalRangingFailurePeerIDs: Set<String> = []
    private var lastAppliedLegacyTokenCursors: [String: RadarReceiveCursor] = [:]
    private var pendingRangingConfigurationRefreshPeerIDs: Set<String> = []
    private var connectionEpochs: [String: UInt64] = [:]
    private var lastConnectedEpochs: [String: UInt64] = [:]
    nonisolated private let connectionEpochTracker = RadarConnectionEpochTracker()
    private var rangingInviteAttempts: [String: UUID] = [:]
    private var legacyRangingRetryCounts: [String: Int] = [:]
    private var legacyRangingRetryRunIDs: [String: UUID] = [:]
    private var roomInviteConnectionAttempts: [String: String] = [:]
    private var invitationTimeoutRunIDs: [String: UUID] = [:]
    private var receivedRoomInvites: [RadarReceivedRoomInviteKey: RadarReceivedRoomInviteState] = [:]
    private var receivedRoomInviteOrder: [RadarReceivedRoomInviteKey] = []
    private var pendingRoomInvites: [String: RadarWireMessage] = [:]
    private var pendingInvitationIDs: [String: String] = [:]
    private var rangingContexts: [String: RadarRangingContext] = [:]
    private var rangingPeerIDsBySession: [ObjectIdentifier: String] = [:]
    private var activeRangefinderProbe: RadarRangefinderProbeContext?
    private var rangefinderProbeIDsBySession: [ObjectIdentifier: String] = [:]
    private var rangefinderProbeResponders: [
        RadarRangefinderProbeKey: RadarRangefinderProbeResponder
    ] = [:]
    private var spatialARSession: ARSession?
    private var localPresenceRevision = RadarNearbyService.initialPresenceRevision()
    private var isApplyingIdentityConfiguration = false
    private var pendingLocalPresenceSnapshot: RadarPresenceSnapshot?
    @ObservationIgnored private var presencePublishTask: Task<Void, Never>?
    private var presencePublishRunID: UUID?
    @ObservationIgnored private var transportRetryTask: Task<Void, Never>?
    private var transportRetryRunID: UUID?
    @ObservationIgnored private var transportStabilityTask: Task<Void, Never>?
    private var consecutiveTransportFailureCount = 0
#if DEBUG
    private var usesPreviewRangingPeers = false
    private var previewScanFailureMessage: String?
    private var previewRangefinderAccessState: RadarRangefinderAccessState?
    private(set) var transportRebuildCountForTesting = 0
#endif

    var hasRecoverableRangingFailure: Bool {
        !terminalRangingFailurePeerIDs.isEmpty
    }

    override init() {
        invitePolicy = .ask
        supportsPreciseDistance = NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
        supportsDirectionMeasurement = NISession.deviceCapabilities.supportsDirectionMeasurement
        supportsCameraAssistance = NISession.deviceCapabilities.supportsCameraAssistance
        rangefinderAccessState = RadarRangefinderAccessPolicy.initialState(
            canVerifyOnCurrentDevice: Self.canVerifyRangefinderAccess
        )
        super.init()
        debugLog(
            "capabilities distance=\(supportsPreciseDistance) "
                + "direction=\(supportsDirectionMeasurement) "
                + "camera=\(supportsCameraAssistance) "
                + "region=\(Locale.current.region?.identifier ?? "nil") "
                + "timezone=\(TimeZone.current.identifier)"
        )
    }

    func configure(
        user: SpyUser?,
        applyRemoteInvitePolicy: Bool = true,
        allowsTransport: Bool = true
    ) {
        let nextIdentity = user.map {
            RadarLocalIdentity(
                userID: $0.id,
                spyID: Self.discoveryValue($0.spyID, fallback: "000-000", limit: 7),
                spyCardTheme: SpyCardThemeID(rawValue: $0.spyCardTheme ?? "") ?? .field,
                spyCardAccent: SpyCardAccentID(rawValue: $0.spyCardAccent ?? "") ?? .signalRed,
                spyCardBadge: SpyCardBadgeID(rawValue: $0.spyCardBadge ?? "") ?? .operative,
                callSign: PublicDisplayNameSafety.sanitizedForDisplay(
                    $0.callSign,
                    limit: 36
                ),
                avatar: Self.discoveryValue($0.avatar ?? "🕵️", fallback: "🕵️", limit: 12),
                rating: $0.rating ?? 0,
                gamesPlayed: max(0, $0.gamesPlayed ?? 0),
                winRate: Self.winRate(gamesPlayed: $0.gamesPlayed, gamesWon: $0.gamesWon)
            )
        }

        let remotePolicy = user.flatMap {
            RadarInvitePolicy(rawValue: $0.radarInvitePolicy ?? "")
        }?.selectableValue
        let nextPolicy: RadarInvitePolicy
        if let user {
            if applyRemoteInvitePolicy, let remotePolicy {
                nextPolicy = remotePolicy
            } else if identity?.userID == user.id {
                nextPolicy = invitePolicy
            } else {
                nextPolicy = RadarInvitePolicy.stored(for: user.id)
            }
        } else {
            nextPolicy = .ask
        }
        let identityChanged = nextIdentity != identity
        let accountChanged = nextIdentity?.userID != identity?.userID
        let policyChanged = nextPolicy != invitePolicy
        let transportAccessChanged = allowsTransport != self.allowsTransport
        guard identityChanged || policyChanged || transportAccessChanged else { return }

        self.allowsTransport = allowsTransport
        if identityChanged || transportAccessChanged {
            resetTransportRecoveryBudget()
        }

        if accountChanged {
            // Account changes invalidate every invitation tied to the previous
            // account. Ordinary avatar/rating refreshes must preserve them.
            incomingInvitation = nil
            outgoingInvitationStates.removeAll()
            pendingInvitationIDs.removeAll()
            pendingRoomInvites.removeAll()
            roomInviteConnectionAttempts.removeAll()
            invitationTimeoutRunIDs.removeAll()
            receivedRoomInvites.removeAll()
            receivedRoomInviteOrder.removeAll()
        }
        if identityChanged {
            identity = nextIdentity
            advanceLocalPresenceRevision()
        }
        if policyChanged {
            // The transport refresh below publishes identity and policy
            // together. Suppress the property observer's transport write so
            // onboarding can keep Bonjour completely dormant until consent.
            isApplyingIdentityConfiguration = true
            invitePolicy = nextPolicy
            isApplyingIdentityConfiguration = false
            if !identityChanged {
                advanceLocalPresenceRevision()
            }
            rejectIncomingInvitationForBlockedPolicyIfNeeded()
        }

        guard allowsTransport else {
            stopScanning()
            stopTransport(clearPeers: true)
            return
        }

        if transportAccessChanged || identityChanged || multipeerSession == nil || localPeerID == nil {
            rebuildTransportIfNeeded()
        } else if policyChanged {
            publishLocalPresence()
        } else {
            restartAdvertisingIfPossible()
        }
    }

    func setInvitePolicy(_ policy: RadarInvitePolicy) {
        invitePolicy = policy
        rejectIncomingInvitationForBlockedPolicyIfNeeded()
    }

    private func rejectIncomingInvitationForBlockedPolicyIfNeeded() {
        guard invitePolicy == .blocked, let invitation = incomingInvitation else { return }
        incomingInvitation = nil
        Task { @MainActor [weak self] in
            await self?.sendInviteResponse(.blocked, for: invitation)
        }
    }

    func setActiveRoom(_ room: GameRoom?) {
        let nextAvailability: RadarPlayerAvailability = room == nil ? .available : .inGame
        guard nextAvailability != localAvailability else { return }
        localAvailability = nextAvailability
        advanceLocalPresenceRevision()
        publishLocalPresence()
    }

    func setApplicationActive(
        _ isActive: Bool,
        stopTransportWhenInactive: Bool = true
    ) {
        let activityChanged = isApplicationActive != isActive
        guard activityChanged || (!isActive && stopTransportWhenInactive) else { return }
        isApplicationActive = isActive
        if activityChanged {
            debugLog("application active=\(isActive)")
        }
        refreshIdleTimerProtection()

        if isActive {
            if activityChanged {
                resetTransportRecoveryBudget()
            }
            supportsPreciseDistance = NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
            supportsDirectionMeasurement = NISession.deviceCapabilities.supportsDirectionMeasurement
            supportsCameraAssistance = NISession.deviceCapabilities.supportsCameraAssistance
            if !Self.canVerifyRangefinderAccess {
                rangefinderAccessState = .unsupported
            }
#if DEBUG
            if let previewRangefinderAccessState {
                rangefinderAccessState = previewRangefinderAccessState
            }
#endif
            if allowsTransport, wantsCameraAssistance {
                requestCameraAuthorizationForExplicitRadarUse()
            }
            if allowsTransport,
               advertiser == nil || multipeerSession == nil || localPeerID == nil {
                rebuildTransportIfNeeded()
            }
            if allowsTransport, wantsScanning {
                startBrowserIfPossible()
            }
#if DEBUG
            if let previewRangefinderAccessState {
                rangefinderAccessState = previewRangefinderAccessState
            }
#endif
            if let nearbySession = activeRangefinderProbe?.nearbySession {
                _ = resumeRangefinderProbeIfNeeded(nearbySession)
            }
            resumePendingRangingWork()
            reconcileRangefinderReadiness()
        } else if stopTransportWhenInactive {
            stopTransport(clearPeers: true)
        }
    }

    private func resumePendingRangingWork() {
        guard isApplicationActive, allowsTransport else { return }

        for context in Array(rangingContexts.values) {
            resumeRanging(for: context.nearbySession)
        }

        let configurationRefreshPeerIDs = pendingRangingConfigurationRefreshPeerIDs
        pendingRangingConfigurationRefreshPeerIDs.removeAll()
        for id in configurationRefreshPeerIDs {
            guard let context = rangingContexts[id],
                  let remoteToken = context.remoteToken,
                  multipeerSession?.connectedPeers.contains(context.peerID) == true else {
                continue
            }
            runRanging(
                context,
                with: remoteToken,
                tokenData: context.remoteTokenData
            )
        }

        let queuedMessagePeerIDs = Set(pendingConnectedRangingRequests.keys)
            .union(pendingNearbyTokens.keys)
            .union(pendingRangefinderProbeRequests.keys)
            .union(pendingRangefinderProbeTokens.keys)
        for id in queuedMessagePeerIDs {
            guard let peerID = multipeerSession?.connectedPeers.first(where: {
                $0.displayName == id
            }) else { continue }
            drainPendingRangingMessages(for: peerID)
        }
        if let activeRangefinderProbe,
           activeRangefinderProbe.nearbySession == nil {
            sendActiveRangefinderProbeRequest(activeRangefinderProbe)
        }

        let pendingSessionPeerIDs = pendingRangingSessionStartPeerIDs
        pendingRangingSessionStartPeerIDs.removeAll()
        for id in pendingSessionPeerIDs {
            guard let peerID = multipeerSession?.connectedPeers.first(where: {
                $0.displayName == id
            }) else { continue }
            if let context = rangingContexts[id] {
                resumeRanging(for: context.nearbySession)
            } else {
                let exchange = connectedRangingCapablePeerIDs.contains(id)
                    ? rangingExchanges[id]
                    : nil
                ensureRangingSession(for: peerID, exchange: exchange)
            }
        }

        let pendingContextPeerIDs = pendingRangingContextRetryPeerIDs
        pendingRangingContextRetryPeerIDs.removeAll()
        for id in pendingContextPeerIDs {
            guard let context = rangingContexts[id] else { continue }
            Task { @MainActor [weak self, weak context] in
                guard let self, let context else { return }
                await self.performRangingSynchronizationRetry(context, for: id)
            }
        }

        let recoveries = Array(pendingRangingRecoveries.values)
        pendingRangingRecoveries.removeAll()
        for recovery in recoveries {
            scheduleRangingRecovery(
                with: recovery.peerID,
                preservedRemoteToken: recovery.preservedRemoteToken,
                preservedRemoteTokenData: recovery.preservedRemoteTokenData,
                supersedingExchangeID: recovery.supersedingExchangeID,
                retryingExchange: recovery.retryingExchange,
                reason: recovery.reason
            )
        }

        let legacyPeerIDs = pendingLegacyRangingPeerIDs
        pendingLegacyRangingPeerIDs.removeAll()
        for id in legacyPeerIDs {
            guard let peerID = discoveredPeerIDs[id] else { continue }
            beginRangingHandshake(with: peerID)
        }
    }

    func startScanning(requestCameraAccess: Bool = false) {
        guard allowsTransport else {
            scanState = .idle
            return
        }
        if !Self.canVerifyRangefinderAccess {
            rangefinderAccessState = .unsupported
        }
#if DEBUG
        if let previewRangefinderAccessState {
            rangefinderAccessState = previewRangefinderAccessState
        }
#endif
        wantsScanning = true
        wantsCameraAssistance = requestCameraAccess
        if requestCameraAccess {
            requestCameraAuthorizationForExplicitRadarUse()
        }
        refreshIdleTimerProtection()
        debugLog(
            "scan requested active=\(isApplicationActive) identity=\(identity != nil) "
                + "rangefinder=\(String(describing: rangefinderAccessState))"
        )
        guard isApplicationActive, identity != nil else {
            scanState = .idle
            return
        }

        if advertiser == nil || multipeerSession == nil {
            rebuildTransportIfNeeded()
        }
        startBrowserIfPossible()
        reconcileRangefinderReadiness()
#if DEBUG
        if usesPreviewRangingPeers {
            applyPreviewRangingPeers()
        }
#endif
    }

    func retryScanning(requestCameraAccess: Bool = false) {
        // A failed MCNearbyServiceBrowser or advertiser is not guaranteed to
        // recover when startScanning() is called again. Tear down the complete
        // transport first so Retry always creates fresh Multipeer objects.
        debugLog("scan retry requested")
        resetTransportRecoveryBudget()
#if DEBUG
        previewScanFailureMessage = nil
#endif
        stopTransport(clearPeers: true)
        startScanning(requestCameraAccess: requestCameraAccess)
    }

    func retryRangefinderAccess() {
        guard Self.canVerifyRangefinderAccess else {
            rangefinderAccessState = .unsupported
            return
        }
        clearActiveRangefinderProbe(notifyPeer: true)
        rangefinderAccessState = .waitingForPeer
        retryScanning(requestCameraAccess: wantsCameraAssistance)
    }

    func stopScanning() {
        wantsScanning = false
        wantsCameraAssistance = false
        cameraAuthorizationRequestID = nil
        clearAllRangefinderProbeResources(notifyPeer: true)
        normalizeRangefinderStateAfterConnectionLoss()
        browser?.stopBrowsingForPeers()
        browser = nil
        multipeerSession?.disconnect()
        stopAllRanging()
        rangingInviteAttempts.removeAll()
        legacyRangingRetryCounts.removeAll()
        legacyRangingRetryRunIDs.removeAll()
        connectingPeerIDs.removeAll()
        pendingRoomInvites.removeAll()
        pendingInvitationIDs.removeAll()
        outgoingInvitationStates.removeAll()
        presencePublishTask?.cancel()
        presencePublishTask = nil
        presencePublishRunID = nil
        pendingLocalPresenceSnapshot = nil
        discoveredPeerIDs.removeAll()
        browsedPeerIDs.removeAll()
        presenceControlPeerIDs.removeAll()
        presenceInviteAttempts.removeAll()
        presenceRetryCounts.removeAll()
        peerPresenceRevisions.removeAll()
        rangefinderProbeCapablePeerIDs.removeAll()
        connectedRangingCapablePeerIDs.removeAll()
        rangingControlPeerIDs.removeAll()
        lastAppliedLegacyTokenCursors.removeAll()
        pendingRangingConfigurationRefreshPeerIDs.removeAll()
        clearAllRangingExchangeState()
        roomInviteConnectionAttempts.removeAll()
        invitationTimeoutRunIDs.removeAll()
        peers.removeAll()
        scanState = .idle
        stopSpatialARSession()
        refreshIdleTimerProtection()
    }

    private func requestCameraAuthorizationForExplicitRadarUse() {
        guard isApplicationActive,
              wantsScanning,
              wantsCameraAssistance,
              supportsCameraAssistance,
              ARWorldTrackingConfiguration.isSupported else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            refreshRangingConfigurationsForScanning()
        case .notDetermined:
            guard cameraAuthorizationRequestID == nil else { return }
            let requestID = UUID()
            cameraAuthorizationRequestID = requestID
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.cameraAuthorizationRequestID == requestID else { return }
                    self.cameraAuthorizationRequestID = nil
                    guard granted,
                          self.isApplicationActive,
                          self.wantsScanning,
                          self.wantsCameraAssistance else { return }
                    self.refreshRangingConfigurationsForScanning()
                }
            }
        case .denied, .restricted:
            stopSpatialARSession()
        @unknown default:
            stopSpatialARSession()
        }
    }

    func toggleInvitation(
        _ peer: RadarNearbyPeer,
        to room: GameRoom
    ) async -> RadarInviteDispatchResult {
        switch RadarInvitationInteractionPolicy.action(
            invitePolicy: peer.invitePolicy,
            availability: peer.availability,
            invitationState: outgoingInvitationStates[peer.id]
        ) {
        case .cancel:
            cancelInvitation(for: peer.id)
            return .cancelled
        case .send:
            return await invite(peer, to: room)
        case .none:
            return peer.availability == .inGame || peer.invitePolicy == .blocked
                ? .blocked
                : .unavailable
        }
    }

    private func invite(_ peer: RadarNearbyPeer, to room: GameRoom) async -> RadarInviteDispatchResult {
        guard peer.invitePolicy != .blocked else {
            return .blocked
        }
        guard peer.availability == .available else {
            outgoingInvitationStates[peer.id] = .inGame
            return .blocked
        }

        let invitationID = UUID().uuidString
        pendingInvitationIDs[peer.id] = invitationID
        outgoingInvitationStates[peer.id] = .waiting

#if DEBUG
        if usesPreviewRangingPeers {
            schedulePreviewResponse(for: peer.id, invitationID: invitationID)
            return .sent
        }
#endif

        guard let multipeerSession,
              let peerID = discoveredPeerIDs[peer.id],
              let identity else {
            markInvitationUnavailable(for: peer.id, invitationID: invitationID)
            return .unavailable
        }

        let message = RadarWireMessage.roomInvite(
            invitationID: invitationID,
            code: room.code.uppercased(),
            hostCallSign: identity.callSign,
            hostAvatar: identity.avatar,
            hostSpyID: identity.spyID,
            hostSpyCardTheme: identity.spyCardTheme,
            hostSpyCardAccent: identity.spyCardAccent,
            hostSpyCardBadge: identity.spyCardBadge,
            hostRating: identity.rating,
            hostGamesPlayed: identity.gamesPlayed,
            hostWinRate: identity.winRate
        )

        if multipeerSession.connectedPeers.contains(peerID) {
            let sent = await send(message, to: peerID)
            guard pendingInvitationIDs[peer.id] == invitationID else {
                return .cancelled
            }
            if sent {
                scheduleInvitationTimeout(for: peer.id, invitationID: invitationID)
                return .sent
            }
            markInvitationUnavailable(for: peer.id, invitationID: invitationID)
            return .unavailable
        }

        if roomInviteConnectionAttempts[peer.id] != nil
            || RadarRoomInviteDeliveryPolicy.shouldQueueForActiveConnectionAttempt(
                hasRangingAttempt: rangingInviteAttempts[peer.id] != nil,
                hasPresenceAttempt: presenceInviteAttempts[peer.id] != nil,
                isConnecting: connectingPeerIDs.contains(peer.id)
            ) {
            roomInviteConnectionAttempts[peer.id] = invitationID
            pendingRoomInvites[peer.id] = message
            scheduleInvitationTimeout(for: peer.id, invitationID: invitationID)
            return .sent
        }

        return beginDirectRoomInviteConnection(message, to: peerID)
            ? .sent
            : .unavailable
    }

    @discardableResult
    private func beginDirectRoomInviteConnection(
        _ message: RadarWireMessage,
        to peerID: MCPeerID
    ) -> Bool {
        let id = peerID.displayName
        guard let invitationID = message.invitationID,
              pendingInvitationIDs[id] == invitationID else { return false }

        pendingRoomInvites[id] = nil
        guard let browser,
              let multipeerSession,
              let context = encoded(message) else {
            markInvitationUnavailable(for: id, invitationID: invitationID)
            return false
        }

        if multipeerSession.connectedPeers.contains(peerID) {
            scheduleInvitationTimeout(for: id, invitationID: invitationID)
            Task { @MainActor [weak self] in
                guard let self,
                      self.pendingInvitationIDs[id] == invitationID else { return }
                if !(await self.send(message, to: peerID)) {
                    self.markInvitationUnavailable(for: id, invitationID: invitationID)
                }
            }
            return true
        }

        guard hasAvailableRemoteSessionSlot(for: id) else {
            debugLog("room invitation capacity reached peer=\(id)")
            markInvitationUnavailable(for: id, invitationID: invitationID)
            return false
        }
        roomInviteConnectionAttempts[id] = invitationID
        browser.invitePeer(
            peerID,
            to: multipeerSession,
            withContext: context,
            timeout: 15
        )
        scheduleInvitationTimeout(for: id, invitationID: invitationID)
        return true
    }

    private func cancelInvitation(for peerID: String) {
        guard let invitationID = pendingInvitationIDs.removeValue(forKey: peerID) else {
            if outgoingInvitationStates[peerID] == .waiting {
                outgoingInvitationStates[peerID] = nil
            }
            return
        }

        pendingRoomInvites[peerID] = nil
        invitationTimeoutRunIDs[peerID] = nil
        if roomInviteConnectionAttempts[peerID] == invitationID {
            roomInviteConnectionAttempts[peerID] = nil
        }
        outgoingInvitationStates[peerID] = nil

#if DEBUG
        if usesPreviewRangingPeers { return }
#endif

        guard let remotePeerID = discoveredPeerIDs[peerID] else {
            clearStaleConnectingStateIfNeeded(for: peerID)
            removePeerIfNoLongerReachable(peerID, ignoringStaleConnectingState: true)
            return
        }
        let cancellation = RadarWireMessage.roomInviteCancellation(
            invitationID: invitationID
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.deliverInvitationCancellation(
                cancellation,
                to: remotePeerID
            )
            // The fallback cancellation invitation has a five-second timeout.
            // If Bonjour was already lost and MCSession never reports a final
            // state, do not retain a ghost Radar card indefinitely.
            try? await Task.sleep(for: .seconds(6))
            self.clearStaleConnectingStateIfNeeded(for: peerID)
            if let pendingInvite = self.pendingRoomInvites[peerID],
               pendingInvite.invitationID == self.pendingInvitationIDs[peerID] {
                self.beginDirectRoomInviteConnection(
                    pendingInvite,
                    to: remotePeerID
                )
            }
            self.removePeerIfNoLongerReachable(
                peerID,
                ignoringStaleConnectingState: true
            )
        }
    }

    private func deliverInvitationCancellation(
        _ cancellation: RadarWireMessage,
        to remotePeerID: MCPeerID
    ) async {
        // A room invitation can already be accepted at the transport layer
        // while MCSession is still connecting. Keep cancellation local and
        // immediate, then retry delivery until that encrypted session becomes
        // writable. The browser context is the fallback when no session forms.
        for _ in 0..<14 {
            if await send(cancellation, to: remotePeerID) { return }
            try? await Task.sleep(for: .milliseconds(120))
        }

        guard let browser,
              let multipeerSession,
              let context = encoded(cancellation) else { return }
        browser.invitePeer(
            remotePeerID,
            to: multipeerSession,
            withContext: context,
            timeout: 5
        )
    }

    func invitationState(for peerID: String) -> RadarOutgoingInvitationState? {
        outgoingInvitationStates[peerID]
    }

    func presentForConfirmation(_ invitation: RadarIncomingInvitation) {
        guard canPresentIncomingInvitation(invitation) else { return }
        guard invitePolicy != .blocked else {
            Task { @MainActor [weak self] in
                await self?.sendInviteResponse(.blocked, for: invitation)
            }
            return
        }
        incomingInvitation = invitation
    }

    func isIncomingInvitationPending(_ invitation: RadarIncomingInvitation) -> Bool {
        canPresentIncomingInvitation(invitation)
    }

    func restoreIncomingInvitationIfVacant(_ invitation: RadarIncomingInvitation) {
        guard incomingInvitation == nil,
              canPresentIncomingInvitation(invitation) else { return }
        incomingInvitation = invitation
    }

    @discardableResult
    func acceptIncomingInvitation(_ invitation: RadarIncomingInvitation) async -> Bool {
        guard canPresentIncomingInvitation(invitation) else { return false }
        clearIncomingInvitationIfMatching(invitation)
        guard invitePolicy != .blocked else {
            await sendInviteResponse(.blocked, for: invitation)
            return false
        }
        await sendInviteResponse(.accepted, for: invitation)
        return true
    }

    @discardableResult
    func declineIncomingInvitation(_ invitation: RadarIncomingInvitation) -> Bool {
        guard canPresentIncomingInvitation(invitation) else { return false }
        clearIncomingInvitationIfMatching(invitation)
        Task { @MainActor [weak self] in
            await self?.sendInviteResponse(.declined, for: invitation)
        }
        return true
    }

#if DEBUG
    func installPreviewRangingPeers() {
        usesPreviewRangingPeers = true
        previewRangefinderAccessState = .granted
        rangefinderAccessState = .granted
        applyPreviewRangingPeers()
    }

    func installPreviewRangefinderAccessState(
        _ state: RadarRangefinderAccessState
    ) {
        previewRangefinderAccessState = state
        rangefinderAccessState = state
        debugLog("preview rangefinder state=\(String(describing: state))")
    }

    func installPreviewScanFailure(message: String = "Preview local search failure") {
        previewScanFailureMessage = message
        markTransportUnavailable(message)
    }

    private func applyPreviewRangingPeers() {
        supportsPreciseDistance = true
        supportsDirectionMeasurement = true
        supportsCameraAssistance = true
        if let previewScanFailureMessage {
            markTransportUnavailable(previewScanFailureMessage)
            return
        }
        scanState = .scanning
        peers = [
            RadarNearbyPeer(
                id: "preview-night-fox",
                spyID: "350-911",
                spyCardTheme: .dossier,
                spyCardAccent: .clearanceAmber,
                spyCardBadge: .ghost,
                callSign: "Night Fox",
                avatar: "🥷",
                invitePolicy: .ask,
                availability: .available,
                source: .iphone,
                precisionState: .measuring,
                directionState: .tracking,
                distanceMeters: 0.74,
                horizontalAngleRadians: -0.42,
                relativePosition: RadarRelativePosition(xMeters: -0.30, zMeters: -0.68)
            ),
            RadarNearbyPeer(
                id: "preview-red-raven",
                spyID: "104-827",
                spyCardTheme: .field,
                spyCardAccent: .verifiedGreen,
                spyCardBadge: .operative,
                callSign: "Red Raven",
                avatar: "🕵️",
                invitePolicy: .automatic,
                availability: .available,
                source: .iphone,
                precisionState: .measuring,
                directionState: .tracking,
                distanceMeters: 3.2,
                horizontalAngleRadians: 0.58,
                relativePosition: RadarRelativePosition(xMeters: 1.75, zMeters: -2.68)
            ),
            RadarNearbyPeer(
                id: "preview-ghost",
                spyID: "777-123",
                spyCardTheme: .blacksite,
                spyCardAccent: .signalRed,
                spyCardBadge: .handler,
                callSign: "Ghost",
                avatar: "👁️",
                invitePolicy: .blocked,
                availability: .available,
                source: .iphone,
                precisionState: .available,
                directionState: .calibrating(.moveSideToSide),
                distanceMeters: nil,
                horizontalAngleRadians: nil,
                relativePosition: nil
            ),
            RadarNearbyPeer(
                id: "preview-cipher",
                spyID: "214-908",
                spyCardTheme: .field,
                spyCardAccent: .verifiedGreen,
                spyCardBadge: .analyst,
                callSign: "Cipher",
                avatar: "🎭",
                invitePolicy: .ask,
                availability: .inGame,
                source: .iphone,
                precisionState: .available,
                directionState: .waiting,
                distanceMeters: nil,
                horizontalAngleRadians: nil,
                relativePosition: nil
            )
        ]
    }

    private func schedulePreviewResponse(for peerID: String, invitationID: String) {
        if ProcessInfo.processInfo.arguments.contains(
            "--spyclash-preview-radar-hold-pending"
        ) {
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_150))
            guard let self, self.pendingInvitationIDs[peerID] == invitationID else { return }

            if peerID == "preview-night-fox" {
                self.applyInviteResponse(.declined, from: peerID, invitationID: invitationID)
            } else {
                self.applyInviteResponse(.accepted, from: peerID, invitationID: invitationID)
            }
        }
    }
#endif

    private func rebuildTransportIfNeeded() {
        stopTransport(clearPeers: true)
        guard allowsTransport, isApplicationActive, let identity else { return }
#if DEBUG
        transportRebuildCountForTesting &+= 1
#endif

        let peerID = Self.persistentPeerID()
        debugLog("transport rebuilt localPeer=\(peerID.displayName)")
        let multipeerSession = MCSession(
            peer: peerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        multipeerSession.delegate = self

        localPeerID = peerID
        self.multipeerSession = multipeerSession
        restartAdvertisingIfPossible(identity: identity, peerID: peerID)

        if wantsScanning {
            startBrowserIfPossible()
        }
#if DEBUG
        if usesPreviewRangingPeers {
            applyPreviewRangingPeers()
        }
#endif
    }

    private func restartAdvertisingIfPossible() {
        guard allowsTransport,
              isApplicationActive,
              let identity,
              let localPeerID else {
            advertiser?.delegate = nil
            advertiser?.stopAdvertisingPeer()
            advertiser = nil
            return
        }
        restartAdvertisingIfPossible(identity: identity, peerID: localPeerID)
    }

    private func restartAdvertisingIfPossible(
        identity: RadarLocalIdentity,
        peerID: MCPeerID
    ) {
        guard allowsTransport else {
            advertiser?.delegate = nil
            advertiser?.stopAdvertisingPeer()
            advertiser = nil
            return
        }
        advertiser?.delegate = nil
        advertiser?.stopAdvertisingPeer()

        let advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: [
                "v": Self.protocolVersion,
                "spyid": identity.spyID,
                "theme": identity.spyCardTheme.rawValue,
                "accent": identity.spyCardAccent.rawValue,
                "badge": identity.spyCardBadge.rawValue,
                "name": identity.callSign,
                "avatar": identity.avatar,
                "policy": invitePolicy.rawValue,
                "availability": localAvailability.rawValue,
                "presence_rev": String(localPresenceRevision),
                "source": RadarTransportSource.iphone.rawValue,
                "precision": supportsPreciseDistance ? "1" : "0",
                "rangefinder_probe": Self.canVerifyRangefinderAccess ? "1" : "0",
                "connected_ranging": "1"
            ],
            serviceType: Self.serviceType
        )
        advertiser.delegate = self
        self.advertiser = advertiser
        advertiser.startAdvertisingPeer()
        scheduleTransportStabilityReset(for: advertiser)
    }

    private func startBrowserIfPossible() {
        guard allowsTransport else {
            scanState = .idle
            return
        }
        guard browser == nil, let localPeerID else {
            if browser != nil {
                scanState = .scanning
            }
            return
        }

        let browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: Self.serviceType)
        browser.delegate = self
        self.browser = browser
        scanState = .scanning
        browser.startBrowsingForPeers()
    }

    private func markTransportUnavailable(_ message: String) {
        let shouldReportFailure = wantsScanning
        consecutiveTransportFailureCount += 1
        debugLog("transport unavailable: \(message)")
        // Failed Multipeer objects are not restartable. Remove the complete
        // transport immediately so leaving and re-entering Radar cannot reuse
        // a broken advertiser, browser, or session.
        stopTransport(clearPeers: true)
        scanState = shouldReportFailure ? .unavailable(message) : .idle
        scheduleTransportRetryIfNeeded()
    }

    private func scheduleTransportRetryIfNeeded() {
        guard allowsTransport,
              isApplicationActive,
              identity != nil,
              let delay = RadarTransportRetryPolicy.delayMilliseconds(
                afterFailureCount: consecutiveTransportFailureCount
              ) else { return }

        let runID = UUID()
        transportRetryRunID = runID
        transportRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(delay))
            } catch {
                return
            }
            guard let self,
                  self.transportRetryRunID == runID,
                  self.allowsTransport,
                  self.isApplicationActive,
                  self.identity != nil,
                  self.advertiser == nil else { return }
            self.transportRetryTask = nil
            self.transportRetryRunID = nil
            self.debugLog(
                "transport automatic retry failure=\(self.consecutiveTransportFailureCount)"
            )
            self.rebuildTransportIfNeeded()
        }
    }

    private func scheduleTransportStabilityReset(
        for advertiser: MCNearbyServiceAdvertiser
    ) {
        transportStabilityTask?.cancel()
        transportStabilityTask = Task { @MainActor [weak self, weak advertiser] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard let self,
                  let advertiser,
                  self.advertiser === advertiser else { return }
            self.consecutiveTransportFailureCount = 0
            self.transportStabilityTask = nil
        }
    }

    private func resetTransportRecoveryBudget() {
        cancelTransportRecoveryTasks()
        consecutiveTransportFailureCount = 0
    }

    private func cancelTransportRecoveryTasks() {
        transportRetryTask?.cancel()
        transportRetryTask = nil
        transportRetryRunID = nil
        transportStabilityTask?.cancel()
        transportStabilityTask = nil
    }

    private func stopTransport(clearPeers: Bool) {
        cancelTransportRecoveryTasks()
        clearRangefinderProbeResponders()
        if activeRangefinderProbe != nil {
            clearActiveRangefinderProbe(notifyPeer: false)
        }
        // Transport shutdown (including an ordinary background transition)
        // is not a rangefinder failure. Put an interrupted automatic probe
        // back into the resumable state instead of requiring a manual retry.
        normalizeRangefinderStateAfterConnectionLoss()
        presencePublishTask?.cancel()
        presencePublishTask = nil
        presencePublishRunID = nil
        pendingLocalPresenceSnapshot = nil
        browser?.delegate = nil
        advertiser?.delegate = nil
        multipeerSession?.delegate = nil
        browser?.stopBrowsingForPeers()
        advertiser?.stopAdvertisingPeer()
        multipeerSession?.disconnect()
        stopAllRanging()
        browser = nil
        advertiser = nil
        multipeerSession = nil
        localPeerID = nil
        connectionEpochs.removeAll()
        lastConnectedEpochs.removeAll()
        lastAppliedLegacyTokenCursors.removeAll()
        pendingRangingConfigurationRefreshPeerIDs.removeAll()
        discoveredPeerIDs.removeAll()
        browsedPeerIDs.removeAll()
        connectingPeerIDs.removeAll()
        presenceControlPeerIDs.removeAll()
        presenceInviteAttempts.removeAll()
        presenceRetryCounts.removeAll()
        peerPresenceRevisions.removeAll()
        rangefinderProbeCapablePeerIDs.removeAll()
        connectedRangingCapablePeerIDs.removeAll()
        rangingControlPeerIDs.removeAll()
        clearAllRangingExchangeState()
        rangingInviteAttempts.removeAll()
        legacyRangingRetryCounts.removeAll()
        legacyRangingRetryRunIDs.removeAll()
        roomInviteConnectionAttempts.removeAll()
        invitationTimeoutRunIDs.removeAll()
        pendingRoomInvites.removeAll()
        pendingInvitationIDs.removeAll()
        outgoingInvitationStates.removeAll()
        if clearPeers {
            peers.removeAll()
        }
        if wantsScanning, isApplicationActive, identity != nil {
            scanState = .idle
        }
        refreshIdleTimerProtection()
    }

    private func recordFoundPeer(_ peerID: MCPeerID, discoveryInfo: [String: String]?) {
        guard allowsTransport else { return }
        guard let peerProtocolVersion = discoveryInfo?["v"],
              RadarPeerProtocolPolicy.acceptedVersions.contains(
                peerProtocolVersion
              ) else { return }

        let id = peerID.displayName
        debugLog("discovered peer=\(id)")
        let policy = RadarInvitePolicy(rawValue: discoveryInfo?["policy"] ?? "") ?? .ask
        let availability = RadarPlayerAvailability(
            rawValue: discoveryInfo?["availability"] ?? ""
        ) ?? .available
        let presenceRevision = discoveryInfo?["presence_rev"].flatMap(UInt64.init)
        let source = RadarTransportSource(rawValue: discoveryInfo?["source"] ?? "") ?? .iphone
        let peerSupportsPrecision = discoveryInfo?["precision"] == "1"
        let peerSupportsRangefinderProbe = discoveryInfo?["rangefinder_probe"] == "1"
        let peerSupportsConnectedRanging = discoveryInfo?["connected_ranging"] == "1"
        let connectionStrategy = RadarPeerProtocolPolicy.connectionStrategy(
            peerVersion: peerProtocolVersion,
            supportsPrecision: peerSupportsPrecision,
            supportsRangefinderProbe: peerSupportsRangefinderProbe,
            supportsConnectedRanging: peerSupportsConnectedRanging
        )
        let previous = peers.first(where: { $0.id == id })

        discoveredPeerIDs[id] = peerID
        browsedPeerIDs.insert(id)
        if peerSupportsPrecision, peerSupportsRangefinderProbe {
            rangefinderProbeCapablePeerIDs.insert(id)
        } else {
            rangefinderProbeCapablePeerIDs.remove(id)
        }
        if peerSupportsConnectedRanging {
            connectedRangingCapablePeerIDs.insert(id)
        } else {
            connectedRangingCapablePeerIDs.remove(id)
        }
        reconcileRangefinderReadiness()
        guard RadarPresenceVersionPolicy.shouldApply(
            incoming: presenceRevision,
            current: peerPresenceRevisions[id]
        ) else {
            debugLog("ignored stale discovery presence peer=\(id) revision=\(presenceRevision ?? 0)")
            beginControlConnection(with: peerID, strategy: connectionStrategy)
            return
        }
        let normalizedPresenceRevision = presenceRevision ?? 0
        if peerPresenceRevisions[id] != normalizedPresenceRevision {
            presenceRetryCounts[id] = 0
        }
        peerPresenceRevisions[id] = normalizedPresenceRevision

        let precisionState: RadarPrecisionState = if !peerSupportsPrecision {
            .unsupported
        } else if previous?.precisionState == .measuring {
            .measuring
        } else {
            .available
        }
        let peer = RadarNearbyPeer(
            id: id,
            spyID: Self.discoveryValue(discoveryInfo?["spyid"] ?? "", fallback: "000-000", limit: 7),
            spyCardTheme: SpyCardThemeID(rawValue: discoveryInfo?["theme"] ?? "") ?? .field,
            spyCardAccent: SpyCardAccentID(rawValue: discoveryInfo?["accent"] ?? "") ?? .signalRed,
            spyCardBadge: SpyCardBadgeID(rawValue: discoveryInfo?["badge"] ?? "") ?? .operative,
            callSign: PublicDisplayNameSafety.sanitizedForDisplay(
                discoveryInfo?["name"] ?? "",
                limit: 36
            ),
            avatar: Self.discoveryValue(discoveryInfo?["avatar"] ?? "", fallback: "🕵️", limit: 12),
            invitePolicy: policy,
            availability: availability,
            source: source,
            precisionState: precisionState,
            directionState: peerSupportsPrecision
                ? previous?.directionState ?? defaultDirectionState
                : .unsupported,
            distanceMeters: previous?.distanceMeters,
            horizontalAngleRadians: previous?.horizontalAngleRadians,
            relativePosition: previous?.relativePosition
        )

        if let index = peers.firstIndex(where: { $0.id == id }) {
            peers[index] = peer
        } else {
            peers.append(peer)
        }
        reconcileInvitationState(
            for: id,
            availability: availability,
            invitePolicy: policy
        )
        peers.sort { $0.callSign.localizedCaseInsensitiveCompare($1.callSign) == .orderedAscending }

        // The current Nearby UI is a local SpyID directory, not a position
        // scope. Discovery and invitations do not need an active UWB/ARKit
        // session, so merely finding a card must never start the camera or
        // consume precision-ranging resources.
        beginControlConnection(with: peerID, strategy: connectionStrategy)
    }

    private func beginControlConnection(
        with peerID: MCPeerID,
        strategy: RadarPeerConnectionStrategy
    ) {
        switch strategy {
        case .presence:
            beginPresenceSubscription(with: peerID)
        case .legacyRanging:
            beginRangingHandshake(with: peerID)
        }
    }

    private func removeLostPeer(_ peerID: MCPeerID) {
        let id = peerID.displayName
        browsedPeerIDs.remove(id)
        if multipeerSession?.connectedPeers.contains(peerID) == true
            || connectingPeerIDs.contains(id)
            || presenceInviteAttempts[id] != nil
            || rangingInviteAttempts[id] != nil
            || roomInviteConnectionAttempts[id] != nil {
            return
        }
        removeTerminalPeerState(id)
    }

    private func removeTerminalPeerState(_ id: String) {
        clearRangefinderProbeResponders(for: id)
        if let context = activeRangefinderProbe,
           context.peerID.displayName == id {
            finishActiveRangefinderProbe(with: .unavailable)
        }
        browsedPeerIDs.remove(id)
        discoveredPeerIDs[id] = nil
        connectingPeerIDs.remove(id)
        presenceControlPeerIDs.remove(id)
        presenceInviteAttempts[id] = nil
        presenceRetryCounts[id] = nil
        peerPresenceRevisions[id] = nil
        rangefinderProbeCapablePeerIDs.remove(id)
        connectedRangingCapablePeerIDs.remove(id)
        rangingControlPeerIDs.remove(id)
        lastAppliedLegacyTokenCursors[id] = nil
        pendingRangingConfigurationRefreshPeerIDs.remove(id)
        clearRangingExchangeState(for: id)
        rangingInviteAttempts[id] = nil
        legacyRangingRetryCounts[id] = nil
        legacyRangingRetryRunIDs[id] = nil
        roomInviteConnectionAttempts[id] = nil
        invitationTimeoutRunIDs[id] = nil
        pendingRoomInvites[id] = nil
        pendingInvitationIDs[id] = nil
        outgoingInvitationStates[id] = nil
        if incomingInvitation?.sourcePeerID == id {
            if let invitation = incomingInvitation {
                removePendingReceivedRoomInvite(for: invitation)
            }
            incomingInvitation = nil
        }
        stopRanging(with: id)
        peers.removeAll { $0.id == id }
        reconcileRangefinderReadiness()
    }

    @discardableResult
    private func removePeerIfNoLongerReachable(
        _ id: String,
        ignoringStaleConnectingState: Bool = false
    ) -> Bool {
        let isConnected = multipeerSession?.connectedPeers.contains {
            $0.displayName == id
        } == true
        guard !browsedPeerIDs.contains(id),
              !isConnected,
              presenceInviteAttempts[id] == nil,
              rangingInviteAttempts[id] == nil,
              roomInviteConnectionAttempts[id] == nil,
              (ignoringStaleConnectingState || !connectingPeerIDs.contains(id)) else {
            return false
        }
        removeTerminalPeerState(id)
        return true
    }

    private func clearStaleConnectingStateIfNeeded(for id: String) {
        let isConnected = multipeerSession?.connectedPeers.contains {
            $0.displayName == id
        } == true
        let hasDirectRoomAttempt = roomInviteConnectionAttempts[id] != nil
            && pendingRoomInvites[id] == nil
        guard !isConnected,
              presenceInviteAttempts[id] == nil,
              rangingInviteAttempts[id] == nil,
              !hasDirectRoomAttempt else { return }
        connectingPeerIDs.remove(id)
        refreshIdleTimerProtection()
    }

    private func beginPresenceSubscription(with peerID: MCPeerID) {
        let id = peerID.displayName
        guard wantsScanning,
              browsedPeerIDs.contains(id),
              let browser,
              let multipeerSession else { return }

        if multipeerSession.connectedPeers.contains(peerID) {
            presenceControlPeerIDs.insert(id)
            markRangefinderPeerReadyIfNeeded(peerID)
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.send(.presenceSubscription, to: peerID)
                _ = await self.send(
                    .presenceUpdate(self.localPresenceSnapshot),
                    to: peerID
                )
            }
            return
        }

        guard occupiedSessionPeerIDs.count < Self.maximumRemoteControlPeers else {
            debugLog("presence control capacity reached peer=\(id); using discovery fallback")
            return
        }

        guard !connectingPeerIDs.contains(id),
              presenceInviteAttempts[id] == nil,
              roomInviteConnectionAttempts[id] == nil,
              (presenceRetryCounts[id] ?? 0) < 3,
              let context = encoded(.presenceSubscription) else { return }

        let attemptID = UUID()
        presenceInviteAttempts[id] = attemptID
        presenceRetryCounts[id, default: 0] += 1
        debugLog("subscribing to presence peer=\(id) attempt=\(attemptID.uuidString.prefix(6))")
        browser.invitePeer(
            peerID,
            to: multipeerSession,
            withContext: context,
            timeout: 10
        )

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(11))
            guard let self,
                  self.presenceInviteAttempts[id] == attemptID else { return }
            if let session = self.multipeerSession,
               session.connectedPeers.contains(peerID) {
                self.handleSessionState(.connected, peerID: peerID, session: session)
                return
            }
            self.presenceInviteAttempts[id] = nil
            self.clearStaleConnectingStateIfNeeded(for: id)
            if !self.browsedPeerIDs.contains(id) {
                self.removeTerminalPeerState(id)
                return
            }
            if let pendingInvite = self.pendingRoomInvites[id] {
                self.beginDirectRoomInviteConnection(pendingInvite, to: peerID)
                return
            }
            self.schedulePresenceSubscriptionRetry(with: peerID)
        }
    }

    private var occupiedSessionPeerIDs: Set<String> {
        var peerIDs = Set(multipeerSession?.connectedPeers.map(\.displayName) ?? [])
        peerIDs.formUnion(connectingPeerIDs)
        peerIDs.formUnion(presenceInviteAttempts.keys)
        peerIDs.formUnion(rangingInviteAttempts.keys)
        peerIDs.formUnion(roomInviteConnectionAttempts.keys)
        return peerIDs
    }

    private func hasAvailableRemoteSessionSlot(for id: String) -> Bool {
        occupiedSessionPeerIDs.subtracting([id]).count
            < Self.maximumRemoteSessionPeers
    }

    private func schedulePresenceSubscriptionRetry(with peerID: MCPeerID) {
        let id = peerID.displayName
        guard wantsScanning,
              browsedPeerIDs.contains(id),
              presenceInviteAttempts[id] == nil else { return }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self,
                  self.wantsScanning,
                  self.browsedPeerIDs.contains(id),
                  self.discoveredPeerIDs[id]?.displayName == id,
                  !self.connectingPeerIDs.contains(id),
                  self.presenceInviteAttempts[id] == nil else { return }
            self.beginPresenceSubscription(with: peerID)
        }
    }

    private func beginRangingHandshake(with peerID: MCPeerID) {
        let id = peerID.displayName
        guard wantsScanning,
              allowsTransport,
              supportsPreciseDistance,
              rangefinderAccessState != .denied,
              rangefinderAccessState != .unsupported else {
            pendingLegacyRangingPeerIDs.remove(id)
            return
        }
        guard isApplicationActive else {
            pendingLegacyRangingPeerIDs.insert(id)
            return
        }
        pendingLegacyRangingPeerIDs.remove(id)
        guard
              RadarLegacyRangingRetryPolicy.allowsAttempt(
                afterFailureCount: legacyRangingRetryCounts[id, default: 0]
              ),
              legacyRangingRetryRunIDs[id] == nil,
              let browser,
              let multipeerSession,
              !multipeerSession.connectedPeers.contains(peerID),
              !connectingPeerIDs.contains(id),
              rangingInviteAttempts[id] == nil,
              roomInviteConnectionAttempts[id] == nil,
              hasAvailableRemoteSessionSlot(for: id),
              let context = encoded(.rangingRequest) else {
            debugLog("ranging handshake skipped peer=\(peerID.displayName) scanning=\(wantsScanning) localPrecision=\(supportsPreciseDistance)")
            return
        }

        let attemptID = UUID()
        debugLog("sending ranging invitation peer=\(id) attempt=\(attemptID.uuidString.prefix(6))")
        rangingInviteAttempts[id] = attemptID
        browser.invitePeer(peerID, to: multipeerSession, withContext: context, timeout: 15)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(16))
            guard let self,
                  self.rangingInviteAttempts[id] == attemptID else { return }
            if let session = self.multipeerSession,
               session.connectedPeers.contains(peerID) {
                self.handleSessionState(.connected, peerID: peerID, session: session)
                return
            }
            self.rangingInviteAttempts[id] = nil
            self.clearStaleConnectingStateIfNeeded(for: id)
            if !self.browsedPeerIDs.contains(id) {
                self.removeTerminalPeerState(id)
                return
            }
            if let pendingInvite = self.pendingRoomInvites[id] {
                self.beginDirectRoomInviteConnection(pendingInvite, to: peerID)
                return
            }
            self.scheduleRangingRetry(with: peerID)
        }
    }

    private func handleConnectionRequest(
        from peerID: MCPeerID,
        context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        guard let context,
              let message = try? JSONDecoder().decode(RadarWireMessage.self, from: context),
              message.version == 1 else {
            invitationHandler(false, nil)
            return
        }

        switch message.kind {
        case .presenceSubscription:
            let id = peerID.displayName
            guard let multipeerSession else {
                invitationHandler(false, nil)
                return
            }

            if multipeerSession.connectedPeers.contains(peerID) {
                presenceControlPeerIDs.insert(id)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.send(
                        .presenceUpdate(self.localPresenceSnapshot),
                        to: peerID
                    )
                }
                debugLog("rejected duplicate presence subscription peer=\(id) state=connected")
                invitationHandler(false, nil)
                return
            }

            let occupiedByOtherPeers = occupiedSessionPeerIDs.subtracting([id])
            let isSimultaneousPresenceAttempt = presenceInviteAttempts[id] != nil
            guard (!connectingPeerIDs.contains(id) || isSimultaneousPresenceAttempt),
                  rangingInviteAttempts[id] == nil,
                  roomInviteConnectionAttempts[id] == nil,
                  occupiedByOtherPeers.count < Self.maximumRemoteControlPeers else {
                debugLog("rejected presence subscription peer=\(id) state=busy-or-capacity")
                invitationHandler(false, nil)
                return
            }

            discoveredPeerIDs[id] = peerID
            presenceControlPeerIDs.insert(id)
            connectingPeerIDs.insert(id)
            refreshIdleTimerProtection()
            debugLog("accepted presence subscription peer=\(id)")
            invitationHandler(true, multipeerSession)

        case .rangingRequest:
            debugLog("received ranging invitation peer=\(peerID.displayName)")
            guard allowsTransport,
                  isApplicationActive,
                  supportsPreciseDistance,
                  rangefinderAccessState != .denied,
                  rangefinderAccessState != .unsupported,
                  let multipeerSession,
                  hasAvailableRemoteSessionSlot(for: peerID.displayName),
                  !connectingPeerIDs.contains(peerID.displayName),
                  !multipeerSession.connectedPeers.contains(peerID) else {
                debugLog("rejected ranging invitation peer=\(peerID.displayName) policy=\(invitePolicy.rawValue) precision=\(supportsPreciseDistance)")
                invitationHandler(false, nil)
                return
            }
            discoveredPeerIDs[peerID.displayName] = peerID
            rangingControlPeerIDs.insert(peerID.displayName)
            connectingPeerIDs.insert(peerID.displayName)
            refreshIdleTimerProtection()
            debugLog("accepted ranging invitation peer=\(peerID.displayName)")
            invitationHandler(true, multipeerSession)

        case .rangefinderProbeRequest,
             .rangefinderProbeToken,
             .rangefinderProbeComplete:
            // Probe messages are valid only inside an already authenticated,
            // encrypted MCSession established by presence discovery.
            invitationHandler(false, nil)

        case .roomInvite:
            guard let multipeerSession,
                  hasAvailableRemoteSessionSlot(for: peerID.displayName) else {
                invitationHandler(false, nil)
                return
            }
            discoveredPeerIDs[peerID.displayName] = peerID
            connectingPeerIDs.insert(peerID.displayName)
            invitationHandler(true, multipeerSession)
            handleRoomInvite(message, from: peerID)

        case .roomInviteCancel:
            handleRoomInviteCancellation(message, from: peerID)
            invitationHandler(false, nil)

        case .nearbyToken, .availabilityUpdate:
            invitationHandler(false, nil)

        case .roomInviteResponse:
            invitationHandler(false, nil)
        }
    }

    private func handleSessionState(
        _ state: MCSessionState,
        peerID: MCPeerID,
        session: MCSession,
        connectionEpoch: UInt64? = nil
    ) {
        guard multipeerSession === session else {
            debugLog("ignored stale multipeer state=\(state.rawValue) peer=\(peerID.displayName)")
            return
        }
        let id = peerID.displayName
        var reconnectsExistingSession = false
        if let connectionEpoch {
            let acceptedEpoch = connectionEpochs[id, default: 0]
            guard connectionEpoch >= acceptedEpoch else {
                debugLog("ignored stale multipeer epoch=\(connectionEpoch) peer=\(id)")
                return
            }
            reconnectsExistingSession = state == .connected
                && lastConnectedEpochs[id].map { connectionEpoch > $0 } == true
            connectionEpochs[id] = connectionEpoch
        }
        debugLog("multipeer state=\(state.rawValue) peer=\(id)")
        switch state {
        case .connected:
            if let connectionEpoch {
                lastConnectedEpochs[id] = connectionEpoch
            }
            if reconnectsExistingSession, let connectionEpoch {
                // A stale disconnect callback may arrive after this reconnect
                // and is intentionally rejected by the epoch guard above. Do
                // the connection-bound cleanup here as well so no NI token or
                // exchange from the previous transport generation survives.
                // Messages already delivered by this new epoch are retained
                // and drained after the replacement handshake is ready.
                clearRangefinderProbeResponders(for: id)
                if let context = activeRangefinderProbe,
                   context.peerID.displayName == id {
                    clearActiveRangefinderProbe(notifyPeer: false)
                    rangefinderAccessState = .waitingForPeer
                }
                stopRanging(with: id)
                clearRangingExchangeState(
                    for: id,
                    preservingPendingMessagesFor: connectionEpoch
                )
            }
            connectingPeerIDs.remove(id)
            let roomInvitationID = roomInviteConnectionAttempts.removeValue(forKey: id)
            let hadRangingInviteAttempt = rangingInviteAttempts.removeValue(forKey: id) != nil
            let hadPresenceInviteAttempt = presenceInviteAttempts.removeValue(forKey: id) != nil
            let isPresenceControl = presenceControlPeerIDs.contains(id)
                || hadPresenceInviteAttempt
            if isPresenceControl {
                presenceControlPeerIDs.insert(id)
                presenceRetryCounts[id] = 0
                markRangefinderPeerReadyIfNeeded(peerID)
            }
            if rangingControlPeerIDs.contains(id) || hadRangingInviteAttempt {
                rangingControlPeerIDs.insert(id)
                if hadRangingInviteAttempt {
                    legacyRangingRetryCounts[id] = 0
                    legacyRangingRetryRunIDs[id] = nil
                    terminalRangingFailurePeerIDs.remove(id)
                }
                ensureRangingSession(for: peerID)
            }
            drainPendingRangingMessages(for: peerID)
            let pendingInvite = pendingRoomInvites[id]
            if let invitationID = pendingInvite?.invitationID,
               pendingInvitationIDs[id] == invitationID {
                scheduleInvitationTimeout(for: id, invitationID: invitationID)
            } else if let roomInvitationID,
                      pendingInvitationIDs[id] == roomInvitationID {
                scheduleInvitationTimeout(for: id, invitationID: roomInvitationID)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.send(
                    .presenceUpdate(self.localPresenceSnapshot),
                    to: peerID
                )
                if let pendingInvite,
                   let invitationID = pendingInvite.invitationID,
                   self.pendingInvitationIDs[id] == invitationID,
                   self.pendingRoomInvites[id]?.invitationID == invitationID {
                    let sent = await self.send(pendingInvite, to: peerID)
                    guard self.pendingInvitationIDs[id] == invitationID,
                          self.pendingRoomInvites[id]?.invitationID == invitationID else {
                        return
                    }
                    if sent {
                        self.pendingRoomInvites[id] = nil
                    } else {
                        self.beginDirectRoomInviteConnection(
                            pendingInvite,
                            to: peerID
                        )
                    }
                }
            }

        case .notConnected:
            lastAppliedLegacyTokenCursors[id] = nil
            clearRangefinderProbeResponders(for: id)
            if let context = activeRangefinderProbe,
               context.peerID == peerID {
                clearActiveRangefinderProbe(notifyPeer: false)
                rangefinderAccessState = Self.canVerifyRangefinderAccess
                    ? .waitingForPeer
                    : .unsupported
            }
            connectingPeerIDs.remove(id)
            let roomInvitationID = roomInviteConnectionAttempts.removeValue(forKey: id)
            let hadRangingInviteAttempt = rangingInviteAttempts.removeValue(forKey: id) != nil
            let wasRangingControl = rangingControlPeerIDs.remove(id) != nil
                || hadRangingInviteAttempt
            clearRangingExchangeState(for: id)
            let hadPresenceInviteAttempt = presenceInviteAttempts.removeValue(forKey: id) != nil
            let wasPresenceControl = presenceControlPeerIDs.remove(id) != nil
                || hadPresenceInviteAttempt
            stopRanging(with: id)
            let pendingInvite = pendingRoomInvites.removeValue(forKey: id)
            if browsedPeerIDs.contains(id) {
                updatePrecision(for: id, state: defaultPrecisionState(for: id), distance: nil, angle: nil)
                if let pendingInvite {
                    beginDirectRoomInviteConnection(pendingInvite, to: peerID)
                } else if let roomInvitationID,
                          pendingInvitationIDs[id] == roomInvitationID {
                    markInvitationUnavailable(for: id, invitationID: roomInvitationID)
                } else if wasPresenceControl {
                    schedulePresenceSubscriptionRetry(with: peerID)
                } else if wasRangingControl {
                    scheduleRangingRetry(with: peerID)
                }
            } else {
                removeTerminalPeerState(id)
            }
            reconcileRangefinderReadiness()

        case .connecting:
            connectingPeerIDs.insert(id)

        @unknown default:
            lastAppliedLegacyTokenCursors[id] = nil
            clearRangefinderProbeResponders(for: id)
            if let context = activeRangefinderProbe,
               context.peerID == peerID {
                clearActiveRangefinderProbe(notifyPeer: false)
                rangefinderAccessState = Self.canVerifyRangefinderAccess
                    ? .waitingForPeer
                    : .unsupported
            }
            connectingPeerIDs.remove(id)
            presenceControlPeerIDs.remove(id)
            presenceInviteAttempts[id] = nil
            rangingControlPeerIDs.remove(id)
            clearRangingExchangeState(for: id)
            rangingInviteAttempts[id] = nil
            legacyRangingRetryCounts[id] = nil
            legacyRangingRetryRunIDs[id] = nil
            roomInviteConnectionAttempts[id] = nil
            stopRanging(with: id)
            reconcileRangefinderReadiness()
        }
        refreshIdleTimerProtection()
    }

    private func scheduleRangingRetry(with peerID: MCPeerID) {
        let id = peerID.displayName
        guard wantsScanning,
              allowsTransport,
              supportsPreciseDistance,
              rangefinderAccessState != .denied,
              rangefinderAccessState != .unsupported,
              browsedPeerIDs.contains(id),
              legacyRangingRetryRunIDs[id] == nil,
              rangingInviteAttempts[id] == nil,
              roomInviteConnectionAttempts[id] == nil else {
            return
        }
        guard isApplicationActive else {
            pendingLegacyRangingPeerIDs.insert(id)
            return
        }

        let failureCount = legacyRangingRetryCounts[id, default: 0] + 1
        legacyRangingRetryCounts[id] = failureCount
        guard let delay = RadarLegacyRangingRetryPolicy.delayMilliseconds(
            afterFailureCount: failureCount
        ) else {
            legacyRangingRetryRunIDs[id] = nil
            terminalRangingFailurePeerIDs.insert(id)
            updatePrecision(for: id, state: .unavailable, distance: nil, angle: nil)
            rangefinderAccessState = RadarRangefinderAccessPolicy
                .stateAfterTransientPeerFailure(
                    currentState: rangefinderAccessState,
                    hasOtherActiveContext: !rangingContexts.isEmpty
                )
            debugLog("legacy ranging retry exhausted peer=\(id)")
            return
        }
        let runID = UUID()
        legacyRangingRetryRunIDs[id] = runID
        Task { @MainActor [weak self] in
            // The receiver can report a failed handshake slightly later than
            // the browser side. Give both MCSession instances time to leave
            // `.connecting` before issuing another invitation.
            do {
                try await Task.sleep(for: .milliseconds(delay))
            } catch {
                return
            }
            guard let self,
                  self.legacyRangingRetryRunIDs[id] == runID,
                  self.legacyRangingRetryCounts[id] == failureCount else { return }
            self.legacyRangingRetryRunIDs[id] = nil
            guard self.wantsScanning,
                  self.allowsTransport,
                  self.supportsPreciseDistance,
                  self.rangefinderAccessState != .denied,
                  self.rangefinderAccessState != .unsupported,
                  self.browsedPeerIDs.contains(id),
                  self.discoveredPeerIDs[id]?.displayName == id,
                  !self.connectingPeerIDs.contains(id),
                  self.rangingInviteAttempts[id] == nil else { return }
            guard self.isApplicationActive else {
                self.pendingLegacyRangingPeerIDs.insert(id)
                return
            }
            self.debugLog("retrying ranging invitation peer=\(id)")
            self.beginRangingHandshake(with: peerID)
        }
    }

    private func ensureRangingSession(
        for peerID: MCPeerID,
        exchange: RadarRangingExchange? = nil,
        preservedRemoteToken: NIDiscoveryToken? = nil,
        preservedRemoteTokenData: Data? = nil
    ) {
        let id = peerID.displayName
        if let exchange,
           rangingExchanges[id] != exchange {
            debugLog("NI session skipped stale exchange peer=\(id) exchange=\(exchange.id.prefix(6))")
            return
        }
        if connectedRangingCapablePeerIDs.contains(id), exchange == nil {
            debugLog("NI session skipped missing connected exchange peer=\(id)")
            return
        }
        guard supportsPreciseDistance,
              rangefinderAccessState != .denied,
              rangefinderAccessState != .unsupported,
              allowsTransport,
              let multipeerSession,
              multipeerSession.connectedPeers.contains(peerID) else {
            pendingRangingSessionStartPeerIDs.remove(id)
            debugLog("NI session skipped peer=\(id) precision=\(supportsPreciseDistance) access=\(String(describing: rangefinderAccessState))")
            return
        }
        guard rangingContexts[id] == nil else {
            debugLog("NI session skipped peer=\(id) precision=\(supportsPreciseDistance) existing=\(rangingContexts[id] != nil)")
            return
        }
        guard isApplicationActive else {
            pendingRangingSessionStartPeerIDs.insert(id)
            debugLog("NI session deferred until foreground peer=\(id)")
            return
        }
        pendingRangingSessionStartPeerIDs.remove(id)

        let nearbySession = NISession()
        nearbySession.delegate = self
        nearbySession.delegateQueue = .main

        guard let localToken = nearbySession.discoveryToken,
              let archivedToken = try? NSKeyedArchiver.archivedData(
                withRootObject: localToken,
                requiringSecureCoding: true
              ) else {
            nearbySession.invalidate()
            debugLog("NI local token unavailable peer=\(id)")
            updatePrecision(for: id, state: .unavailable, distance: nil, angle: nil)
            scheduleRangingRecovery(
                with: peerID,
                preservedRemoteToken: preservedRemoteToken,
                preservedRemoteTokenData: preservedRemoteTokenData,
                retryingExchange: exchange,
                reason: "local-token-unavailable"
            )
            return
        }

        let rangingContext = RadarRangingContext(
            peerID: peerID,
            nearbySession: nearbySession,
            localTokenData: archivedToken,
            exchange: exchange
        )
        rangingContexts[id] = rangingContext
        rangingPeerIDsBySession[ObjectIdentifier(nearbySession)] = id
        refreshIdleTimerProtection()
        debugLog("NI session created peer=\(id); sending local token")
        updatePrecision(for: id, state: .available, distance: nil, angle: nil)
        if let preservedRemoteToken {
            runRanging(
                rangingContext,
                with: preservedRemoteToken,
                tokenData: preservedRemoteTokenData
            )
        } else {
            scheduleRangingTokenExchangeTimeout(rangingContext, for: id)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let sent = await self.send(
                .nearbyToken(archivedToken, exchange: exchange),
                to: peerID
            )
            self.debugLog("NI local token sent=\(sent) peer=\(id)")
            guard self.rangingContexts[id] === rangingContext else { return }
            if sent {
                rangingContext.localTokenDeliveryConfirmed = true
            }
            guard self.isApplicationActive else {
                if !sent {
                    self.pendingRangingContextRetryPeerIDs.insert(id)
                }
                return
            }
            if !sent {
                self.handleRangingTokenExchangeFailure(
                    rangingContext,
                    for: id,
                    reason: "local-token-send"
                )
            }
        }
    }

    private func sendRangingSynchronization(
        for context: RadarRangingContext,
        includeRequest: Bool
    ) async -> Bool {
        let id = context.peerID.displayName
        guard rangingContexts[id] === context,
              allowsTransport,
              isApplicationActive,
              rangefinderAccessState != .denied,
              rangefinderAccessState != .unsupported,
              multipeerSession?.connectedPeers.contains(context.peerID) == true else {
            return false
        }

        if includeRequest, let exchange = context.exchange {
            let requestSent = await send(
                .rangingRequest(exchange: exchange),
                to: context.peerID
            )
            guard rangingContexts[id] === context,
                  rangingExchanges[id] == exchange,
                  allowsTransport,
                  isApplicationActive,
                  multipeerSession?.connectedPeers.contains(context.peerID) == true,
                  requestSent else { return false }
        }

        let tokenSent = await send(
            .nearbyToken(
                context.localTokenData,
                exchange: context.exchange
            ),
            to: context.peerID
        )
        guard rangingContexts[id] === context,
              allowsTransport,
              isApplicationActive,
              multipeerSession?.connectedPeers.contains(context.peerID) == true else {
            return false
        }
        if tokenSent {
            context.localTokenDeliveryConfirmed = true
        }
        return tokenSent
    }

    private func scheduleRangingTokenExchangeTimeout(
        _ context: RadarRangingContext,
        for id: String
    ) {
        context.tokenExchangeTimeoutTask?.cancel()
        context.tokenExchangeTimeoutTask = Task { @MainActor [weak self, weak context] in
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            guard let self,
                  let context,
                  self.rangingContexts[id] === context,
                  context.remoteToken == nil else { return }
            self.handleRangingTokenExchangeFailure(
                context,
                for: id,
                reason: "remote-token-timeout"
            )
        }
    }

    private func handleRangingTokenExchangeFailure(
        _ context: RadarRangingContext,
        for id: String,
        reason: String
    ) {
        guard rangingContexts[id] === context else { return }
        let peerID = context.peerID
        debugLog("NI token exchange failed peer=\(id) reason=\(reason)")
        context.tokenExchangeTimeoutTask?.cancel()
        context.tokenExchangeTimeoutTask = nil
        context.tokenExchangeRetryTask?.cancel()
        context.tokenExchangeRetryTask = nil
        context.tokenExchangeRetryRunID = nil
        updatePrecision(for: id, state: .unavailable, distance: nil, angle: nil)

        guard rangefinderAccessState != .denied,
              rangefinderAccessState != .unsupported,
              allowsTransport,
              rangingControlPeerIDs.contains(id),
              multipeerSession?.connectedPeers.contains(peerID) == true else {
            pendingRangingContextRetryPeerIDs.remove(id)
            stopRanging(with: id)
            retireCurrentRangingExchange(for: id)
            rangefinderAccessState = RadarRangefinderAccessPolicy
                .stateAfterTransientPeerFailure(
                    currentState: rangefinderAccessState,
                    hasOtherActiveContext: !rangingContexts.isEmpty
                )
            return
        }
        guard isApplicationActive else {
            pendingRangingContextRetryPeerIDs.insert(id)
            debugLog("deferred NI token retry until foreground peer=\(id)")
            return
        }
        pendingRangingContextRetryPeerIDs.remove(id)

        let failureCount = rangingTokenExchangeFailureCounts[id, default: 0] + 1
        rangingTokenExchangeFailureCounts[id] = failureCount
        guard let delay = RadarRangingTokenRetryPolicy.delayMilliseconds(
            afterFailureCount: failureCount
        ) else {
            let failedExchangeID = context.exchange?.id
            let usesConnectedExchange = connectedRangingCapablePeerIDs.contains(id)
            let preservedRemoteToken = usesConnectedExchange ? nil : context.remoteToken
            let preservedRemoteTokenData = usesConnectedExchange
                ? nil
                : context.remoteTokenData
            stopRanging(with: id)
            retireCurrentRangingExchange(for: id)
            rangefinderAccessState = RadarRangefinderAccessPolicy
                .stateAfterTransientPeerFailure(
                    currentState: rangefinderAccessState,
                    hasOtherActiveContext: !rangingContexts.isEmpty
                )
            scheduleRangingRecovery(
                with: peerID,
                preservedRemoteToken: preservedRemoteToken,
                preservedRemoteTokenData: preservedRemoteTokenData,
                supersedingExchangeID: failedExchangeID,
                reason: "token-exchange-exhausted"
            )
            return
        }

        let retryRunID = UUID()
        context.tokenExchangeRetryRunID = retryRunID
        context.tokenExchangeRetryTask = Task { @MainActor [weak self, weak context] in
            do {
                try await Task.sleep(for: .milliseconds(delay))
            } catch {
                return
            }
            guard let self,
                  let context,
                  self.rangingContexts[id] === context,
                  context.tokenExchangeRetryRunID == retryRunID,
                  self.rangingTokenExchangeFailureCounts[id] == failureCount else { return }
            context.tokenExchangeRetryTask = nil
            context.tokenExchangeRetryRunID = nil
            await self.performRangingSynchronizationRetry(context, for: id)
        }
    }

    private func performRangingSynchronizationRetry(
        _ context: RadarRangingContext,
        for id: String
    ) async {
        guard rangingContexts[id] === context,
              allowsTransport,
              rangefinderAccessState != .denied,
              rangefinderAccessState != .unsupported,
              rangingControlPeerIDs.contains(id),
              multipeerSession?.connectedPeers.contains(context.peerID) == true else {
            return
        }
        guard isApplicationActive else {
            pendingRangingContextRetryPeerIDs.insert(id)
            return
        }
        pendingRangingContextRetryPeerIDs.remove(id)
        let sent = await sendRangingSynchronization(
            for: context,
            includeRequest: context.exchange != nil
        )
        guard rangingContexts[id] === context else { return }
        guard isApplicationActive else {
            pendingRangingContextRetryPeerIDs.insert(id)
            return
        }
        if sent {
            if context.remoteToken == nil {
                scheduleRangingTokenExchangeTimeout(context, for: id)
            }
        } else {
            handleRangingTokenExchangeFailure(
                context,
                for: id,
                reason: "synchronization-send"
            )
        }
    }

    private func handleReceivedData(
        _ data: Data,
        from peerID: MCPeerID,
        connectionEpoch: UInt64,
        receiveSequence: UInt64
    ) {
        let id = peerID.displayName
        guard allowsTransport,
              let multipeerSession,
              connectionEpoch == connectionEpochTracker.current(
                for: id,
                in: multipeerSession
              ),
              connectionEpoch >= connectionEpochs[id, default: 0],
              multipeerSession.connectedPeers.contains(peerID) else {
            debugLog("ignored stale multipeer data epoch=\(connectionEpoch) peer=\(id)")
            return
        }
        guard let message = try? JSONDecoder().decode(RadarWireMessage.self, from: data),
              message.version == 1 else {
            return
        }

        switch message.kind {
        case .presenceSubscription:
            presenceControlPeerIDs.insert(peerID.displayName)
            markRangefinderPeerReadyIfNeeded(peerID)
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.send(
                    .presenceUpdate(self.localPresenceSnapshot),
                    to: peerID
                )
            }
        case .nearbyToken:
            handleNearbyToken(
                message,
                from: peerID,
                connectionEpoch: connectionEpoch,
                receiveSequence: receiveSequence
            )
        case .rangefinderProbeRequest:
            guard isApplicationActive,
                  presenceControlPeerIDs.contains(id),
                  connectionEpoch == connectionEpochs[id] else {
                enqueuePendingRangefinderProbeRequest(
                    message,
                    for: id,
                    connectionEpoch: connectionEpoch,
                    receiveSequence: receiveSequence
                )
                return
            }
            handleRangefinderProbeRequest(message, from: peerID)
        case .rangefinderProbeToken:
            guard isApplicationActive,
                  connectionEpoch == connectionEpochs[id] else {
                enqueuePendingRangefinderProbeToken(
                    message,
                    for: id,
                    connectionEpoch: connectionEpoch,
                    receiveSequence: receiveSequence
                )
                return
            }
            handleRangefinderProbeToken(message, from: peerID)
        case .rangefinderProbeComplete:
            handleRangefinderProbeCompletion(message, from: peerID)
        case .roomInvite:
            handleRoomInvite(message, from: peerID)
        case .roomInviteResponse:
            guard let invitationID = message.invitationID,
                  let response = message.inviteResponse else { return }
            applyInviteResponse(response, from: peerID.displayName, invitationID: invitationID)
        case .roomInviteCancel:
            handleRoomInviteCancellation(message, from: peerID)
        case .availabilityUpdate:
            if let presence = message.presence {
                applyPresence(presence, for: peerID.displayName)
            } else if let rawAvailability = message.availability,
                      let availability = RadarPlayerAvailability(rawValue: rawAvailability) {
                applyLegacyAvailability(availability, for: peerID.displayName)
            }
        case .rangingRequest:
            guard isApplicationActive,
                  presenceControlPeerIDs.contains(id),
                  connectionEpoch == connectionEpochs[id],
                  multipeerSession.connectedPeers.contains(peerID) else {
                enqueuePendingConnectedRangingRequest(
                    message,
                    for: id,
                    connectionEpoch: connectionEpoch,
                    receiveSequence: receiveSequence
                )
                debugLog("deferred connected NI request peer=\(id)")
                return
            }
            handleConnectedRangingRequest(message, from: peerID)
        }
    }

    private func handleNearbyToken(
        _ message: RadarWireMessage,
        from peerID: MCPeerID,
        connectionEpoch: UInt64,
        receiveSequence: UInt64
    ) {
        let id = peerID.displayName
        guard message.token != nil else { return }
        guard rangefinderAccessState != .denied,
              rangefinderAccessState != .unsupported else {
            pendingNearbyTokens[id] = nil
            return
        }
        guard isApplicationActive,
              rangingControlPeerIDs.contains(id),
              connectionEpoch == connectionEpochs[id],
              multipeerSession?.connectedPeers.contains(peerID) == true else {
            enqueuePendingNearbyToken(
                message,
                for: id,
                connectionEpoch: connectionEpoch,
                receiveSequence: receiveSequence
            )
            debugLog("deferred NI token until connection is ready peer=\(id)")
            return
        }
        debugLog("received NI token peer=\(id)")
        guard let tokenData = message.token else { return }
        startRanging(
            with: tokenData,
            exchangeID: message.rangingExchangeID,
            exchangeInitiatorPeerID: message.rangingExchangeInitiatorPeerID,
            supersedesExchangeID: message.supersedesRangingExchangeID,
            connectionEpoch: connectionEpoch,
            receiveSequence: receiveSequence,
            from: peerID
        )
    }

    private func enqueuePendingConnectedRangingRequest(
        _ message: RadarWireMessage,
        for id: String,
        connectionEpoch: UInt64,
        receiveSequence: UInt64
    ) {
        pendingConnectedRangingRequests[id, default: []].append(
            RadarPendingWireMessage(
                message: message,
                connectionEpoch: connectionEpoch,
                receiveSequence: receiveSequence
            )
        )
        pendingConnectedRangingRequests[id]?.sort {
            $0.receiveSequence < $1.receiveSequence
        }
        if pendingConnectedRangingRequests[id, default: []].count > 8 {
            pendingConnectedRangingRequests[id]?.removeFirst()
        }
    }

    private func enqueuePendingNearbyToken(
        _ message: RadarWireMessage,
        for id: String,
        connectionEpoch: UInt64,
        receiveSequence: UInt64
    ) {
        pendingNearbyTokens[id, default: []].append(
            RadarPendingWireMessage(
                message: message,
                connectionEpoch: connectionEpoch,
                receiveSequence: receiveSequence
            )
        )
        pendingNearbyTokens[id]?.sort { $0.receiveSequence < $1.receiveSequence }
        if pendingNearbyTokens[id, default: []].count > 8 {
            pendingNearbyTokens[id]?.removeFirst()
        }
    }

    private func enqueuePendingRangefinderProbeRequest(
        _ message: RadarWireMessage,
        for id: String,
        connectionEpoch: UInt64,
        receiveSequence: UInt64
    ) {
        pendingRangefinderProbeRequests[id, default: []].append(
            RadarPendingWireMessage(
                message: message,
                connectionEpoch: connectionEpoch,
                receiveSequence: receiveSequence
            )
        )
        pendingRangefinderProbeRequests[id]?.sort {
            $0.receiveSequence < $1.receiveSequence
        }
        if pendingRangefinderProbeRequests[id, default: []].count > 8 {
            pendingRangefinderProbeRequests[id]?.removeFirst()
        }
    }

    private func enqueuePendingRangefinderProbeToken(
        _ message: RadarWireMessage,
        for id: String,
        connectionEpoch: UInt64,
        receiveSequence: UInt64
    ) {
        pendingRangefinderProbeTokens[id, default: []].append(
            RadarPendingWireMessage(
                message: message,
                connectionEpoch: connectionEpoch,
                receiveSequence: receiveSequence
            )
        )
        pendingRangefinderProbeTokens[id]?.sort {
            $0.receiveSequence < $1.receiveSequence
        }
        if pendingRangefinderProbeTokens[id, default: []].count > 8 {
            pendingRangefinderProbeTokens[id]?.removeFirst()
        }
    }

    private func drainPendingRangingMessages(for peerID: MCPeerID) {
        guard isApplicationActive,
              allowsTransport,
              multipeerSession?.connectedPeers.contains(peerID) == true else { return }
        let id = peerID.displayName
        guard let connectionEpoch = connectionEpochs[id] else { return }

        let probeRequests = (pendingRangefinderProbeRequests.removeValue(forKey: id) ?? [])
            .sorted { $0.receiveSequence < $1.receiveSequence }
        for pending in probeRequests where pending.connectionEpoch == connectionEpoch {
            guard presenceControlPeerIDs.contains(id) else { continue }
            handleRangefinderProbeRequest(pending.message, from: peerID)
        }
        let probeTokens = (pendingRangefinderProbeTokens.removeValue(forKey: id) ?? [])
            .sorted { $0.receiveSequence < $1.receiveSequence }
        for pending in probeTokens where pending.connectionEpoch == connectionEpoch {
            handleRangefinderProbeToken(pending.message, from: peerID)
        }

        let requests = (pendingConnectedRangingRequests.removeValue(forKey: id) ?? [])
            .sorted { $0.receiveSequence < $1.receiveSequence }
        for pending in requests where pending.connectionEpoch == connectionEpoch {
            guard presenceControlPeerIDs.contains(id) else {
                continue
            }
            handleConnectedRangingRequest(pending.message, from: peerID)
        }
        drainPendingNearbyTokens(for: peerID)
    }

    private func drainPendingNearbyTokens(for peerID: MCPeerID) {
        guard isApplicationActive,
              allowsTransport,
              rangingControlPeerIDs.contains(peerID.displayName),
              multipeerSession?.connectedPeers.contains(peerID) == true else { return }
        let id = peerID.displayName
        guard let connectionEpoch = connectionEpochs[id] else { return }
        let messages = (pendingNearbyTokens.removeValue(forKey: id) ?? [])
            .sorted { $0.receiveSequence < $1.receiveSequence }
        for pending in messages where pending.connectionEpoch == connectionEpoch {
            handleNearbyToken(
                pending.message,
                from: peerID,
                connectionEpoch: connectionEpoch,
                receiveSequence: pending.receiveSequence
            )
        }
    }

    private func connectedPrecisionPeer() -> MCPeerID? {
        multipeerSession?.connectedPeers.first {
            rangefinderProbeCapablePeerIDs.contains($0.displayName)
                && presenceControlPeerIDs.contains($0.displayName)
        }
    }

    private func markRangefinderPeerReadyIfNeeded(_ peerID: MCPeerID) {
        guard wantsScanning,
              allowsTransport,
              isApplicationActive,
              Self.canVerifyRangefinderAccess,
              connectedRangingCapablePeerIDs.contains(peerID.displayName),
              rangefinderProbeCapablePeerIDs.contains(peerID.displayName),
              presenceControlPeerIDs.contains(peerID.displayName),
              multipeerSession?.connectedPeers.contains(peerID) == true else {
            return
        }

        if rangefinderAccessState == .granted {
            Task { @MainActor [weak self] in
                await self?.beginConnectedRanging(with: peerID)
            }
            return
        }

        guard RadarAutomaticRangefinderPolicy.shouldBeginProbe(
            from: rangefinderAccessState
        ) else { return }
        rangefinderAccessState = .ready
        debugLog("rangefinder permission ready peer=\(peerID.displayName)")
        beginRangefinderProbe(with: peerID)
    }

    private func beginRangefinderProbe(with peerID: MCPeerID) {
        guard allowsTransport,
              isApplicationActive,
              wantsScanning else { return }
        guard activeRangefinderProbe == nil,
              rangefinderProbeCapablePeerIDs.contains(peerID.displayName),
              multipeerSession?.connectedPeers.contains(peerID) == true else {
            rangefinderAccessState = .waitingForPeer
            return
        }

        let context = RadarRangefinderProbeContext(
            id: UUID().uuidString,
            peerID: peerID
        )
        activeRangefinderProbe = context
        rangefinderAccessState = .requesting
        debugLog("rangefinder permission requested peer=\(peerID.displayName) probe=\(context.id.prefix(6))")

        sendActiveRangefinderProbeRequest(context)
    }

    private func scheduleRangefinderProbeRequestTimeout(
        _ context: RadarRangefinderProbeContext
    ) {
        context.timeoutTask?.cancel()
        context.timeoutTask = Task { @MainActor [weak self, weak context] in
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            guard let self,
                  let context,
                  self.activeRangefinderProbe === context else { return }
            guard self.isApplicationActive else {
                self.scheduleRangefinderProbeRequestTimeout(context)
                return
            }
            self.finishActiveRangefinderProbe(with: .unavailable)
        }
    }

    private func sendActiveRangefinderProbeRequest(
        _ context: RadarRangefinderProbeContext
    ) {
        guard activeRangefinderProbe === context,
              isApplicationActive,
              context.nearbySession == nil else { return }
        scheduleRangefinderProbeRequestTimeout(context)
        let attemptID = UUID()
        context.requestSendAttemptID = attemptID
        Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            let sent = await self.send(
                .rangefinderProbeRequest(id: context.id),
                to: context.peerID
            )
            guard self.activeRangefinderProbe === context,
                  context.requestSendAttemptID == attemptID,
                  context.nearbySession == nil else { return }
            context.requestSendAttemptID = nil
            guard self.isApplicationActive else { return }
            if !sent {
                self.finishActiveRangefinderProbe(with: .unavailable)
            }
        }
    }

    private func handleRangefinderProbeRequest(
        _ message: RadarWireMessage,
        from peerID: MCPeerID
    ) {
        guard Self.canVerifyRangefinderAccess,
              allowsTransport,
              isApplicationActive,
              presenceControlPeerIDs.contains(peerID.displayName),
              multipeerSession?.connectedPeers.contains(peerID) == true,
              let probeID = message.invitationID,
              !probeID.isEmpty else { return }

        // A passive advertiser may accept the presence session without ever
        // browsing the initiator's discovery metadata. Receiving the probe is
        // itself authenticated capability evidence for this connected peer.
        rangefinderProbeCapablePeerIDs.insert(peerID.displayName)

        if let activeRangefinderProbe,
           activeRangefinderProbe.peerID == peerID,
           let localPeerID {
            switch RadarRangefinderProbeCollisionPolicy.decision(
                localPeerID: localPeerID.displayName,
                localProbeID: activeRangefinderProbe.id,
                incomingPeerID: peerID.displayName,
                incomingProbeID: probeID
            ) {
            case .continueLocalProbe:
                debugLog(
                    "kept local rangefinder probe peer=\(peerID.displayName) "
                        + "probe=\(activeRangefinderProbe.id.prefix(6))"
                )
                return
            case .yieldAndRespond:
                debugLog(
                    "yielded rangefinder probe peer=\(peerID.displayName) "
                        + "probe=\(activeRangefinderProbe.id.prefix(6))"
                )
                clearActiveRangefinderProbe(notifyPeer: true)
                rangefinderAccessState = .requesting
            }
        }

        let key = RadarRangefinderProbeKey(
            peerID: peerID.displayName,
            probeID: probeID
        )
        if let existing = rangefinderProbeResponders[key] {
            scheduleRangefinderResponderTimeout(existing, for: key)
            Task { @MainActor [weak self] in
                _ = await self?.send(
                    .rangefinderProbeToken(id: probeID, token: existing.tokenData),
                    to: peerID
                )
            }
            return
        }

        clearRangefinderProbeResponders(for: peerID.displayName)
        let nearbySession = NISession()
        guard let token = nearbySession.discoveryToken,
              let tokenData = try? NSKeyedArchiver.archivedData(
                withRootObject: token,
                requiringSecureCoding: true
              ) else {
            nearbySession.invalidate()
            return
        }

        let responder = RadarRangefinderProbeResponder(
            peerID: peerID,
            nearbySession: nearbySession,
            tokenData: tokenData
        )
        rangefinderProbeResponders[key] = responder
        scheduleRangefinderResponderTimeout(responder, for: key)

        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.send(
                .rangefinderProbeToken(id: probeID, token: tokenData),
                to: peerID
            )
        }
    }

    private func handleRangefinderProbeToken(
        _ message: RadarWireMessage,
        from peerID: MCPeerID
    ) {
        guard Self.canVerifyRangefinderAccess,
              allowsTransport,
              isApplicationActive,
              wantsScanning,
              rangefinderProbeCapablePeerIDs.contains(peerID.displayName),
              presenceControlPeerIDs.contains(peerID.displayName),
              multipeerSession?.connectedPeers.contains(peerID) == true,
              let context = activeRangefinderProbe,
              context.peerID == peerID,
              context.id == message.invitationID,
              context.nearbySession == nil,
              let tokenData = message.token,
              let peerToken = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NIDiscoveryToken.self,
                from: tokenData
              ) else { return }

        let nearbySession = NISession()
        nearbySession.delegate = self
        nearbySession.delegateQueue = .main
        context.timeoutTask?.cancel()
        context.timeoutTask = nil
        context.requestSendAttemptID = nil
        context.nearbySession = nearbySession
        context.peerToken = peerToken
        rangefinderProbeIDsBySession[ObjectIdentifier(nearbySession)] = context.id
        scheduleActiveRangefinderResolutionTimeout(context)

        let configuration = NINearbyPeerConfiguration(peerToken: peerToken)
        configuration.isExtendedDistanceMeasurementEnabled = false
        nearbySession.run(configuration)
        debugLog("rangefinder permission run peer=\(peerID.displayName) probe=\(context.id.prefix(6))")
    }

    private func handleRangefinderProbeCompletion(
        _ message: RadarWireMessage,
        from peerID: MCPeerID
    ) {
        guard let probeID = message.invitationID else { return }
        let key = RadarRangefinderProbeKey(
            peerID: peerID.displayName,
            probeID: probeID
        )
        let wasResponding = rangefinderProbeResponders[key] != nil
        clearRangefinderProbeResponder(for: key)
        if wasResponding,
           rangefinderAccessState == .requesting,
           activeRangefinderProbe == nil,
           rangingContexts[peerID.displayName] == nil {
            rangefinderAccessState = wantsScanning ? .ready : .waitingForPeer
        }
    }

    private func finishActiveRangefinderProbe(
        with state: RadarRangefinderAccessState
    ) {
        guard let context = activeRangefinderProbe else { return }
        let peerID = context.peerID
        let probeID = context.id
        clearActiveRangefinderProbe(notifyPeer: false)
        rangefinderAccessState = state
        debugLog("rangefinder permission resolved state=\(String(describing: state))")
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.send(
                .rangefinderProbeComplete(id: probeID),
                to: peerID
            )
            guard state == .granted else { return }
            self.beginConnectedRangingForEligiblePeers()
        }
    }

    private func beginConnectedRangingForEligiblePeers() {
        guard allowsTransport,
              isApplicationActive,
              rangefinderAccessState == .granted else { return }
        let eligiblePeers = multipeerSession?.connectedPeers.filter {
            connectedRangingCapablePeerIDs.contains($0.displayName)
                && rangefinderProbeCapablePeerIDs.contains($0.displayName)
                && presenceControlPeerIDs.contains($0.displayName)
        } ?? []
        guard !eligiblePeers.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for peerID in eligiblePeers {
                guard self.allowsTransport,
                      self.isApplicationActive,
                      self.rangefinderAccessState == .granted else { return }
                await self.beginConnectedRanging(with: peerID)
            }
        }
    }

    private func beginConnectedRanging(with peerID: MCPeerID) async {
        let id = peerID.displayName
        guard allowsTransport,
              isApplicationActive,
              supportsPreciseDistance,
              rangefinderAccessState == .granted,
              rangefinderProbeCapablePeerIDs.contains(id),
              presenceControlPeerIDs.contains(id),
              multipeerSession?.connectedPeers.contains(peerID) == true else {
            return
        }
        guard !terminalRangingFailurePeerIDs.contains(id),
              rangingRecoveryTasks[id] == nil,
              pendingRangingRecoveries[id] == nil else { return }

        if rangingContexts[id] != nil || connectedRangingRequestAttempts[id] != nil {
            return
        }

        rangingControlPeerIDs.insert(id)
        drainPendingNearbyTokens(for: peerID)
        await initiateNewConnectedRangingExchange(
            with: peerID,
            reason: "permission-granted"
        )
    }

    private func initiateNewConnectedRangingExchange(
        with peerID: MCPeerID,
        reason: String,
        supersedingExchangeID: String? = nil
    ) async {
        let id = peerID.displayName
        guard allowsTransport,
              isApplicationActive,
              supportsPreciseDistance,
              rangefinderAccessState != .denied,
              rangefinderAccessState != .unsupported,
              connectedRangingCapablePeerIDs.contains(id),
              rangingControlPeerIDs.contains(id),
              connectedRangingRequestAttempts[id] == nil,
              multipeerSession?.connectedPeers.contains(peerID) == true,
              let localPeerID else { return }

        let exchange = RadarRangingExchange(
            id: UUID().uuidString,
            initiatorPeerID: localPeerID.displayName,
            supersedesExchangeID: supersedingExchangeID ?? rangingExchanges[id]?.id
        )
        adoptRangingExchange(exchange, for: id)
        await sendConnectedRangingRequest(
            exchange,
            to: peerID,
            reason: reason
        )
    }

    private func sendConnectedRangingRequest(
        _ exchange: RadarRangingExchange,
        to peerID: MCPeerID,
        reason: String
    ) async {
        let id = peerID.displayName
        guard allowsTransport,
              isApplicationActive,
              rangefinderAccessState != .denied,
              rangefinderAccessState != .unsupported,
              rangingControlPeerIDs.contains(id),
              rangingExchanges[id] == exchange,
              connectedRangingRequestAttempts[id] == nil,
              multipeerSession?.connectedPeers.contains(peerID) == true else { return }

        let attemptID = UUID()
        connectedRangingRequestAttempts[id] = attemptID
        debugLog(
            "starting connected NI exchange peer=\(id) exchange=\(exchange.id.prefix(6)) reason=\(reason)"
        )
        let sent = await send(
            .rangingRequest(exchange: exchange),
            to: peerID
        )
        guard connectedRangingRequestAttempts[id] == attemptID,
              rangingExchanges[id] == exchange else {
            // A disconnect, stop, or newer attempt superseded this suspended
            // send. Its completion must not mutate the current transport.
            return
        }
        connectedRangingRequestAttempts[id] = nil
        guard allowsTransport,
              rangefinderAccessState != .denied,
              rangefinderAccessState != .unsupported,
              rangingControlPeerIDs.contains(id),
              multipeerSession?.connectedPeers.contains(peerID) == true else {
            return
        }
        guard isApplicationActive else {
            if sent {
                pendingRangingSessionStartPeerIDs.insert(id)
            } else {
                scheduleRangingRecovery(
                    with: peerID,
                    preservedRemoteToken: nil,
                    retryingExchange: exchange,
                    reason: "connected-request-send"
                )
            }
            return
        }
        guard sent else {
            updatePrecision(for: id, state: .unavailable, distance: nil, angle: nil)
            rangefinderAccessState = RadarRangefinderAccessPolicy
                .stateAfterTransientPeerFailure(
                    currentState: rangefinderAccessState,
                    hasOtherActiveContext: !rangingContexts.isEmpty
                )
            scheduleRangingRecovery(
                with: peerID,
                preservedRemoteToken: nil,
                retryingExchange: exchange,
                reason: "connected-request-send"
            )
            return
        }
        ensureRangingSession(for: peerID, exchange: exchange)
    }

    private func handleConnectedRangingRequest(
        _ message: RadarWireMessage,
        from peerID: MCPeerID
    ) {
        let id = peerID.displayName
        guard allowsTransport,
              isApplicationActive,
              supportsPreciseDistance,
              rangefinderAccessState != .denied,
              rangefinderAccessState != .unsupported,
              presenceControlPeerIDs.contains(id),
              multipeerSession?.connectedPeers.contains(peerID) == true,
              let exchangeID = message.rangingExchangeID,
              !exchangeID.isEmpty,
              let exchangeInitiatorPeerID = message.rangingExchangeInitiatorPeerID,
              !exchangeInitiatorPeerID.isEmpty,
              exchangeInitiatorPeerID == id
                || exchangeInitiatorPeerID == localPeerID?.displayName,
              message.supersedesRangingExchangeID != exchangeID else {
            debugLog("ignored connected ranging request peer=\(id)")
            return
        }
        // A passive foreground advertiser may never browse the initiator's
        // discovery metadata. The authenticated wire request itself proves the
        // connected peer speaks the rangefinder protocol.
        rangefinderProbeCapablePeerIDs.insert(id)
        connectedRangingCapablePeerIDs.insert(id)
        if activeRangefinderProbe?.peerID == peerID {
            // The remote peer has already proven access and moved straight to
            // real ranging. Supersede our permission-only probe so this device
            // never runs two NI sessions for the same peer concurrently.
            clearActiveRangefinderProbe(notifyPeer: true)
        }
        clearRangefinderProbeResponders(for: id)
        rangingControlPeerIDs.insert(id)

        let incomingExchange = RadarRangingExchange(
            id: exchangeID,
            initiatorPeerID: exchangeInitiatorPeerID,
            supersedesExchangeID: message.supersedesRangingExchangeID
        )
        if retiredRangingExchangeIDs[id]?.contains(exchangeID) == true {
            debugLog("ignored retired NI exchange peer=\(id) exchange=\(exchangeID.prefix(6))")
            synchronizeCurrentRangingExchange(with: peerID, includeRequest: true)
            return
        }

        if rangefinderAccessState != .granted {
            rangefinderAccessState = .requesting
        }

        if let currentExchange = rangingExchanges[id] {
            if currentExchange == incomingExchange {
                cancelRangingRecovery(for: id)
                ensureRangingSession(for: peerID, exchange: currentExchange)
                synchronizeCurrentRangingExchange(with: peerID, includeRequest: false)
                return
            }
            guard RadarRangingExchangeCollisionPolicy.shouldAcceptIncoming(
                currentInitiatorPeerID: currentExchange.initiatorPeerID,
                currentExchangeID: currentExchange.id,
                currentSupersedesExchangeID: currentExchange.supersedesExchangeID,
                incomingInitiatorPeerID: incomingExchange.initiatorPeerID,
                incomingExchangeID: incomingExchange.id,
                incomingSupersedesExchangeID: incomingExchange.supersedesExchangeID
            ) else {
                debugLog(
                    "kept winning NI exchange peer=\(id) exchange=\(currentExchange.id.prefix(6))"
                )
                synchronizeCurrentRangingExchange(with: peerID, includeRequest: true)
                return
            }
        }

        adoptRangingExchange(incomingExchange, for: id)
        ensureRangingSession(for: peerID, exchange: incomingExchange)
        drainPendingNearbyTokens(for: peerID)
    }

    private func adoptRangingExchange(
        _ exchange: RadarRangingExchange,
        for id: String
    ) {
        guard rangingExchanges[id] != exchange else { return }
        cancelRangingRecovery(for: id)
        if let previousExchange = rangingExchanges[id] {
            retiredRangingExchangeIDs[id, default: []].insert(previousExchange.id)
        }
        connectedRangingRequestAttempts[id] = nil
        stopRanging(with: id)
        rangingExchanges[id] = exchange
    }

    private func retireCurrentRangingExchange(for id: String) {
        guard let exchange = rangingExchanges.removeValue(forKey: id) else { return }
        retiredRangingExchangeIDs[id, default: []].insert(exchange.id)
        connectedRangingRequestAttempts[id] = nil
    }

    private func synchronizeCurrentRangingExchange(
        with peerID: MCPeerID,
        includeRequest: Bool
    ) {
        let id = peerID.displayName
        guard let exchange = rangingExchanges[id] else { return }
        ensureRangingSession(for: peerID, exchange: exchange)
        guard let context = rangingContexts[id] else { return }
        Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            let sent = await self.sendRangingSynchronization(
                for: context,
                includeRequest: includeRequest
            )
            guard self.rangingContexts[id] === context,
                  self.rangingExchanges[id] == exchange,
                  !sent else { return }
            self.handleRangingTokenExchangeFailure(
                context,
                for: id,
                reason: "exchange-sync-send"
            )
        }
    }

    private func scheduleRangingRecovery(
        with peerID: MCPeerID,
        preservedRemoteToken: NIDiscoveryToken?,
        preservedRemoteTokenData: Data? = nil,
        supersedingExchangeID: String? = nil,
        retryingExchange: RadarRangingExchange? = nil,
        reason: String
    ) {
        let id = peerID.displayName
        let supersededExchangeID = supersedingExchangeID ?? rangingExchanges[id]?.id
        let recovery = RadarPendingRangingRecovery(
            peerID: peerID,
            preservedRemoteToken: preservedRemoteToken,
            preservedRemoteTokenData: preservedRemoteTokenData,
            supersedingExchangeID: supersededExchangeID,
            retryingExchange: retryingExchange,
            reason: reason
        )
        cancelRangingRecovery(for: id)
        guard rangefinderAccessState != .denied,
              rangefinderAccessState != .unsupported,
              allowsTransport,
              rangingControlPeerIDs.contains(id),
              multipeerSession?.connectedPeers.contains(peerID) == true else {
            pendingRangingRecoveries[id] = nil
            retireCurrentRangingExchange(for: id)
            updatePrecision(for: id, state: .unavailable, distance: nil, angle: nil)
            rangefinderAccessState = RadarRangefinderAccessPolicy
                .stateAfterTransientPeerFailure(
                    currentState: rangefinderAccessState,
                    hasOtherActiveContext: !rangingContexts.isEmpty
                )
            return
        }
        guard isApplicationActive else {
            pendingRangingRecoveries[id] = recovery
            debugLog("deferred NI recovery until foreground peer=\(id) reason=\(reason)")
            return
        }
        pendingRangingRecoveries[id] = nil

        let failureCount = rangingRecoveryFailureCounts[id, default: 0] + 1
        rangingRecoveryFailureCounts[id] = failureCount
        guard let delay = RadarRangingTokenRetryPolicy.delayMilliseconds(
            afterFailureCount: failureCount
        ) else {
            terminalRangingFailurePeerIDs.insert(id)
            retireCurrentRangingExchange(for: id)
            updatePrecision(for: id, state: .unavailable, distance: nil, angle: nil)
            rangefinderAccessState = RadarRangefinderAccessPolicy
                .stateAfterTransientPeerFailure(
                    currentState: rangefinderAccessState,
                    hasOtherActiveContext: !rangingContexts.isEmpty
                )
            debugLog("NI recovery exhausted peer=\(id) reason=\(reason)")
            return
        }

        let runID = UUID()
        rangingRecoveryRunIDs[id] = runID
        debugLog(
            "scheduled NI recovery peer=\(id) failure=\(failureCount) reason=\(reason)"
        )
        rangingRecoveryTasks[id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(delay))
            } catch {
                return
            }
            guard let self,
                  self.rangingRecoveryRunIDs[id] == runID,
                  self.rangingRecoveryFailureCounts[id] == failureCount else { return }
            self.rangingRecoveryRunIDs[id] = nil
            self.rangingRecoveryTasks[id] = nil
            guard self.rangefinderAccessState != .denied,
                  self.rangefinderAccessState != .unsupported,
                  self.allowsTransport,
                  self.rangingControlPeerIDs.contains(id),
                  self.rangingContexts[id] == nil,
                  self.multipeerSession?.connectedPeers.contains(peerID) == true else {
                return
            }
            guard self.isApplicationActive else {
                if self.rangingRecoveryFailureCounts[id] == failureCount {
                    self.rangingRecoveryFailureCounts[id] = max(0, failureCount - 1)
                }
                self.pendingRangingRecoveries[id] = recovery
                self.debugLog("paused NI recovery until foreground peer=\(id)")
                return
            }
            if let retryingExchange {
                guard self.rangingExchanges[id] == retryingExchange else { return }
                await self.sendConnectedRangingRequest(
                    retryingExchange,
                    to: peerID,
                    reason: "automatic-request-retry"
                )
            } else if self.connectedRangingCapablePeerIDs.contains(id) {
                await self.initiateNewConnectedRangingExchange(
                    with: peerID,
                    reason: "automatic-recovery",
                    supersedingExchangeID: supersededExchangeID
                )
            } else {
                self.ensureRangingSession(
                    for: peerID,
                    preservedRemoteToken: preservedRemoteToken,
                    preservedRemoteTokenData: preservedRemoteTokenData
                )
            }
        }
    }

    private func cancelRangingRecovery(for id: String) {
        rangingRecoveryTasks[id]?.cancel()
        rangingRecoveryTasks[id] = nil
        rangingRecoveryRunIDs[id] = nil
        pendingRangingRecoveries[id] = nil
    }

    private func clearRangingExchangeState(
        for id: String,
        preservingPendingMessagesFor connectionEpoch: UInt64? = nil
    ) {
        let connectedRequests = connectionEpoch.map { epoch in
            pendingConnectedRangingRequests[id, default: []].filter {
                $0.connectionEpoch == epoch
            }
        } ?? []
        let nearbyTokens = connectionEpoch.map { epoch in
            pendingNearbyTokens[id, default: []].filter {
                $0.connectionEpoch == epoch
            }
        } ?? []
        let probeRequests = connectionEpoch.map { epoch in
            pendingRangefinderProbeRequests[id, default: []].filter {
                $0.connectionEpoch == epoch
            }
        } ?? []
        let probeTokens = connectionEpoch.map { epoch in
            pendingRangefinderProbeTokens[id, default: []].filter {
                $0.connectionEpoch == epoch
            }
        } ?? []
        cancelRangingRecovery(for: id)
        rangingExchanges[id] = nil
        retiredRangingExchangeIDs[id] = nil
        connectedRangingRequestAttempts[id] = nil
        rangingTokenExchangeFailureCounts[id] = nil
        rangingRecoveryFailureCounts[id] = nil
        pendingRangingSessionStartPeerIDs.remove(id)
        pendingRangingConfigurationRefreshPeerIDs.remove(id)
        pendingRangingContextRetryPeerIDs.remove(id)
        pendingConnectedRangingRequests[id] = nil
        pendingNearbyTokens[id] = nil
        pendingRangefinderProbeRequests[id] = nil
        pendingRangefinderProbeTokens[id] = nil
        pendingLegacyRangingPeerIDs.remove(id)
        terminalRangingFailurePeerIDs.remove(id)
        if !connectedRequests.isEmpty {
            pendingConnectedRangingRequests[id] = connectedRequests
        }
        if !nearbyTokens.isEmpty {
            pendingNearbyTokens[id] = nearbyTokens
        }
        if !probeRequests.isEmpty {
            pendingRangefinderProbeRequests[id] = probeRequests
        }
        if !probeTokens.isEmpty {
            pendingRangefinderProbeTokens[id] = probeTokens
        }
    }

    private func clearAllRangingExchangeState() {
        for task in rangingRecoveryTasks.values {
            task.cancel()
        }
        rangingRecoveryTasks.removeAll()
        rangingRecoveryRunIDs.removeAll()
        rangingExchanges.removeAll()
        retiredRangingExchangeIDs.removeAll()
        connectedRangingRequestAttempts.removeAll()
        rangingTokenExchangeFailureCounts.removeAll()
        rangingRecoveryFailureCounts.removeAll()
        pendingRangingRecoveries.removeAll()
        pendingRangingSessionStartPeerIDs.removeAll()
        pendingRangingConfigurationRefreshPeerIDs.removeAll()
        pendingRangingContextRetryPeerIDs.removeAll()
        pendingConnectedRangingRequests.removeAll()
        pendingNearbyTokens.removeAll()
        pendingRangefinderProbeRequests.removeAll()
        pendingRangefinderProbeTokens.removeAll()
        pendingLegacyRangingPeerIDs.removeAll()
        terminalRangingFailurePeerIDs.removeAll()
    }

    private func clearActiveRangefinderProbe(notifyPeer: Bool) {
        guard let context = activeRangefinderProbe else { return }
        activeRangefinderProbe = nil
        context.timeoutTask?.cancel()
        context.timeoutTask = nil
        if let nearbySession = context.nearbySession {
            rangefinderProbeIDsBySession[ObjectIdentifier(nearbySession)] = nil
            nearbySession.delegate = nil
            nearbySession.invalidate()
        }
        if notifyPeer {
            let peerID = context.peerID
            let probeID = context.id
            Task { @MainActor [weak self] in
                _ = await self?.send(
                    .rangefinderProbeComplete(id: probeID),
                    to: peerID
                )
            }
        }
    }

    private func scheduleActiveRangefinderResolutionTimeout(
        _ context: RadarRangefinderProbeContext
    ) {
        context.timeoutTask?.cancel()
        context.timeoutTask = Task { @MainActor [weak self, weak context] in
            do {
                try await Task.sleep(for: .seconds(300))
            } catch {
                return
            }
            guard let self,
                  let context,
                  self.activeRangefinderProbe === context else { return }
            guard self.isApplicationActive else {
                self.scheduleActiveRangefinderResolutionTimeout(context)
                return
            }
            self.finishActiveRangefinderProbe(with: .unavailable)
        }
    }

    private func clearRangefinderProbeResponder(
        for key: RadarRangefinderProbeKey
    ) {
        guard let responder = rangefinderProbeResponders.removeValue(forKey: key) else {
            return
        }
        responder.timeoutTask?.cancel()
        responder.timeoutTask = nil
        responder.nearbySession.invalidate()
    }

    private func scheduleRangefinderResponderTimeout(
        _ responder: RadarRangefinderProbeResponder,
        for key: RadarRangefinderProbeKey
    ) {
        responder.timeoutTask?.cancel()
        responder.timeoutTask = Task { @MainActor [weak self, weak responder] in
            do {
                try await Task.sleep(for: .seconds(300))
            } catch {
                return
            }
            guard let self,
                  let responder,
                  self.rangefinderProbeResponders[key] === responder else { return }
            self.clearRangefinderProbeResponder(for: key)
        }
    }

    private func clearRangefinderProbeResponders(for peerID: String? = nil) {
        let keys = rangefinderProbeResponders.keys.filter {
            peerID == nil || $0.peerID == peerID
        }
        for key in keys {
            clearRangefinderProbeResponder(for: key)
        }
    }

    private func clearAllRangefinderProbeResources(notifyPeer: Bool) {
        clearActiveRangefinderProbe(notifyPeer: notifyPeer)
        clearRangefinderProbeResponders()
    }

    private func normalizeRangefinderStateAfterConnectionLoss() {
        guard Self.canVerifyRangefinderAccess else {
            rangefinderAccessState = .unsupported
            return
        }
        guard activeRangefinderProbe?.nearbySession == nil else { return }
        if rangefinderAccessState == .ready || rangefinderAccessState == .requesting {
            rangefinderAccessState = .waitingForPeer
        }
    }

    private func reconcileRangefinderReadiness() {
        guard Self.canVerifyRangefinderAccess else {
            rangefinderAccessState = .unsupported
            return
        }
        guard allowsTransport, isApplicationActive else { return }
        guard activeRangefinderProbe == nil else { return }
        guard rangefinderAccessState == .granted
                || rangefinderAccessState == .ready
                || rangefinderAccessState == .waitingForPeer else { return }
        guard wantsScanning else {
            rangefinderAccessState = .waitingForPeer
            return
        }
        if rangefinderAccessState == .granted {
            beginConnectedRangingForEligiblePeers()
            return
        }
        guard let peerID = connectedPrecisionPeer() else {
            rangefinderAccessState = .waitingForPeer
            return
        }
        markRangefinderPeerReadyIfNeeded(peerID)
    }

    private func isActiveRangefinderProbeSession(_ session: NISession) -> Bool {
        let sessionID = ObjectIdentifier(session)
        guard let mappedProbeID = rangefinderProbeIDsBySession[sessionID],
              let context = activeRangefinderProbe,
              context.id == mappedProbeID,
              context.nearbySession === session else {
            return false
        }
        return true
    }

    @discardableResult
    private func resumeRangefinderProbeIfNeeded(_ session: NISession) -> Bool {
        let sessionID = ObjectIdentifier(session)
        guard rangefinderProbeIDsBySession[sessionID] != nil else { return false }
        guard isActiveRangefinderProbeSession(session),
              let context = activeRangefinderProbe,
              let peerToken = context.peerToken else {
            rangefinderProbeIDsBySession[sessionID] = nil
            return true
        }
        guard RadarRangefinderResumePolicy.canRun(
            wasSuspended: context.wasSuspended,
            suspensionDidEnd: context.suspensionDidEnd,
            isApplicationActive: isApplicationActive
        ) else { return true }
        context.wasSuspended = false
        context.suspensionDidEnd = false
        let configuration = NINearbyPeerConfiguration(peerToken: peerToken)
        configuration.isExtendedDistanceMeasurementEnabled = false
        session.run(configuration)
        return true
    }

    private func startRanging(
        with tokenData: Data,
        exchangeID: String?,
        exchangeInitiatorPeerID: String?,
        supersedesExchangeID: String?,
        connectionEpoch: UInt64,
        receiveSequence: UInt64,
        from peerID: MCPeerID
    ) {
        let id = peerID.displayName
        let exchange: RadarRangingExchange?
        guard isApplicationActive else { return }
        if connectedRangingCapablePeerIDs.contains(id) {
            guard let exchangeID,
                  let exchangeInitiatorPeerID,
                  exchangeInitiatorPeerID == id
                    || exchangeInitiatorPeerID == localPeerID?.displayName,
                  retiredRangingExchangeIDs[id]?.contains(exchangeID) != true,
                  let currentExchange = rangingExchanges[id],
                  currentExchange == RadarRangingExchange(
                    id: exchangeID,
                    initiatorPeerID: exchangeInitiatorPeerID,
                    supersedesExchangeID: supersedesExchangeID
                  ) else {
                let exchangeLabel = exchangeID.map { String($0.prefix(6)) } ?? "nil"
                debugLog("ignored stale NI token peer=\(id) exchange=\(exchangeLabel)")
                return
            }
            exchange = currentExchange
        } else {
            guard exchangeID == nil,
                  exchangeInitiatorPeerID == nil,
                  supersedesExchangeID == nil else {
                debugLog("ignored versioned NI token on legacy connection peer=\(id)")
                return
            }
            exchange = nil
        }

        guard supportsPreciseDistance,
              let peerToken = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NIDiscoveryToken.self,
                from: tokenData
              ) else {
            debugLog("remote NI token decode failed peer=\(id)")
            updatePrecision(
                for: id,
                state: .unavailable,
                distance: nil,
                angle: nil
            )
            return
        }

        if exchange == nil {
            let cursor = RadarReceiveCursor(
                connectionEpoch: connectionEpoch,
                receiveSequence: receiveSequence
            )
            if let lastCursor = lastAppliedLegacyTokenCursors[id] {
                let isNewer = cursor.connectionEpoch > lastCursor.connectionEpoch
                    || (
                        cursor.connectionEpoch == lastCursor.connectionEpoch
                            && cursor.receiveSequence > lastCursor.receiveSequence
                    )
                guard isNewer else {
                    debugLog(
                        "ignored reordered legacy NI token peer=\(id) sequence=\(receiveSequence)"
                    )
                    return
                }
            }
            lastAppliedLegacyTokenCursors[id] = cursor
        }

        ensureRangingSession(for: peerID, exchange: exchange)
        guard let rangingContext = rangingContexts[id],
              rangingContext.exchange == exchange else { return }
        if let existingTokenData = rangingContext.remoteTokenData {
            guard existingTokenData != tokenData else {
                debugLog("ignored duplicate NI token peer=\(id)")
                return
            }
            guard exchange == nil else {
                debugLog("ignored changed NI token inside one exchange peer=\(id)")
                return
            }
        }
        rangingContext.tokenExchangeTimeoutTask?.cancel()
        rangingContext.tokenExchangeTimeoutTask = nil
        if rangingContext.localTokenDeliveryConfirmed {
            rangingContext.tokenExchangeRetryTask?.cancel()
            rangingContext.tokenExchangeRetryTask = nil
            rangingContext.tokenExchangeRetryRunID = nil
        }
        cancelRangingRecovery(for: id)

        runRanging(rangingContext, with: peerToken, tokenData: tokenData)
    }

    private func runRanging(
        _ rangingContext: RadarRangingContext,
        with peerToken: NIDiscoveryToken,
        tokenData: Data?
    ) {
        let id = rangingContext.peerID.displayName
        let configuration = NINearbyPeerConfiguration(peerToken: peerToken)
        configure(
            configuration,
            for: rangingContext.nearbySession,
            allowCameraAssistance: false
        )
        // Start both phones with the same base UWB configuration. Once the
        // first distance arrives, the phone displaying Radar can safely
        // upgrade its local session to Camera Assistance for a wider bearing.
        rangingContext.didFallbackToBaseRanging = true
        rangingContext.remoteToken = peerToken
        rangingContext.remoteTokenData = tokenData
        rangingContext.nearbySession.run(configuration)
        debugLog("NI ranging run peer=\(id) camera=\(configuration.isCameraAssistanceEnabled)")
        scheduleMeasurementAvailabilityCheck(
            for: id,
            nearbySession: rangingContext.nearbySession
        )
        updatePrecision(
            for: id,
            state: .measuring,
            distance: nil,
            angle: nil
        )
    }

    private func handleRoomInvite(_ message: RadarWireMessage, from peerID: MCPeerID) {
        guard let roomCode = message.roomCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !roomCode.isEmpty else {
            return
        }

        let invitationID = message.invitationID ?? UUID().uuidString
        let invitationKey = RadarReceivedRoomInviteKey(
            sourcePeerID: peerID.displayName,
            invitationID: invitationID
        )
        if let previousState = receivedRoomInvites[invitationKey] {
            if case .responded(let response) = previousState {
                Task { @MainActor [weak self] in
                    await self?.sendInviteResponse(
                        response,
                        invitationID: invitationID,
                        to: peerID
                    )
                }
            }
            debugLog("ignored duplicate room invitation peer=\(peerID.displayName) id=\(invitationID)")
            return
        }
        setReceivedRoomInviteState(.pending, for: invitationKey)

        if invitePolicy == .blocked {
            setReceivedRoomInviteState(.responded(.blocked), for: invitationKey)
            Task { @MainActor [weak self] in
                await self?.sendInviteResponse(
                    .blocked,
                    invitationID: invitationID,
                    to: peerID
                )
            }
            return
        }
        if localAvailability == .inGame {
            setReceivedRoomInviteState(.responded(.inGame), for: invitationKey)
            Task { @MainActor [weak self] in
                await self?.sendInviteResponse(
                    .inGame,
                    invitationID: invitationID,
                    to: peerID
                )
            }
            return
        }

        let invitation = RadarIncomingInvitation(
            roomCode: roomCode.uppercased(),
            hostCallSign: PublicDisplayNameSafety.sanitizedForDisplay(
                message.hostCallSign ?? "",
                limit: 36
            ),
            hostAvatar: Self.discoveryValue(message.hostAvatar ?? "", fallback: "🕵️", limit: 12),
            hostSpyID: Self.discoveryValue(message.hostSpyID ?? "", fallback: "000-000", limit: 7),
            hostSpyCardTheme: SpyCardThemeID(rawValue: message.hostSpyCardTheme ?? "") ?? .field,
            hostSpyCardAccent: SpyCardAccentID(rawValue: message.hostSpyCardAccent ?? "") ?? .signalRed,
            hostSpyCardBadge: SpyCardBadgeID(rawValue: message.hostSpyCardBadge ?? "") ?? .operative,
            hostRating: min(max(message.hostRating ?? 0, -99_999), 99_999),
            hostGamesPlayed: min(max(message.hostGamesPlayed ?? 0, 0), 999_999),
            hostWinRate: min(max(message.hostWinRate ?? 0, 0), 100),
            wireInvitationID: invitationID,
            sourcePeerID: peerID.displayName
        )

        switch invitePolicy {
        case .ask:
            incomingInvitation = invitation
        case .automatic:
            incomingInvitation = invitation
            onAutomaticInvitation?(invitation)
        case .blocked:
            break
        }
    }

    private func handleRoomInviteCancellation(
        _ message: RadarWireMessage,
        from peerID: MCPeerID
    ) {
        guard let invitationID = message.invitationID else { return }
        let invitationKey = RadarReceivedRoomInviteKey(
            sourcePeerID: peerID.displayName,
            invitationID: invitationID
        )
        setReceivedRoomInviteState(.cancelled, for: invitationKey)
        if RadarInvitationCancellationPolicy.matches(
            invitation: incomingInvitation,
            invitationID: invitationID,
            sourcePeerID: peerID.displayName
        ) {
            incomingInvitation = nil
        }
    }

    private func setReceivedRoomInviteState(
        _ state: RadarReceivedRoomInviteState,
        for key: RadarReceivedRoomInviteKey
    ) {
        if receivedRoomInvites[key] == nil {
            receivedRoomInviteOrder.append(key)
        }
        receivedRoomInvites[key] = state
        while receivedRoomInviteOrder.count > Self.maximumRememberedRoomInvites {
            let protectedKey = currentIncomingRoomInviteKey
            let expiredIndex = receivedRoomInviteOrder.firstIndex {
                $0 != protectedKey
            } ?? receivedRoomInviteOrder.startIndex
            let expiredKey = receivedRoomInviteOrder.remove(at: expiredIndex)
            receivedRoomInvites[expiredKey] = nil
        }
    }

    private var currentIncomingRoomInviteKey: RadarReceivedRoomInviteKey? {
        guard let invitation = incomingInvitation,
              let sourcePeerID = invitation.sourcePeerID else { return nil }
        return RadarReceivedRoomInviteKey(
            sourcePeerID: sourcePeerID,
            invitationID: invitation.wireInvitationID
        )
    }

    private func canPresentIncomingInvitation(
        _ invitation: RadarIncomingInvitation
    ) -> Bool {
        guard let sourcePeerID = invitation.sourcePeerID else { return true }
        let key = RadarReceivedRoomInviteKey(
            sourcePeerID: sourcePeerID,
            invitationID: invitation.wireInvitationID
        )
        guard let state = receivedRoomInvites[key] else { return false }
        if case .pending = state { return true }
        return false
    }

    private func clearIncomingInvitationIfMatching(
        _ invitation: RadarIncomingInvitation
    ) {
        guard incomingInvitation?.wireInvitationID == invitation.wireInvitationID,
              incomingInvitation?.sourcePeerID == invitation.sourcePeerID else { return }
        incomingInvitation = nil
    }

    private func removePendingReceivedRoomInvite(
        for invitation: RadarIncomingInvitation
    ) {
        guard let sourcePeerID = invitation.sourcePeerID else { return }
        let key = RadarReceivedRoomInviteKey(
            sourcePeerID: sourcePeerID,
            invitationID: invitation.wireInvitationID
        )
        guard let state = receivedRoomInvites[key],
              case .pending = state else { return }
        receivedRoomInvites[key] = nil
        receivedRoomInviteOrder.removeAll { $0 == key }
    }

    private func sendInviteResponse(
        _ response: RadarWireInviteResponse,
        for invitation: RadarIncomingInvitation
    ) async {
        guard let sourcePeerID = invitation.sourcePeerID else { return }
        setReceivedRoomInviteState(
            .responded(response),
            for: RadarReceivedRoomInviteKey(
                sourcePeerID: sourcePeerID,
                invitationID: invitation.wireInvitationID
            )
        )
        guard let peerID = discoveredPeerIDs[sourcePeerID] else { return }
        await sendInviteResponse(
            response,
            invitationID: invitation.wireInvitationID,
            to: peerID
        )
    }

    private func sendInviteResponse(
        _ response: RadarWireInviteResponse,
        invitationID: String,
        to peerID: MCPeerID
    ) async {
        let message = RadarWireMessage.roomInviteResponse(
            invitationID: invitationID,
            response: response
        )

        // Browser invitations establish the encrypted MCSession just after the
        // room-invite context arrives. Wait briefly so blocked/busy answers are
        // returned on that same local connection instead of being dropped.
        for _ in 0..<14 {
            if await send(message, to: peerID) { return }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    private func applyInviteResponse(
        _ response: RadarWireInviteResponse,
        from peerID: String,
        invitationID: String
    ) {
        guard pendingInvitationIDs[peerID] == invitationID else { return }
        pendingInvitationIDs[peerID] = nil
        pendingRoomInvites[peerID] = nil
        invitationTimeoutRunIDs[peerID] = nil
        if roomInviteConnectionAttempts[peerID] == invitationID {
            roomInviteConnectionAttempts[peerID] = nil
        }

        switch response {
        case .accepted:
            outgoingInvitationStates[peerID] = .accepted
            clearOrAdvanceInvitationState(
                .accepted,
                for: peerID,
                after: .milliseconds(1_450)
            )
        case .declined:
            outgoingInvitationStates[peerID] = .declined
            clearOrAdvanceInvitationState(
                .declined,
                for: peerID,
                after: .milliseconds(2_600)
            )
        case .inGame:
            outgoingInvitationStates[peerID] = .inGame
        case .blocked:
            outgoingInvitationStates[peerID] = .blocked
        }
    }

    private func scheduleInvitationTimeout(for peerID: String, invitationID: String) {
        let runID = UUID()
        invitationTimeoutRunIDs[peerID] = runID
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(18))
            guard let self,
                  self.invitationTimeoutRunIDs[peerID] == runID else { return }
            if self.pendingInvitationIDs[peerID] == invitationID {
                self.markInvitationUnavailable(for: peerID, invitationID: invitationID)
                return
            }
            self.invitationTimeoutRunIDs[peerID] = nil
            guard self.roomInviteConnectionAttempts[peerID] == invitationID else { return }
            self.roomInviteConnectionAttempts[peerID] = nil
            self.clearStaleConnectingStateIfNeeded(for: peerID)
            self.removePeerIfNoLongerReachable(
                peerID,
                ignoringStaleConnectingState: true
            )
        }
    }

    private func markInvitationUnavailable(for peerID: String, invitationID: String) {
        guard pendingInvitationIDs[peerID] == invitationID else { return }
        pendingInvitationIDs[peerID] = nil
        pendingRoomInvites[peerID] = nil
        invitationTimeoutRunIDs[peerID] = nil
        if roomInviteConnectionAttempts[peerID] == invitationID {
            roomInviteConnectionAttempts[peerID] = nil
        }
        clearStaleConnectingStateIfNeeded(for: peerID)
        if removePeerIfNoLongerReachable(
            peerID,
            ignoringStaleConnectingState: true
        ) {
            return
        }
        outgoingInvitationStates[peerID] = .unavailable
        clearOrAdvanceInvitationState(
            .unavailable,
            for: peerID,
            after: .milliseconds(2_400)
        )
    }

    private func clearOrAdvanceInvitationState(
        _ expectedState: RadarOutgoingInvitationState,
        for peerID: String,
        after delay: Duration,
        replacement: RadarOutgoingInvitationState? = nil
    ) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.outgoingInvitationStates[peerID] == expectedState else { return }
            self.outgoingInvitationStates[peerID] = replacement
        }
    }

    private func send(_ message: RadarWireMessage, to peerID: MCPeerID) async -> Bool {
        guard let multipeerSession,
              multipeerSession.connectedPeers.contains(peerID),
              let data = encoded(message) else {
            return false
        }

        let session = SendableMultipeerSession(value: multipeerSession)
        let peer = SendableRadarPeerID(value: peerID)
        return await Task.detached(priority: .userInitiated) {
            do {
                try session.value.send(data, toPeers: [peer.value], with: .reliable)
                return true
            } catch {
                return false
            }
        }.value
    }

    private func encoded(_ message: RadarWireMessage) -> Data? {
        try? JSONEncoder().encode(message)
    }

    private func configure(
        _ configuration: NINearbyPeerConfiguration,
        for nearbySession: NISession,
        allowCameraAssistance: Bool = true
    ) {
        // Some cross-version discovery tokens expose an unusable capabilities
        // object. Reading it can crash in Swift before Nearby Interaction gets
        // a chance to validate the token. Base UWB ranging does not require it.
        configuration.isExtendedDistanceMeasurementEnabled = false

        // Only the person actively looking at the radar should start ARKit and
        // receive the camera permission prompt. Passive nearby players still
        // participate in UWB ranging without activating their camera.
        let canUseCameraAssistance = allowCameraAssistance
            && RadarCameraAssistanceGate.canEnable(
                hasExplicitRadarIntent: wantsCameraAssistance,
                wantsScanning: wantsScanning,
                authorizationStatus: AVCaptureDevice.authorizationStatus(for: .video),
                supportsCameraAssistance: supportsCameraAssistance,
                supportsWorldTracking: ARWorldTrackingConfiguration.isSupported
            )
        configuration.isCameraAssistanceEnabled = canUseCameraAssistance
        if canUseCameraAssistance, let spatialARSession = ensureSpatialARSession() {
            nearbySession.setARSession(spatialARSession)
        }
    }

    private var localPresenceSnapshot: RadarPresenceSnapshot {
        RadarPresenceSnapshot(
            availability: localAvailability,
            invitePolicy: invitePolicy,
            revision: localPresenceRevision
        )
    }

    private func advanceLocalPresenceRevision() {
        let wallClockRevision = Self.initialPresenceRevision()
        localPresenceRevision = max(localPresenceRevision &+ 1, wallClockRevision)
    }

    private func publishLocalPresence() {
        let snapshot = localPresenceSnapshot
        restartAdvertisingIfPossible()
        pendingLocalPresenceSnapshot = snapshot
        guard presencePublishTask == nil else { return }
        let runID = UUID()
        presencePublishRunID = runID
        presencePublishTask = Task { @MainActor [weak self] in
            await self?.runLocalPresencePublishLoop(runID: runID)
        }
    }

    private func runLocalPresencePublishLoop(runID: UUID) async {
        defer {
            if presencePublishRunID == runID {
                presencePublishTask = nil
                presencePublishRunID = nil
            }
        }
        while !Task.isCancelled, let snapshot = pendingLocalPresenceSnapshot {
            pendingLocalPresenceSnapshot = nil
            await broadcastLocalPresence(snapshot)
        }
    }

    private func broadcastLocalPresence(_ snapshot: RadarPresenceSnapshot) async {
        guard let multipeerSession else { return }
        let message = RadarWireMessage.presenceUpdate(snapshot)
        for peerID in multipeerSession.connectedPeers {
            _ = await send(message, to: peerID)
        }
    }

    private func scheduleMeasurementAvailabilityCheck(
        for id: String,
        nearbySession: NISession
    ) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self,
                  let context = self.rangingContexts[id],
                  context.nearbySession === nearbySession,
                  context.lastDistanceMeasurementAt == 0 else {
                return
            }

            self.debugLog("NI measurement unavailable peer=\(id)")
            self.updatePrecision(
                for: id,
                state: .unavailable,
                distance: nil,
                angle: nil,
                relativePosition: nil,
                directionState: .unavailable
            )
            if !context.localTokenDeliveryConfirmed,
               context.tokenExchangeRetryTask == nil {
                self.handleRangingTokenExchangeFailure(
                    context,
                    for: id,
                    reason: "measurement-without-local-token-delivery"
                )
            }
        }
    }

    private func refreshRangingConfigurationsForScanning() {
        guard wantsScanning else { return }

        for context in rangingContexts.values {
            guard let remoteToken = context.remoteToken else { continue }
            let configuration = NINearbyPeerConfiguration(peerToken: remoteToken)
            configure(
                configuration,
                for: context.nearbySession,
                allowCameraAssistance: !context.didFallbackToBaseRanging
            )
            context.nearbySession.run(configuration)
        }
    }

    private func ensureSpatialARSession() -> ARSession? {
        if let spatialARSession {
            return spatialARSession
        }
        guard supportsCameraAssistance, ARWorldTrackingConfiguration.isSupported else {
            return nil
        }

        let spatialARSession = ARSession()
        spatialARSession.delegate = self
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        spatialARSession.run(
            configuration,
            options: [.resetTracking, .removeExistingAnchors]
        )
        self.spatialARSession = spatialARSession
        return spatialARSession
    }

    private func stopSpatialARSession() {
        spatialARSession?.delegate = nil
        spatialARSession?.pause()
        spatialARSession = nil
    }

    private func updateRanging(
        for nearbySession: NISession,
        nearbyObjects: [NINearbyObject]
    ) {
        guard let id = rangingPeerIDsBySession[ObjectIdentifier(nearbySession)],
              let nearbyObject = nearbyObjects.first,
              let context = rangingContexts[id] else {
            return
        }
        if !context.didConfirmStableRanging {
            context.didConfirmStableRanging = true
            rangingTokenExchangeFailureCounts[id] = 0
            rangingRecoveryFailureCounts[id] = 0
            terminalRangingFailurePeerIDs.remove(id)
            debugLog("NI recovery budget reset after live update peer=\(id)")
        }

        let now = Date.timeIntervalSinceReferenceDate
        let measuredDistance = nearbyObject.distance.map(Double.init)
#if DEBUG
        let diagnosticDistance = measuredDistance
            .map { String(format: "%.2f", $0) } ?? "nil"
        let diagnosticAngle = nearbyObject.horizontalAngle
            .map { String(format: "%.2f", Double($0)) } ?? "nil"
        debugLog("NI update peer=\(id) distance=\(diagnosticDistance) angle=\(diagnosticAngle)")
#endif
        // A peer iPhone is not a stationary AR anchor. Use only the current
        // UWB bearing for its radar position. An AR worldTransform may keep the
        // first resolved physical location after the other phone moves, so
        // falling back to it would display a confident but stale marker.
        let measuredPosition = sensorRelativePosition(
            for: nearbyObject,
            distanceMeters: measuredDistance
        )

        if let measuredDistance {
            context.lastDistanceMeasurementAt = now
            if let previous = context.smoothedDistanceMeters {
                context.smoothedDistanceMeters = (previous * 0.58) + (measuredDistance * 0.42)
            } else {
                context.smoothedDistanceMeters = measuredDistance
            }
            upgradeToCameraAssistanceIfPossible(for: id, context: context)
        } else if now - context.lastDistanceMeasurementAt > 0.85 {
            context.smoothedDistanceMeters = nil
        }

        if let measuredPosition {
            context.lastPositionMeasurementAt = now
            // Direction and camera-relative coordinates rotate with this
            // iPhone. Averaging them across frames mixes different coordinate
            // bases and makes the marker lag behind physical rotation. Nearby
            // Interaction already stabilizes the measurement; the view adds a
            // short visual interpolation for the remaining jitter.
            context.smoothedRelativePosition = measuredPosition
        } else {
            context.smoothedRelativePosition = nil
        }

        publishRangingUpdate(
            for: id,
            nearbyObject: nearbyObject,
            context: context,
            now: now
        )
    }

    private func upgradeToCameraAssistanceIfPossible(
        for id: String,
        context: RadarRangingContext
    ) {
        guard wantsScanning,
              supportsCameraAssistance,
              context.didFallbackToBaseRanging,
              let remoteToken = context.remoteToken else {
            return
        }

        context.didFallbackToBaseRanging = false
        let configuration = NINearbyPeerConfiguration(peerToken: remoteToken)
        configure(
            configuration,
            for: context.nearbySession,
            allowCameraAssistance: true
        )
        context.nearbySession.run(configuration)
        debugLog("NI upgraded to camera assistance peer=\(id)")
    }

    private func publishRangingUpdate(
        for id: String,
        nearbyObject: NINearbyObject,
        context: RadarRangingContext,
        now: TimeInterval
    ) {
        // Nearby Interaction can deliver callbacks faster than SwiftUI needs.
        // Filter every sample, but publish at most 12 frames per second so the
        // radar remains fluid without invalidating the whole screen at 60 Hz.
        let publishInterval = 1.0 / 12.0
        guard now - context.lastPublishedAt >= publishInterval else { return }

        let smoothedDistance = context.smoothedDistanceMeters
        let smoothedPosition = context.smoothedRelativePosition

        let measuredAngle = nearbyObject.horizontalAngle.map(Double.init)
            ?? smoothedPosition.map { atan2($0.xMeters, -$0.zMeters) }
        let previousDistance = peers.first(where: { $0.id == id })?.distanceMeters
        let previousPosition = peers.first(where: { $0.id == id })?.relativePosition

        let distanceChanged = switch (smoothedDistance, previousDistance) {
        case (let next?, let previous?): abs(next - previous) >= 0.025
        case (.some, .none), (.none, .some): true
        case (.none, .none): false
        }
        let positionChanged = switch (smoothedPosition, previousPosition) {
        case (let next?, let previous?):
            hypot(next.xMeters - previous.xMeters, next.zMeters - previous.zMeters) >= 0.025
        case (.some, .none), (.none, .some): true
        case (.none, .none): false
        }
        let changedMeaningfully = distanceChanged || positionChanged
        guard changedMeaningfully || now - context.lastPublishedAt >= 0.24 else { return }
        context.lastPublishedAt = now

#if DEBUG
        if now - context.lastDiagnosticAt >= 0.5 {
            context.lastDiagnosticAt = now
            let distance = smoothedDistance.map { String(format: "%.2f", $0) } ?? "nil"
            let angle = nearbyObject.horizontalAngle
                .map { String(format: "%.3f", Double($0)) } ?? "nil"
            let direction = nearbyObject.direction.map {
                String(format: "%.2f,%.2f,%.2f", Double($0.x), Double($0.y), Double($0.z))
            } ?? "nil"
            let position = smoothedPosition.map {
                String(format: "%.2f,%.2f", $0.xMeters, $0.zMeters)
            } ?? "nil"
            print("[RadarNI] distance=\(distance) angle=\(angle) direction=\(direction) position=\(position)")
        }
#endif

        let directionState: RadarDirectionState
        if smoothedPosition != nil {
            directionState = .tracking
        } else if let currentState = peers.first(where: { $0.id == id })?.directionState,
                  case .calibrating = currentState {
            directionState = currentState
        } else if supportsCameraAssistance {
            directionState = .calibrating(.moveSideToSide)
        } else {
            directionState = defaultDirectionState
        }

        updatePrecision(
            for: id,
            state: .measuring,
            distance: smoothedDistance,
            angle: measuredAngle,
            relativePosition: smoothedPosition,
            directionState: directionState
        )
    }

    private func sensorRelativePosition(
        for nearbyObject: NINearbyObject,
        distanceMeters: Double?
    ) -> RadarRelativePosition? {
        guard let distanceMeters, distanceMeters.isFinite, distanceMeters > 0 else {
            return nil
        }

        // Raw UWB direction is the freshest signal when the remote phone moves.
        if let direction = nearbyObject.direction {
            let horizontalMagnitude = hypot(Double(direction.x), Double(direction.z))
            if horizontalMagnitude > 0.001 {
                return RadarRelativePosition(
                    xMeters: Double(direction.x) / horizontalMagnitude * distanceMeters,
                    zMeters: Double(direction.z) / horizontalMagnitude * distanceMeters
                )
            }
        }

        // Camera Assistance widens the useful field of view when raw direction
        // is unavailable, but remains a live bearing rather than a fixed AR
        // world point.
        if let angle = nearbyObject.horizontalAngle.map(Double.init), angle.isFinite {
            return RadarRelativePosition(
                xMeters: sin(angle) * distanceMeters,
                zMeters: -cos(angle) * distanceMeters
            )
        }

        return nil
    }

    private func updatePrecision(
        for id: String,
        state: RadarPrecisionState,
        distance: Double?,
        angle: Double?,
        relativePosition: RadarRelativePosition? = nil,
        directionState: RadarDirectionState? = nil
    ) {
        guard let index = peers.firstIndex(where: { $0.id == id }) else { return }
        let peer = peers[index]
        let resolvedDirectionState: RadarDirectionState
        if let directionState {
            resolvedDirectionState = directionState
        } else {
            resolvedDirectionState = switch state {
            case .unsupported: .unsupported
            case .available: defaultDirectionState
            case .measuring: peer.directionState
            case .unavailable: .unavailable
            }
        }
        peers[index] = RadarNearbyPeer(
            id: peer.id,
            spyID: peer.spyID,
            spyCardTheme: peer.spyCardTheme,
            spyCardAccent: peer.spyCardAccent,
            spyCardBadge: peer.spyCardBadge,
            callSign: peer.callSign,
            avatar: peer.avatar,
            invitePolicy: peer.invitePolicy,
            availability: peer.availability,
            source: peer.source,
            precisionState: state,
            directionState: resolvedDirectionState,
            distanceMeters: distance,
            horizontalAngleRadians: angle,
            relativePosition: relativePosition
        )
    }

    private func applyLegacyAvailability(
        _ availability: RadarPlayerAvailability,
        for id: String
    ) {
        guard let peer = peers.first(where: { $0.id == id }) else { return }
        applyPresence(
            RadarPresenceSnapshot(
                availability: availability,
                invitePolicy: peer.invitePolicy,
                revision: nil
            ),
            for: id
        )
    }

    private func applyPresence(_ presence: RadarPresenceSnapshot, for id: String) {
        guard let index = peers.firstIndex(where: { $0.id == id }) else { return }
        let peer = peers[index]
        guard RadarPresenceVersionPolicy.shouldApply(
            incoming: presence.revision,
            current: peerPresenceRevisions[id]
        ) else {
            debugLog("ignored stale wire presence peer=\(id) revision=\(presence.revision ?? 0)")
            return
        }
        peerPresenceRevisions[id] = presence.revision ?? 0

        peers[index] = RadarNearbyPeer(
            id: peer.id,
            spyID: peer.spyID,
            spyCardTheme: peer.spyCardTheme,
            spyCardAccent: peer.spyCardAccent,
            spyCardBadge: peer.spyCardBadge,
            callSign: peer.callSign,
            avatar: peer.avatar,
            invitePolicy: presence.invitePolicy,
            availability: presence.availability,
            source: peer.source,
            precisionState: peer.precisionState,
            directionState: peer.directionState,
            distanceMeters: peer.distanceMeters,
            horizontalAngleRadians: peer.horizontalAngleRadians,
            relativePosition: peer.relativePosition
        )
        reconcileInvitationState(
            for: id,
            availability: presence.availability,
            invitePolicy: presence.invitePolicy
        )
    }

    private func reconcileInvitationState(
        for peerID: String,
        availability: RadarPlayerAvailability,
        invitePolicy: RadarInvitePolicy
    ) {
        if availability == .inGame || invitePolicy == .blocked {
            pendingInvitationIDs[peerID] = nil
            pendingRoomInvites[peerID] = nil
            // Keep an in-flight transport reservation until MCSession reports
            // its terminal state or its invitation-specific timeout fires.
        }
        outgoingInvitationStates[peerID] = RadarInvitationInteractionPolicy.state(
            after: availability,
            invitePolicy: invitePolicy,
            currentState: outgoingInvitationStates[peerID]
        )
    }

    private func updateDirectionState(for id: String, state: RadarDirectionState) {
        guard let index = peers.firstIndex(where: { $0.id == id }) else { return }
        let peer = peers[index]
        peers[index] = RadarNearbyPeer(
            id: peer.id,
            spyID: peer.spyID,
            spyCardTheme: peer.spyCardTheme,
            spyCardAccent: peer.spyCardAccent,
            spyCardBadge: peer.spyCardBadge,
            callSign: peer.callSign,
            avatar: peer.avatar,
            invitePolicy: peer.invitePolicy,
            availability: peer.availability,
            source: peer.source,
            precisionState: peer.precisionState,
            directionState: state,
            distanceMeters: peer.distanceMeters,
            horizontalAngleRadians: state == .tracking ? peer.horizontalAngleRadians : nil,
            relativePosition: state == .tracking ? peer.relativePosition : nil
        )
    }

    private func defaultPrecisionState(for id: String) -> RadarPrecisionState {
        guard let peer = peers.first(where: { $0.id == id }) else { return .unavailable }
        return peer.precisionState == .unsupported ? .unsupported : .available
    }

    private var defaultDirectionState: RadarDirectionState {
        supportsCameraAssistance || supportsDirectionMeasurement ? .waiting : .unsupported
    }

    private func updateConvergence(
        for nearbySession: NISession,
        convergence: NIAlgorithmConvergence
    ) {
        guard let id = rangingPeerIDsBySession[ObjectIdentifier(nearbySession)] else { return }

        let state: RadarDirectionState = switch convergence.status {
        case .converged:
            .tracking
        case .unknown:
            .waiting
        case .notConverged(let reasons):
            if reasons.contains(.insufficientLighting) {
                .calibrating(.improveLighting)
            } else if reasons.contains(.insufficientSignalStrength) {
                .calibrating(.moveCloser)
            } else if reasons.contains(.insufficientVerticalSweep) {
                .calibrating(.moveUpAndDown)
            } else if reasons.contains(.insufficientHorizontalSweep) {
                .calibrating(.moveSideToSide)
            } else {
                .calibrating(.keepMoving)
            }
        @unknown default:
            .waiting
        }
        if state != .tracking, let context = rangingContexts[id] {
            context.smoothedRelativePosition = nil
            context.lastPositionMeasurementAt = 0
        }
        updateDirectionState(for: id, state: state)
    }

    private func removeRangingObjects(
        for nearbySession: NISession,
        peerEnded: Bool,
        timedOut: Bool
    ) {
        guard let id = rangingPeerIDsBySession[ObjectIdentifier(nearbySession)],
              let context = rangingContexts[id],
              context.nearbySession === nearbySession else { return }

        debugLog("NI removed peer=\(id)")

        context.smoothedDistanceMeters = nil
        context.smoothedRelativePosition = nil
        context.lastDistanceMeasurementAt = 0
        context.lastPositionMeasurementAt = 0
        updatePrecision(
            for: id,
            state: .available,
            distance: nil,
            angle: nil,
            relativePosition: nil,
            directionState: defaultDirectionState
        )

        if timedOut, let remoteToken = context.remoteToken {
            guard rangefinderAccessState != .denied,
                  rangefinderAccessState != .unsupported,
                  allowsTransport,
                  rangingControlPeerIDs.contains(id),
                  multipeerSession?.connectedPeers.contains(context.peerID) == true else {
                return
            }
            guard isApplicationActive else {
                pendingRangingConfigurationRefreshPeerIDs.insert(id)
                debugLog("deferred NI timeout restart until foreground peer=\(id)")
                return
            }
            debugLog("restarting NI after timeout peer=\(id)")
            runRanging(
                context,
                with: remoteToken,
                tokenData: context.remoteTokenData
            )
            return
        }

        // Protocol-v4 peers do not explicitly restart their NI exchange when
        // their session ends. Keep the Multipeer connection and resend our
        // token through the normal bounded retry path so the legacy peer can
        // recreate its session and return a fresh token automatically.
        guard peerEnded,
              context.exchange == nil,
              context.remoteToken != nil,
              context.tokenExchangeRetryTask == nil else { return }
        context.remoteToken = nil
        context.remoteTokenData = nil
        handleRangingTokenExchangeFailure(
            context,
            for: id,
            reason: "legacy-peer-ended"
        )
    }

    private func suspendRanging(for nearbySession: NISession) {
        guard let id = rangingPeerIDsBySession[ObjectIdentifier(nearbySession)],
              let context = rangingContexts[id],
              context.nearbySession === nearbySession else { return }
        context.wasSuspended = true
        context.suspensionDidEnd = false
        debugLog("NI suspended peer=\(id)")
        updatePrecision(
            for: id,
            state: .unavailable,
            distance: nil,
            angle: nil,
            relativePosition: nil,
            directionState: .unavailable
        )
    }

    private func resumeRanging(for nearbySession: NISession) {
        guard let id = rangingPeerIDsBySession[ObjectIdentifier(nearbySession)],
              let context = rangingContexts[id],
              context.nearbySession === nearbySession,
              let remoteToken = context.remoteToken,
              RadarRangefinderResumePolicy.canRun(
                wasSuspended: context.wasSuspended,
                suspensionDidEnd: context.suspensionDidEnd,
                isApplicationActive: isApplicationActive
              ) else {
            return
        }
        context.wasSuspended = false
        context.suspensionDidEnd = false
        debugLog("NI suspension ended peer=\(id)")
        let configuration = NINearbyPeerConfiguration(peerToken: remoteToken)
        let didFallback = context.didFallbackToBaseRanging
        configure(
            configuration,
            for: nearbySession,
            allowCameraAssistance: !didFallback
        )
        nearbySession.run(configuration)
        updatePrecision(for: id, state: .measuring, distance: nil, angle: nil)
    }

    @discardableResult
    private func invalidateRanging(
        for nearbySession: NISession,
        errorDescription: String
    ) -> RadarRangingContext? {
        guard let id = rangingPeerIDsBySession[ObjectIdentifier(nearbySession)] else {
            return nil
        }
        debugLog("NI invalidated peer=\(id) error=\(errorDescription)")
        rangingPeerIDsBySession[ObjectIdentifier(nearbySession)] = nil
        pendingRangingConfigurationRefreshPeerIDs.remove(id)
        let context = rangingContexts.removeValue(forKey: id)
        context?.tokenExchangeTimeoutTask?.cancel()
        context?.tokenExchangeTimeoutTask = nil
        context?.tokenExchangeRetryTask?.cancel()
        context?.tokenExchangeRetryTask = nil
        context?.tokenExchangeRetryRunID = nil
        updatePrecision(for: id, state: .unavailable, distance: nil, angle: nil)
        if rangingContexts.isEmpty {
            stopSpatialARSession()
        }
        refreshIdleTimerProtection()
        return context
    }

    private func refreshIdleTimerProtection() {
        let shouldPreventAutoLock = isApplicationActive
            && (wantsScanning || !connectingPeerIDs.isEmpty || !rangingContexts.isEmpty)
        guard UIApplication.shared.isIdleTimerDisabled != shouldPreventAutoLock else { return }
        UIApplication.shared.isIdleTimerDisabled = shouldPreventAutoLock
        debugLog("idle timer disabled=\(shouldPreventAutoLock)")
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        NSLog("[RadarNearby] %@", message())
#endif
    }

    private func stopRanging(with id: String) {
        pendingRangingConfigurationRefreshPeerIDs.remove(id)
        guard let context = rangingContexts.removeValue(forKey: id) else { return }
        context.tokenExchangeTimeoutTask?.cancel()
        context.tokenExchangeTimeoutTask = nil
        context.tokenExchangeRetryTask?.cancel()
        context.tokenExchangeRetryTask = nil
        context.tokenExchangeRetryRunID = nil
        rangingPeerIDsBySession[ObjectIdentifier(context.nearbySession)] = nil
        context.nearbySession.delegate = nil
        context.nearbySession.invalidate()
        if rangingContexts.isEmpty {
            stopSpatialARSession()
        }
        refreshIdleTimerProtection()
    }

    private func stopAllRanging() {
        pendingRangingConfigurationRefreshPeerIDs.removeAll()
        let contexts = Array(rangingContexts.values)
        rangingContexts.removeAll()
        rangingPeerIDsBySession.removeAll()
        for context in contexts {
            context.tokenExchangeTimeoutTask?.cancel()
            context.tokenExchangeTimeoutTask = nil
            context.tokenExchangeRetryTask?.cancel()
            context.tokenExchangeRetryTask = nil
            context.tokenExchangeRetryRunID = nil
            context.nearbySession.delegate = nil
            context.nearbySession.invalidate()
        }
        stopSpatialARSession()
        refreshIdleTimerProtection()
    }

    private static func persistentPeerID() -> MCPeerID {
        if let archivedPeerID = UserDefaults.standard.data(forKey: peerIDStorageKey),
           let peerID = try? NSKeyedUnarchiver.unarchivedObject(
               ofClass: MCPeerID.self,
               from: archivedPeerID
           ) {
            return peerID
        }

        let suffix = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(12)
            .lowercased()
        let peerID = MCPeerID(displayName: "spy-\(suffix)")
        if let archivedPeerID = try? NSKeyedArchiver.archivedData(
            withRootObject: peerID,
            requiringSecureCoding: true
        ) {
            UserDefaults.standard.set(archivedPeerID, forKey: peerIDStorageKey)
        }
        return peerID
    }

    private static func discoveryValue(_ value: String, fallback: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? fallback : trimmed
        return String(resolved.prefix(limit))
    }

    private static func winRate(gamesPlayed: Int?, gamesWon: Int?) -> Int {
        let played = max(0, gamesPlayed ?? 0)
        guard played > 0 else { return 0 }
        let won = min(max(0, gamesWon ?? 0), played)
        return Int((Double(won) / Double(played) * 100).rounded())
    }

    private static func initialPresenceRevision() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
    }
}

private struct RadarLocalIdentity: Equatable {
    let userID: String
    let spyID: String
    let spyCardTheme: SpyCardThemeID
    let spyCardAccent: SpyCardAccentID
    let spyCardBadge: SpyCardBadgeID
    let callSign: String
    let avatar: String
    let rating: Int
    let gamesPlayed: Int
    let winRate: Int
}

private struct RadarRangefinderProbeKey: Hashable {
    let peerID: String
    let probeID: String
}

@MainActor
private final class RadarRangefinderProbeContext {
    let id: String
    let peerID: MCPeerID
    var nearbySession: NISession?
    var peerToken: NIDiscoveryToken?
    var timeoutTask: Task<Void, Never>?
    var requestSendAttemptID: UUID?
    var wasSuspended = false
    var suspensionDidEnd = false

    init(id: String, peerID: MCPeerID) {
        self.id = id
        self.peerID = peerID
    }
}

@MainActor
private final class RadarRangefinderProbeResponder {
    let peerID: MCPeerID
    let nearbySession: NISession
    let tokenData: Data
    var timeoutTask: Task<Void, Never>?

    init(
        peerID: MCPeerID,
        nearbySession: NISession,
        tokenData: Data
    ) {
        self.peerID = peerID
        self.nearbySession = nearbySession
        self.tokenData = tokenData
    }
}

@MainActor
private final class RadarRangingContext {
    let peerID: MCPeerID
    let nearbySession: NISession
    let localTokenData: Data
    let exchange: RadarRangingExchange?
    var tokenExchangeTimeoutTask: Task<Void, Never>?
    var tokenExchangeRetryTask: Task<Void, Never>?
    var tokenExchangeRetryRunID: UUID?
    var remoteToken: NIDiscoveryToken?
    var remoteTokenData: Data?
    var localTokenDeliveryConfirmed = false
    var lastPublishedAt: TimeInterval = 0
    var lastDistanceMeasurementAt: TimeInterval = 0
    var lastPositionMeasurementAt: TimeInterval = 0
    var smoothedDistanceMeters: Double?
    var smoothedRelativePosition: RadarRelativePosition?
    var didFallbackToBaseRanging = false
    var didConfirmStableRanging = false
    var wasSuspended = false
    var suspensionDidEnd = false
#if DEBUG
    var lastDiagnosticAt: TimeInterval = 0
#endif

    init(
        peerID: MCPeerID,
        nearbySession: NISession,
        localTokenData: Data,
        exchange: RadarRangingExchange?
    ) {
        self.peerID = peerID
        self.nearbySession = nearbySession
        self.localTokenData = localTokenData
        self.exchange = exchange
    }
}

private struct SendableRadarPeerID: @unchecked Sendable {
    let value: MCPeerID
}

private struct SendableNearbyBrowser: @unchecked Sendable {
    let value: MCNearbyServiceBrowser
}

private struct SendableNearbyAdvertiser: @unchecked Sendable {
    let value: MCNearbyServiceAdvertiser
}

private struct SendableMultipeerSession: @unchecked Sendable {
    let value: MCSession
}

private struct SendableInvitationHandler: @unchecked Sendable {
    let value: (Bool, MCSession?) -> Void
}

private struct SendableNearbySession: @unchecked Sendable {
    let value: NISession
}

private struct SendableNearbyObjects: @unchecked Sendable {
    let value: [NINearbyObject]
}

private struct SendableAlgorithmConvergence: @unchecked Sendable {
    let value: NIAlgorithmConvergence
}

extension RadarNearbyService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        let activeBrowser = SendableNearbyBrowser(value: browser)
        let peer = SendableRadarPeerID(value: peerID)
        Task { @MainActor [weak self] in
            guard let self,
                  self.allowsTransport,
                  self.browser === activeBrowser.value else { return }
            self.recordFoundPeer(peer.value, discoveryInfo: info)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let activeBrowser = SendableNearbyBrowser(value: browser)
        let peer = SendableRadarPeerID(value: peerID)
        Task { @MainActor [weak self] in
            guard let self,
                  self.allowsTransport,
                  self.browser === activeBrowser.value else { return }
            self.removeLostPeer(peer.value)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        let activeBrowser = SendableNearbyBrowser(value: browser)
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self,
                  self.allowsTransport,
                  self.browser === activeBrowser.value else { return }
            self.markTransportUnavailable(message)
        }
    }
}

extension RadarNearbyService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let activeAdvertiser = SendableNearbyAdvertiser(value: advertiser)
        let peer = SendableRadarPeerID(value: peerID)
        let handler = SendableInvitationHandler(value: invitationHandler)
        Task { @MainActor [weak self] in
            guard let self else {
                handler.value(false, nil)
                return
            }
            guard self.allowsTransport,
                  self.advertiser === activeAdvertiser.value else {
                handler.value(false, nil)
                return
            }
            self.handleConnectionRequest(
                from: peer.value,
                context: context,
                invitationHandler: handler.value
            )
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        let activeAdvertiser = SendableNearbyAdvertiser(value: advertiser)
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self,
                  self.allowsTransport,
                  self.advertiser === activeAdvertiser.value else { return }
            self.markTransportUnavailable(message)
        }
    }
}

extension RadarNearbyService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let activeSession = SendableMultipeerSession(value: session)
        let peer = SendableRadarPeerID(value: peerID)
        let connectionEpoch = connectionEpochTracker.record(
            state,
            for: peerID.displayName,
            in: session
        )
        Task { @MainActor [weak self] in
            guard let self,
                  self.allowsTransport,
                  self.multipeerSession === activeSession.value else { return }
            self.handleSessionState(
                state,
                peerID: peer.value,
                session: activeSession.value,
                connectionEpoch: connectionEpoch
            )
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive data: Data,
        fromPeer peerID: MCPeerID
    ) {
        let activeSession = SendableMultipeerSession(value: session)
        let peer = SendableRadarPeerID(value: peerID)
        let delivery = connectionEpochTracker.recordReceive(
            for: peerID.displayName,
            in: session
        )
        Task { @MainActor [weak self] in
            guard let self,
                  self.allowsTransport,
                  self.multipeerSession === activeSession.value else { return }
            self.handleReceivedData(
                data,
                from: peer.value,
                connectionEpoch: delivery.connectionEpoch,
                receiveSequence: delivery.receiveSequence
            )
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}
}

extension RadarNearbyService: NISessionDelegate {
    nonisolated func sessionDidStartRunning(_ session: NISession) {
        let sendableSession = SendableNearbySession(value: session)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let sessionID = ObjectIdentifier(sendableSession.value)
            if self.rangefinderProbeIDsBySession[sessionID] != nil {
                guard self.isActiveRangefinderProbeSession(sendableSession.value) else {
                    self.rangefinderProbeIDsBySession[sessionID] = nil
                    return
                }
                self.finishActiveRangefinderProbe(with: .granted)
                return
            }
            guard let id = self.rangingPeerIDsBySession[
                ObjectIdentifier(sendableSession.value)
            ],
                  let context = self.rangingContexts[id],
                  context.nearbySession === sendableSession.value else { return }
            if context.localTokenDeliveryConfirmed {
                self.rangingTokenExchangeFailureCounts[id] = 0
                self.pendingRangingContextRetryPeerIDs.remove(id)
            }
            self.terminalRangingFailurePeerIDs.remove(id)
            self.rangefinderAccessState = .granted
            self.debugLog("NI started peer=\(id)")
        }
    }

    nonisolated func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        let sendableSession = SendableNearbySession(value: session)
        let sendableObjects = SendableNearbyObjects(value: nearbyObjects)
        Task { @MainActor [weak self] in
            self?.updateRanging(
                for: sendableSession.value,
                nearbyObjects: sendableObjects.value
            )
        }
    }

    nonisolated func session(
        _ session: NISession,
        didRemove nearbyObjects: [NINearbyObject],
        reason: NINearbyObject.RemovalReason
    ) {
        let sendableSession = SendableNearbySession(value: session)
        let peerEnded = reason == .peerEnded
        let timedOut = reason == .timeout
        Task { @MainActor [weak self] in
            self?.removeRangingObjects(
                for: sendableSession.value,
                peerEnded: peerEnded,
                timedOut: timedOut
            )
        }
    }

    nonisolated func sessionWasSuspended(_ session: NISession) {
        let sendableSession = SendableNearbySession(value: session)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let sessionID = ObjectIdentifier(sendableSession.value)
            if self.rangefinderProbeIDsBySession[sessionID] != nil {
                guard self.isActiveRangefinderProbeSession(sendableSession.value) else {
                    self.rangefinderProbeIDsBySession[sessionID] = nil
                    return
                }
                self.activeRangefinderProbe?.wasSuspended = true
                self.activeRangefinderProbe?.suspensionDidEnd = false
                return
            }
            self.suspendRanging(for: sendableSession.value)
        }
    }

    nonisolated func session(
        _ session: NISession,
        didUpdateAlgorithmConvergence convergence: NIAlgorithmConvergence,
        for object: NINearbyObject?
    ) {
        let sendableSession = SendableNearbySession(value: session)
        let sendableConvergence = SendableAlgorithmConvergence(value: convergence)
        Task { @MainActor [weak self] in
            self?.updateConvergence(
                for: sendableSession.value,
                convergence: sendableConvergence.value
            )
        }
    }

    nonisolated func sessionSuspensionEnded(_ session: NISession) {
        let sendableSession = SendableNearbySession(value: session)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let sessionID = ObjectIdentifier(sendableSession.value)
            if self.rangefinderProbeIDsBySession[sessionID] != nil {
                guard self.isActiveRangefinderProbeSession(sendableSession.value) else {
                    self.rangefinderProbeIDsBySession[sessionID] = nil
                    return
                }
                self.activeRangefinderProbe?.suspensionDidEnd = true
                _ = self.resumeRangefinderProbeIfNeeded(sendableSession.value)
                return
            }
            if let id = self.rangingPeerIDsBySession[sessionID],
               let context = self.rangingContexts[id],
               context.nearbySession === sendableSession.value {
                context.suspensionDidEnd = true
            }
            self.resumeRanging(for: sendableSession.value)
        }
    }

    nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {
        let sendableSession = SendableNearbySession(value: session)
        let nsError = error as NSError
        let errorDescription = "\(nsError.domain)#\(nsError.code): \(nsError.localizedDescription)"
        Task { @MainActor [weak self] in
            guard let self else { return }
            let sessionID = ObjectIdentifier(sendableSession.value)
            if self.rangefinderProbeIDsBySession[sessionID] != nil {
                guard self.isActiveRangefinderProbeSession(sendableSession.value) else {
                    self.rangefinderProbeIDsBySession[sessionID] = nil
                    return
                }
                let state = RadarRangefinderAccessPolicy.stateAfterInvalidation(
                    nsError,
                    canVerifyOnCurrentDevice: Self.canVerifyRangefinderAccess
                )
                self.finishActiveRangefinderProbe(with: state)
                return
            }
            guard self.rangingPeerIDsBySession[sessionID] != nil else {
                // The session was explicitly stopped while this delegate
                // callback was queued. Its stale error must not overwrite the
                // access state of a newer probe or ranging session.
                return
            }
            let previousAccessState = self.rangefinderAccessState
            let mappedState = RadarRangefinderAccessPolicy.stateAfterInvalidation(
                nsError,
                canVerifyOnCurrentDevice: Self.canVerifyRangefinderAccess
            )
            let invalidatedContext = self.invalidateRanging(
                for: sendableSession.value,
                errorDescription: errorDescription
            )
            self.rangefinderAccessState = RadarRangefinderAccessPolicy
                .stateAfterRangingInvalidation(
                    nsError,
                    currentState: previousAccessState,
                    hasOtherActiveContext: !self.rangingContexts.isEmpty,
                    canVerifyOnCurrentDevice: Self.canVerifyRangefinderAccess
                )
            if let invalidatedPeerID = invalidatedContext?.peerID.displayName,
               invalidatedContext?.exchange != nil {
                self.retireCurrentRangingExchange(for: invalidatedPeerID)
            }
            if mappedState == .unavailable,
               let invalidatedContext,
               self.allowsTransport,
               self.rangingControlPeerIDs.contains(invalidatedContext.peerID.displayName),
               self.multipeerSession?.connectedPeers.contains(invalidatedContext.peerID) == true {
                let invalidatedPeerID = invalidatedContext.peerID.displayName
                let usesConnectedExchange = self.connectedRangingCapablePeerIDs.contains(
                    invalidatedPeerID
                )
                let preservedRemoteToken = usesConnectedExchange
                    ? nil
                    : invalidatedContext.remoteToken
                let preservedRemoteTokenData = usesConnectedExchange
                    ? nil
                    : invalidatedContext.remoteTokenData
                self.scheduleRangingRecovery(
                    with: invalidatedContext.peerID,
                    preservedRemoteToken: preservedRemoteToken,
                    preservedRemoteTokenData: preservedRemoteTokenData,
                    supersedingExchangeID: invalidatedContext.exchange?.id,
                    reason: "session-invalidation"
                )
            }
        }
    }
}

extension RadarNearbyService: ARSessionDelegate {
    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        false
    }
}
