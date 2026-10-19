#!/usr/bin/env python3
"""Compile and exercise the actual Radar invitation methods on the macOS host.

No Simulator, device, network, or production service is used. The declarations
under test are extracted from RadarNearbyService.swift on every invocation.
Only model/framework boundaries are stubbed; dispatch means the production
method called enqueueInvitation, not that a remote phone accepted a connection.
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import shutil
import subprocess
import tempfile


DECLARATIONS = (
    "enum RadarRoomInviteDeliveryAction:",
    "struct RadarRoomInviteDelivery {",
    "enum RadarInviteDispatchResult:",
    "enum RadarOutgoingInvitationState:",
    "final class RadarFrameworkExecutor:",
    "final class RadarFrameworkLifetime:",
)
METHODS = (
    "private func invite(_ peer:",
    "private func beginDirectRoomInviteConnection(",
    "private func scheduleInvitationTimeout(",
    "private func cancelInvitation(",
    "private func markInvitationUnavailable(",
    "private func encoded(_ message:",
)


def declaration(source: str, marker: str) -> str:
    """Return one balanced Swift declaration, ignoring comments/strings."""
    if source.count(marker) != 1:
        raise ValueError(f"Expected one declaration for {marker!r}")
    start = source.index(marker)
    previous_line_start = source.rfind("\n", 0, source.rfind("\n", 0, start)) + 1
    if source[previous_line_start:start].strip() == "@discardableResult":
        start = previous_line_start
    opening = source.index("{", start)
    depth, index, block_depth = 1, opening + 1, 0
    in_string = False
    while index < len(source):
        pair = source[index : index + 2]
        character = source[index]
        if block_depth:
            if pair == "/*":
                block_depth += 1
                index += 2
            elif pair == "*/":
                block_depth -= 1
                index += 2
            else:
                index += 1
            continue
        if in_string:
            if character == "\\":
                index += 2
            elif character == '"':
                in_string = False
                index += 1
            else:
                index += 1
            continue
        if pair == "//":
            newline = source.find("\n", index)
            index = len(source) if newline < 0 else newline + 1
            continue
        if pair == "/*":
            block_depth = 1
            index += 2
            continue
        if character == '"':
            in_string = True
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
        index += 1
    raise ValueError(f"Unbalanced declaration: {marker}")


BOUNDARIES = r'''
import Foundation

enum RadarInvitePolicy { case ask, automatic, blocked }
enum RadarPlayerAvailability { case available, inGame }
struct RadarNearbyPeer {
    let id: String
    var invitePolicy: RadarInvitePolicy = .ask
    var availability: RadarPlayerAvailability = .available
}
struct GameRoom { let code: String }
struct MCPeerID: Hashable, Sendable { let displayName: String }
@MainActor final class MCSession { var connectedPeers: [MCPeerID] = [] }
@MainActor final class MCNearbyServiceBrowser {}
struct LocalIdentity {
    let callSign = "Host", avatar = "S", spyID = "123-456"
    let spyCardTheme = "field", spyCardAccent = "red", spyCardBadge = "operative"
    let rating = 100, gamesPlayed = 8, winRate = 50
}
struct RadarWireMessage: Codable {
    let invitationID: String?
    let code: String?
    static func roomInvite(
        invitationID: String, code: String, hostCallSign: String, hostAvatar: String,
        hostSpyID: String, hostSpyCardTheme: String, hostSpyCardAccent: String,
        hostSpyCardBadge: String, hostRating: Int, hostGamesPlayed: Int, hostWinRate: Int
    ) -> Self { Self(invitationID: invitationID, code: code) }
    static func roomInviteCancellation(invitationID: String) -> Self {
        Self(invitationID: invitationID, code: nil)
    }
}
struct DispatchRecord {
    let invitationID: String?
    let timeout: TimeInterval
    let deadline: ContinuousClock.Instant?
    let lifetimeWasActive: Bool
}

@MainActor final class HarnessService {
    var multipeerSession: MCSession? = MCSession()
    var browser: MCNearbyServiceBrowser? = MCNearbyServiceBrowser()
    var identity: LocalIdentity? = LocalIdentity()
    var discoveredPeerIDs: [String: MCPeerID] = [:]
    var pendingInvitationIDs: [String: String] = [:]
    var pendingRoomInvites: [String: RadarWireMessage] = [:]
    var outgoingInvitationStates: [String: RadarOutgoingInvitationState] = [:]
    var roomInviteConnectionAttempts: [String: String] = [:]
    var roomInviteDeliveries: [String: RadarRoomInviteDelivery] = [:]
    var roomInvitationLifetimes: [String: RadarFrameworkLifetime] = [:]
    var invitationTimeoutRunIDs: [String: UUID] = [:]
    var invitationDeadlines: [String: ContinuousClock.Instant] = [:]
    var presenceInviteAttempts: [String: UUID] = [:]
    var rangingInviteAttempts: [String: UUID] = [:]
    var connectingPeerIDs: Set<String> = []
    let frameworkExecutor = RadarFrameworkExecutor()
    let transportLifetime = RadarFrameworkLifetime()
    var dispatches: [DispatchRecord] = []
    var reliableSends: [RadarWireMessage] = []
    var sendHadDeadline: [Bool] = []
    var sendSucceeds = true
    var hasSessionCapacity = true

    func send(_ message: RadarWireMessage, to peerID: MCPeerID) async -> Bool {
        reliableSends.append(message)
        sendHadDeadline.append(invitationDeadlines[peerID.displayName] != nil
            && invitationTimeoutRunIDs[peerID.displayName] != nil)
        return sendSucceeds
    }
    func enqueueInvitation(
        to peerID: MCPeerID, browser: MCNearbyServiceBrowser, session: MCSession,
        context: Data, timeout: TimeInterval,
        invitationLifetime: RadarFrameworkLifetime? = nil,
        deadline: ContinuousClock.Instant? = nil
    ) {
        let message = try! JSONDecoder().decode(RadarWireMessage.self, from: context)
        dispatches.append(DispatchRecord(
            invitationID: message.invitationID, timeout: timeout, deadline: deadline,
            lifetimeWasActive: invitationLifetime?.isActive == true
        ))
    }
    func hasAvailableRemoteSessionSlot(for id: String) -> Bool { hasSessionCapacity }
    func debugLog(_ message: @autoclosure () -> String) {}
    func clearStaleConnectingStateIfNeeded(for id: String) {}
    @discardableResult
    func removePeerIfNoLongerReachable(
        _ id: String, ignoringStaleConnectingState: Bool = false
    ) -> Bool { false }
    func clearOrAdvanceInvitationState(
        _ state: RadarOutgoingInvitationState, for id: String, after delay: Duration
    ) {}
    func deliverInvitationCancellation(_ message: RadarWireMessage, to peer: MCPeerID) async {}

    func tap(_ peer: RadarNearbyPeer) async -> RadarInviteDispatchResult {
        await invite(peer, to: GameRoom(code: "abc123"))
    }
    @discardableResult
    func staleConnectionCallback(_ message: RadarWireMessage, peer: MCPeerID) -> Bool {
        beginDirectRoomInviteConnection(message, to: peer)
    }
    func cancel(_ id: String) { cancelInvitation(for: id) }
    func repeatTimeout(_ id: String, invitationID: String) {
        scheduleInvitationTimeout(for: id, invitationID: invitationID)
    }
'''


TESTS = r'''
}

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): message }
    }
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}

@main struct RunChecks {
    @MainActor static func main() async {
        do {
            try await runChecks()
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    @MainActor static func runChecks() async throws {
        let peer = MCPeerID(displayName: "peer-a")
        let card = RadarNearbyPeer(id: peer.displayName)
        var directDispatchCases = 0
        var staleCallbacks = 0
        var cancellationCases = 0

        for mask in 0..<8 {
            let service = HarnessService()
            service.discoveredPeerIDs[peer.displayName] = peer
            if mask & 1 != 0 { service.presenceInviteAttempts[peer.displayName] = UUID() }
            if mask & 2 != 0 { service.rangingInviteAttempts[peer.displayName] = UUID() }
            if mask & 4 != 0 { service.connectingPeerIDs.insert(peer.displayName) }

            let result = await service.tap(card)
            // No yield, sleep, callback or watchdog is allowed before these checks.
            try expect(result == .sent, "mask \(mask): tap result")
            try expect(service.dispatches.count == 1, "mask \(mask): first call did not dispatch")
            try expect(service.reliableSends.isEmpty, "mask \(mask): disconnected fast path")
            let invitationID = service.pendingInvitationIDs[peer.displayName]!
            let message = service.pendingRoomInvites[peer.displayName]!
            let timeoutID = service.invitationTimeoutRunIDs[peer.displayName]!
            let deadline = service.invitationDeadlines[peer.displayName]!
            try expect(message.invitationID == invitationID, "mask \(mask): retained message ID")
            directDispatchCases += 1

            for _ in 0..<20 {
                try expect(service.staleConnectionCallback(message, peer: peer), "mask \(mask): callback")
                service.repeatTimeout(peer.displayName, invitationID: invitationID)
                staleCallbacks += 1
            }
            try expect(service.dispatches.count == 2, "mask \(mask): expected initial + one retry only")
            try expect(service.roomInviteDeliveries[peer.displayName]?.directAttemptCount == 2,
                       "mask \(mask): retry budget")
            try expect(service.dispatches.allSatisfy { $0.invitationID == invitationID },
                       "mask \(mask): ID changed across context retries")
            try expect(service.dispatches.allSatisfy { $0.lifetimeWasActive },
                       "mask \(mask): cancelled lifetime dispatched")
            try expect(service.dispatches.allSatisfy { $0.timeout > 0 && $0.timeout <= 15 },
                       "mask \(mask): framework timeout bounds")
            try expect(service.dispatches.allSatisfy { $0.deadline == deadline },
                       "mask \(mask): framework deadline changed")
            try expect(service.invitationTimeoutRunIDs[peer.displayName] == timeoutID,
                       "mask \(mask): retry extended response timer")
            try expect(service.invitationDeadlines[peer.displayName] == deadline,
                       "mask \(mask): retry extended absolute deadline")

            service.multipeerSession!.connectedPeers = [peer]
            try expect(service.staleConnectionCallback(message, peer: peer), "mask \(mask): connected callback")
            for _ in 0..<200 where service.reliableSends.isEmpty {
                try await Task.sleep(for: .milliseconds(1))
            }
            try expect(service.reliableSends.count == 1, "mask \(mask): connected delivery never ran")
            try expect(service.reliableSends[0].invitationID == invitationID,
                       "mask \(mask): connected delivery changed ID")
            try expect(service.invitationTimeoutRunIDs[peer.displayName] == timeoutID,
                       "mask \(mask): connection extended response timer")
            try expect(service.invitationDeadlines[peer.displayName] == deadline,
                       "mask \(mask): connection extended absolute deadline")

            let oldLifetime = service.roomInvitationLifetimes[peer.displayName]!
            service.cancel(peer.displayName)
            try expect(!oldLifetime.isActive, "mask \(mask): cancellation left lifetime active")
            let priorDispatches = service.dispatches.count
            for _ in 0..<20 {
                try expect(!service.staleConnectionCallback(message, peer: peer),
                           "mask \(mask): cancelled ID admitted")
            }
            try expect(service.dispatches.count == priorDispatches, "mask \(mask): cancelled ID dispatched")

            service.multipeerSession!.connectedPeers = []
            let newResult = await service.tap(card)
            try expect(newResult == .sent, "mask \(mask): replacement tap")
            try expect(service.pendingInvitationIDs[peer.displayName] != invitationID,
                       "mask \(mask): new user tap reused cancelled ID")
            try expect(service.invitationTimeoutRunIDs[peer.displayName] != timeoutID,
                       "mask \(mask): new user tap has no fresh timer")
            try expect(service.dispatches.count == priorDispatches + 1,
                       "mask \(mask): new user tap did not reset delivery budget")
            try expect(!service.staleConnectionCallback(message, peer: peer),
                       "mask \(mask): replaced ID admitted")
            service.cancel(peer.displayName)
            cancellationCases += 1
        }

        let failedFastSend = HarnessService()
        failedFastSend.discoveredPeerIDs[peer.displayName] = peer
        failedFastSend.multipeerSession!.connectedPeers = [peer]
        failedFastSend.sendSucceeds = false
        let failedFastResult = await failedFastSend.tap(card)
        try expect(failedFastResult == .sent, "failed connected send did not fall back")
        try expect(failedFastSend.reliableSends.count == 1, "connected send attempt missing")
        try expect(failedFastSend.dispatches.count == 1, "fallback required a later callback")
        try expect(failedFastSend.dispatches[0].invitationID == failedFastSend.reliableSends[0].invitationID,
                   "failed connected fallback changed invitation ID")
        try expect(failedFastSend.sendHadDeadline == [true],
                   "response deadline was created after the initial connected send")
        failedFastSend.cancel(peer.displayName)

        let connectedSuccess = HarnessService()
        connectedSuccess.discoveredPeerIDs[peer.displayName] = peer
        connectedSuccess.multipeerSession!.connectedPeers = [peer]
        let connectedResult = await connectedSuccess.tap(card)
        try expect(connectedResult == .sent && connectedSuccess.reliableSends.count == 1,
                   "connected success path did not send exactly once")
        try expect(connectedSuccess.dispatches.isEmpty, "connected success unnecessarily invited again")
        try expect(connectedSuccess.sendHadDeadline == [true],
                   "connected success send had no original response deadline")
        connectedSuccess.cancel(peer.displayName)

        let shortened = HarnessService()
        shortened.discoveredPeerIDs[peer.displayName] = peer
        _ = await shortened.tap(card)
        let shortenedMessage = shortened.pendingRoomInvites[peer.displayName]!
        let shortenedTimeoutID = shortened.invitationTimeoutRunIDs[peer.displayName]!
        let soon = ContinuousClock.now.advanced(by: .seconds(2))
        shortened.invitationDeadlines[peer.displayName] = soon
        try expect(shortened.staleConnectionCallback(shortenedMessage, peer: peer),
                   "retry with remaining budget was rejected")
        try expect(shortened.dispatches.count == 2 && shortened.dispatches[1].timeout <= 2,
                   "retry did not respect remaining 2-second budget")
        try expect(shortened.dispatches[1].deadline == soon
            && shortened.invitationTimeoutRunIDs[peer.displayName] == shortenedTimeoutID,
                   "shortened budget restarted the original response timer")
        shortened.cancel(peer.displayName)

        let expired = HarnessService()
        expired.discoveredPeerIDs[peer.displayName] = peer
        _ = await expired.tap(card)
        let expiredMessage = expired.pendingRoomInvites[peer.displayName]!
        expired.invitationDeadlines[peer.displayName] = ContinuousClock.now.advanced(by: .seconds(-1))
        let admittedExpired = expired.staleConnectionCallback(expiredMessage, peer: peer)
        try expect(!admittedExpired, "expired deadline admitted a direct retry")
        try expect(expired.dispatches.count == 1, "expired deadline dispatched a retry")

        print("PASS: \(directDispatchCases)/8 background-handshake combinations dispatch during the tap call")
        print("PASS: \(staleCallbacks) stale callbacks retain one initial + one retry maximum, same invitation ID")
        print("PASS: retries and connected callbacks preserve the original timer ID and absolute deadline")
        print("PASS: \(cancellationCases)/8 real cancellation + replacement cases reject old IDs")
        print("PASS: failed connected send immediately falls back using the same invitation ID")
        print("PASS: connected success and failure both establish the deadline before sending")
        print("PASS: a retry with 2 seconds remaining receives at most 2 seconds framework timeout")
        print("PASS: expired absolute deadline cannot dispatch a retry")
        print("Boundary: actual invitation methods; stubbed MC/network/model edges; no Simulator or phone timing")
    }
}
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    root = pathlib.Path(__file__).resolve().parents[2]
    parser.add_argument("--source", type=pathlib.Path,
                        default=root / "SpyClash/Services/RadarNearbyService.swift")
    args = parser.parse_args()
    source = args.source.read_text()
    declarations = [declaration(source, marker) for marker in DECLARATIONS]
    methods = [declaration(source, marker) for marker in METHODS]
    swift = "import Foundation\n\n" + "\n\n".join(declarations) + "\n" + BOUNDARIES
    swift += "\n\n".join(methods) + "\n" + TESTS
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        raise SystemExit("swiftc is required; this check runs on the macOS host.")
    print(f"Source: {args.source.resolve()}", flush=True)
    print(f"SHA256: {hashlib.sha256(source.encode()).hexdigest()}", flush=True)
    print(f"Extracted {len(declarations)} declarations and {len(methods)} production methods", flush=True)
    with tempfile.TemporaryDirectory(prefix="spyclash-radar-dispatch-") as directory:
        temporary = pathlib.Path(directory)
        harness = temporary / "main.swift"
        binary = temporary / "check-dispatch"
        harness.write_text(swift)
        subprocess.run([swiftc, "-swift-version", "6", "-parse-as-library",
                        str(harness), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == "__main__":
    main()
