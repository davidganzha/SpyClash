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

    static var rangingRequest: RadarWireMessage {
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
            presence: nil
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
            presence: nil
        )
    }

    static func nearbyToken(_ token: Data) -> RadarWireMessage {
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
            presence: nil
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
            presence: nil
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
            presence: nil
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
            presence: nil
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
            presence: presence
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
    private static let protocolVersion = "4"
    private static let peerIDStorageKey = "spyclash.radar.multipeer-id"

    private(set) var peers: [RadarNearbyPeer] = []
    private(set) var scanState: RadarScanState = .idle
    private(set) var incomingInvitation: RadarIncomingInvitation?
    private(set) var outgoingInvitationStates: [String: RadarOutgoingInvitationState] = [:]
    private(set) var supportsPreciseDistance: Bool
    private(set) var supportsDirectionMeasurement: Bool
    private(set) var supportsCameraAssistance: Bool

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
    private var rangingControlPeerIDs: Set<String> = []
    private var rangingInviteAttempts: [String: UUID] = [:]
    private var roomInviteConnectionAttempts: [String: String] = [:]
    private var invitationTimeoutRunIDs: [String: UUID] = [:]
    private var receivedRoomInvites: [RadarReceivedRoomInviteKey: RadarReceivedRoomInviteState] = [:]
    private var receivedRoomInviteOrder: [RadarReceivedRoomInviteKey] = []
    private var pendingRoomInvites: [String: RadarWireMessage] = [:]
    private var pendingInvitationIDs: [String: String] = [:]
    private var rangingContexts: [String: RadarRangingContext] = [:]
    private var rangingPeerIDsBySession: [ObjectIdentifier: String] = [:]
    private var spatialARSession: ARSession?
    private var localPresenceRevision = RadarNearbyService.initialPresenceRevision()
    private var isApplyingIdentityConfiguration = false
    private var pendingLocalPresenceSnapshot: RadarPresenceSnapshot?
    @ObservationIgnored private var presencePublishTask: Task<Void, Never>?
    private var presencePublishRunID: UUID?
#if DEBUG
    private var usesPreviewRangingPeers = false
#endif

    override init() {
        invitePolicy = .ask
        supportsPreciseDistance = NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
        supportsDirectionMeasurement = NISession.deviceCapabilities.supportsDirectionMeasurement
        supportsCameraAssistance = NISession.deviceCapabilities.supportsCameraAssistance
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

    func setApplicationActive(_ isActive: Bool) {
        guard isApplicationActive != isActive else { return }
        isApplicationActive = isActive
        debugLog("application active=\(isActive)")
        refreshIdleTimerProtection()

        if isActive {
            supportsPreciseDistance = NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
            supportsDirectionMeasurement = NISession.deviceCapabilities.supportsDirectionMeasurement
            supportsCameraAssistance = NISession.deviceCapabilities.supportsCameraAssistance
            if allowsTransport, wantsCameraAssistance {
                requestCameraAuthorizationForExplicitRadarUse()
            }
            if allowsTransport {
                rebuildTransportIfNeeded()
            }
        } else {
            stopTransport(clearPeers: true)
        }
    }

    func startScanning(requestCameraAccess: Bool = false) {
        guard allowsTransport else {
            scanState = .idle
            return
        }
        wantsScanning = true
        wantsCameraAssistance = requestCameraAccess
        if requestCameraAccess {
            requestCameraAuthorizationForExplicitRadarUse()
        }
        refreshIdleTimerProtection()
        debugLog("scan requested active=\(isApplicationActive) identity=\(identity != nil)")
        guard isApplicationActive, identity != nil else {
            scanState = .idle
            return
        }

        if advertiser == nil || multipeerSession == nil {
            rebuildTransportIfNeeded()
        }
        startBrowserIfPossible()
#if DEBUG
        if usesPreviewRangingPeers {
            applyPreviewRangingPeers()
        }
#endif
    }

    func stopScanning() {
        wantsScanning = false
        wantsCameraAssistance = false
        cameraAuthorizationRequestID = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        multipeerSession?.disconnect()
        stopAllRanging()
        rangingInviteAttempts.removeAll()
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
        rangingControlPeerIDs.removeAll()
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

    func acceptIncomingInvitation() async {
        guard let invitation = incomingInvitation else { return }
        incomingInvitation = nil
        guard invitePolicy != .blocked else {
            await sendInviteResponse(.blocked, for: invitation)
            return
        }
        await sendInviteResponse(.accepted, for: invitation)
    }

    func declineIncomingInvitation() {
        guard let invitation = incomingInvitation else { return }
        incomingInvitation = nil
        Task { @MainActor [weak self] in
            await self?.sendInviteResponse(.declined, for: invitation)
        }
    }

#if DEBUG
    func installPreviewRangingPeers() {
        usesPreviewRangingPeers = true
        applyPreviewRangingPeers()
    }

    private func applyPreviewRangingPeers() {
        supportsPreciseDistance = true
        supportsDirectionMeasurement = true
        supportsCameraAssistance = true
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
                "precision": supportsPreciseDistance ? "1" : "0"
            ],
            serviceType: Self.serviceType
        )
        advertiser.delegate = self
        self.advertiser = advertiser
        advertiser.startAdvertisingPeer()
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

    private func stopTransport(clearPeers: Bool) {
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
        discoveredPeerIDs.removeAll()
        browsedPeerIDs.removeAll()
        connectingPeerIDs.removeAll()
        presenceControlPeerIDs.removeAll()
        presenceInviteAttempts.removeAll()
        presenceRetryCounts.removeAll()
        peerPresenceRevisions.removeAll()
        rangingControlPeerIDs.removeAll()
        rangingInviteAttempts.removeAll()
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
        guard discoveryInfo?["v"] == Self.protocolVersion else { return }

        let id = peerID.displayName
        debugLog("discovered peer=\(id)")
        let policy = RadarInvitePolicy(rawValue: discoveryInfo?["policy"] ?? "") ?? .ask
        let availability = RadarPlayerAvailability(
            rawValue: discoveryInfo?["availability"] ?? ""
        ) ?? .available
        let presenceRevision = discoveryInfo?["presence_rev"].flatMap(UInt64.init)
        let source = RadarTransportSource(rawValue: discoveryInfo?["source"] ?? "") ?? .iphone
        let peerSupportsPrecision = discoveryInfo?["precision"] == "1"
        let previous = peers.first(where: { $0.id == id })

        discoveredPeerIDs[id] = peerID
        browsedPeerIDs.insert(id)
        guard RadarPresenceVersionPolicy.shouldApply(
            incoming: presenceRevision,
            current: peerPresenceRevisions[id]
        ) else {
            debugLog("ignored stale discovery presence peer=\(id) revision=\(presenceRevision ?? 0)")
            beginPresenceSubscription(with: peerID)
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
        beginPresenceSubscription(with: peerID)
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
        browsedPeerIDs.remove(id)
        discoveredPeerIDs[id] = nil
        connectingPeerIDs.remove(id)
        presenceControlPeerIDs.remove(id)
        presenceInviteAttempts[id] = nil
        presenceRetryCounts[id] = nil
        peerPresenceRevisions[id] = nil
        rangingControlPeerIDs.remove(id)
        rangingInviteAttempts[id] = nil
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
            Task { @MainActor [weak self] in
                guard let self else { return }
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
              supportsPreciseDistance,
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
            guard invitePolicy != .blocked,
                  supportsPreciseDistance,
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
        session: MCSession
    ) {
        guard multipeerSession === session else {
            debugLog("ignored stale multipeer state=\(state.rawValue) peer=\(peerID.displayName)")
            return
        }
        let id = peerID.displayName
        debugLog("multipeer state=\(state.rawValue) peer=\(id)")
        switch state {
        case .connected:
            connectingPeerIDs.remove(id)
            let roomInvitationID = roomInviteConnectionAttempts.removeValue(forKey: id)
            let hadRangingInviteAttempt = rangingInviteAttempts.removeValue(forKey: id) != nil
            let hadPresenceInviteAttempt = presenceInviteAttempts.removeValue(forKey: id) != nil
            let isPresenceControl = presenceControlPeerIDs.contains(id)
                || hadPresenceInviteAttempt
            if isPresenceControl {
                presenceControlPeerIDs.insert(id)
                presenceRetryCounts[id] = 0
            }
            if rangingControlPeerIDs.contains(id) || hadRangingInviteAttempt {
                rangingControlPeerIDs.insert(id)
                ensureRangingSession(for: peerID)
            }
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
            connectingPeerIDs.remove(id)
            let roomInvitationID = roomInviteConnectionAttempts.removeValue(forKey: id)
            let hadRangingInviteAttempt = rangingInviteAttempts.removeValue(forKey: id) != nil
            let wasRangingControl = rangingControlPeerIDs.remove(id) != nil
                || hadRangingInviteAttempt
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

        case .connecting:
            connectingPeerIDs.insert(id)

        @unknown default:
            connectingPeerIDs.remove(id)
            presenceControlPeerIDs.remove(id)
            presenceInviteAttempts[id] = nil
            rangingControlPeerIDs.remove(id)
            rangingInviteAttempts[id] = nil
            roomInviteConnectionAttempts[id] = nil
            stopRanging(with: id)
        }
        refreshIdleTimerProtection()
    }

    private func scheduleRangingRetry(with peerID: MCPeerID) {
        let id = peerID.displayName
        guard wantsScanning,
              browsedPeerIDs.contains(id),
              rangingInviteAttempts[id] == nil,
              roomInviteConnectionAttempts[id] == nil else {
            return
        }

        Task { @MainActor [weak self] in
            // The receiver can report a failed handshake slightly later than
            // the browser side. Give both MCSession instances time to leave
            // `.connecting` before issuing another invitation.
            try? await Task.sleep(for: .seconds(2))
            guard let self,
                  self.wantsScanning,
                  self.browsedPeerIDs.contains(id),
                  self.discoveredPeerIDs[id]?.displayName == id,
                  !self.connectingPeerIDs.contains(id),
                  self.rangingInviteAttempts[id] == nil else {
                return
            }
            self.debugLog("retrying ranging invitation peer=\(id)")
            self.beginRangingHandshake(with: peerID)
        }
    }

    private func ensureRangingSession(for peerID: MCPeerID) {
        let id = peerID.displayName
        guard supportsPreciseDistance,
              rangingContexts[id] == nil,
              let multipeerSession,
              multipeerSession.connectedPeers.contains(peerID) else {
            debugLog("NI session skipped peer=\(id) precision=\(supportsPreciseDistance) existing=\(rangingContexts[id] != nil)")
            return
        }

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
            return
        }

        let rangingContext = RadarRangingContext(peerID: peerID, nearbySession: nearbySession)
        rangingContexts[id] = rangingContext
        rangingPeerIDsBySession[ObjectIdentifier(nearbySession)] = id
        refreshIdleTimerProtection()
        debugLog("NI session created peer=\(id); sending local token")
        updatePrecision(for: id, state: .available, distance: nil, angle: nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let sent = await self.send(.nearbyToken(archivedToken), to: peerID)
            self.debugLog("NI local token sent=\(sent) peer=\(id)")
            guard self.rangingContexts[id]?.nearbySession === nearbySession else { return }
            if !sent {
                self.stopRanging(with: id)
                self.updatePrecision(for: id, state: .unavailable, distance: nil, angle: nil)
            }
        }
    }

    private func handleReceivedData(_ data: Data, from peerID: MCPeerID) {
        guard allowsTransport else { return }
        guard let message = try? JSONDecoder().decode(RadarWireMessage.self, from: data),
              message.version == 1 else {
            return
        }

        switch message.kind {
        case .presenceSubscription:
            break
        case .nearbyToken:
            let id = peerID.displayName
            guard rangingControlPeerIDs.contains(id) else {
                debugLog("ignored NI token without ranging intent peer=\(id)")
                return
            }
            debugLog("received NI token peer=\(id)")
            guard let tokenData = message.token else { return }
            startRanging(with: tokenData, from: peerID)
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
            break
        }
    }

    private func startRanging(with tokenData: Data, from peerID: MCPeerID) {
        guard supportsPreciseDistance,
              let peerToken = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NIDiscoveryToken.self,
                from: tokenData
              ) else {
            debugLog("remote NI token decode failed peer=\(peerID.displayName)")
            updatePrecision(
                for: peerID.displayName,
                state: .unavailable,
                distance: nil,
                angle: nil
            )
            return
        }

        ensureRangingSession(for: peerID)
        guard let rangingContext = rangingContexts[peerID.displayName] else { return }

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
        rangingContext.nearbySession.run(configuration)
        debugLog("NI ranging run peer=\(peerID.displayName) camera=\(configuration.isCameraAssistanceEnabled)")
        scheduleMeasurementAvailabilityCheck(
            for: peerID.displayName,
            nearbySession: rangingContext.nearbySession
        )
        updatePrecision(
            for: peerID.displayName,
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

    private func removeRangingObjects(for nearbySession: NISession) {
        guard let id = rangingPeerIDsBySession[ObjectIdentifier(nearbySession)],
              let context = rangingContexts[id] else { return }

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
    }

    private func suspendRanging(for nearbySession: NISession) {
        guard let id = rangingPeerIDsBySession[ObjectIdentifier(nearbySession)] else { return }
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
              let remoteToken = rangingContexts[id]?.remoteToken else {
            return
        }
        debugLog("NI suspension ended peer=\(id)")
        let configuration = NINearbyPeerConfiguration(peerToken: remoteToken)
        let didFallback = rangingContexts[id]?.didFallbackToBaseRanging == true
        configure(
            configuration,
            for: nearbySession,
            allowCameraAssistance: !didFallback
        )
        nearbySession.run(configuration)
        updatePrecision(for: id, state: .measuring, distance: nil, angle: nil)
    }

    private func invalidateRanging(
        for nearbySession: NISession,
        errorDescription: String
    ) {
        guard let id = rangingPeerIDsBySession[ObjectIdentifier(nearbySession)] else { return }
        debugLog("NI invalidated peer=\(id) error=\(errorDescription)")
        rangingPeerIDsBySession[ObjectIdentifier(nearbySession)] = nil
        rangingContexts[id] = nil
        updatePrecision(for: id, state: .unavailable, distance: nil, angle: nil)
        if rangingContexts.isEmpty {
            stopSpatialARSession()
        }
        refreshIdleTimerProtection()
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
        guard let context = rangingContexts.removeValue(forKey: id) else { return }
        rangingPeerIDsBySession[ObjectIdentifier(context.nearbySession)] = nil
        context.nearbySession.delegate = nil
        context.nearbySession.invalidate()
        if rangingContexts.isEmpty {
            stopSpatialARSession()
        }
        refreshIdleTimerProtection()
    }

    private func stopAllRanging() {
        let contexts = Array(rangingContexts.values)
        rangingContexts.removeAll()
        rangingPeerIDsBySession.removeAll()
        for context in contexts {
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

@MainActor
private final class RadarRangingContext {
    let peerID: MCPeerID
    let nearbySession: NISession
    var remoteToken: NIDiscoveryToken?
    var lastPublishedAt: TimeInterval = 0
    var lastDistanceMeasurementAt: TimeInterval = 0
    var lastPositionMeasurementAt: TimeInterval = 0
    var smoothedDistanceMeters: Double?
    var smoothedRelativePosition: RadarRelativePosition?
    var didFallbackToBaseRanging = false
#if DEBUG
    var lastDiagnosticAt: TimeInterval = 0
#endif

    init(peerID: MCPeerID, nearbySession: NISession) {
        self.peerID = peerID
        self.nearbySession = nearbySession
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
            self.scanState = .unavailable(message)
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
                  self.advertiser === activeAdvertiser.value,
                  self.wantsScanning else { return }
            self.scanState = .unavailable(message)
        }
    }
}

extension RadarNearbyService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let activeSession = SendableMultipeerSession(value: session)
        let peer = SendableRadarPeerID(value: peerID)
        Task { @MainActor [weak self] in
            guard let self,
                  self.allowsTransport,
                  self.multipeerSession === activeSession.value else { return }
            self.handleSessionState(
                state,
                peerID: peer.value,
                session: activeSession.value
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
        Task { @MainActor [weak self] in
            guard let self,
                  self.allowsTransport,
                  self.multipeerSession === activeSession.value else { return }
            self.handleReceivedData(data, from: peer.value)
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
            guard let self,
                  let id = self.rangingPeerIDsBySession[ObjectIdentifier(sendableSession.value)] else {
                return
            }
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
        Task { @MainActor [weak self] in
            self?.removeRangingObjects(for: sendableSession.value)
        }
    }

    nonisolated func sessionWasSuspended(_ session: NISession) {
        let sendableSession = SendableNearbySession(value: session)
        Task { @MainActor [weak self] in
            self?.suspendRanging(for: sendableSession.value)
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
            self?.resumeRanging(for: sendableSession.value)
        }
    }

    nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {
        let sendableSession = SendableNearbySession(value: session)
        let nsError = error as NSError
        let errorDescription = "\(nsError.domain)#\(nsError.code): \(nsError.localizedDescription)"
        Task { @MainActor [weak self] in
            self?.invalidateRanging(
                for: sendableSession.value,
                errorDescription: errorDescription
            )
        }
    }
}

extension RadarNearbyService: ARSessionDelegate {
    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        false
    }
}
