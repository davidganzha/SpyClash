import XCTest
import UIKit
@testable import SpyClashGameCenter

@MainActor
final class GameCenterAuthenticationTests: XCTestCase {
    func testDuplicateAuthenticationCallbacksFetchOneProofAndCompleteOnce() async throws {
        let player = TestGameCenterPlayer()
        let authentication = makeAuthentication(player)
        let task = Task { try await authentication.authenticate() }
        await waitForInitialization(player)
        player.emitAuthenticated()
        player.emitAuthenticated()
        XCTAssertEqual(player.proofRequests.count, 1)
        let proofCallback = try XCTUnwrap(player.proofRequests.first)
        proofCallback(URL(string: "https://static.gc.apple.com/public-key/test.cer"), Data([1, 2]), Data([3, 4]), 123, nil)
        // GameKit is allowed to invoke its callbacks repeatedly. A repeated
        // signature callback must not resume the continuation a second time.
        proofCallback(URL(string: "https://static.gc.apple.com/public-key/test.cer"), Data([1]), Data([3]), 124, nil)
        let proof = try await task.value
        XCTAssertEqual(proof.teamPlayerID, "team-player-one")
        XCTAssertEqual(proof.bundleID, "com.spyclash.ios.gamecenter000")
        XCTAssertEqual(proof.timestamp, 123)
        XCTAssertEqual(player.stops, 1)
    }

    func testCancelledAttemptCannotCompleteNewAttempt() async throws {
        let player = TestGameCenterPlayer()
        let authentication = makeAuthentication(player)
        let oldTask = Task { try await authentication.authenticate() }
        await waitForInitialization(player)
        let oldCallback = try XCTUnwrap(player.handlers.first)
        player.emitAuthenticated()
        let oldProofCallback = try XCTUnwrap(player.proofRequests.first)
        authentication.cancel()
        do { _ = try await oldTask.value; XCTFail("Cancellation must finish the old attempt") }
        catch { XCTAssertTrue(error is CancellationError) }

        let nextTask = Task { try await authentication.authenticate() }
        await waitForInitialization(player, count: 2)
        oldCallback(nil, nil)
        oldProofCallback(URL(string: "https://static.gc.apple.com/public-key/test.cer"), Data([1]), Data([2]), 123, nil)
        XCTAssertEqual(player.proofRequests.count, 1)
        player.emitAuthenticated()
        XCTAssertEqual(player.proofRequests.count, 2)
        player.completeProof(timestamp: 456)
        let next = try await nextTask.value
        XCTAssertEqual(next.timestamp, 456)
    }

    func testIdentityChangeWhileFetchingProofIsRejected() async throws {
        let player = TestGameCenterPlayer()
        let authentication = makeAuthentication(player)
        let task = Task { try await authentication.authenticate() }
        await waitForInitialization(player)
        player.emitAuthenticated()
        player.teamPlayerID = "a-different-player"
        player.completeProof()
        do { _ = try await task.value; XCTFail("An account switch must not be accepted") }
        catch { XCTAssertEqual(error as? GameCenterAuthenticationError, .invalidProof) }
    }

    func testUnconfiguredPlayerFallsBackWithoutRequestingProof() async {
        let player = TestGameCenterPlayer()
        player.isAuthenticated = false
        let authentication = makeAuthentication(player)
        let task = Task { try await authentication.authenticate() }
        await waitForInitialization(player)
        player.handlers.last?(nil, nil)
        do { _ = try await task.value; XCTFail("An unauthenticated Game Center player is not an account") }
        catch { XCTAssertEqual(error as? GameCenterAuthenticationError, .unavailable) }
        XCTAssertTrue(player.proofRequests.isEmpty)
    }

    func testSystemPromptPresentationFailureFinishesAttempt() async {
        let player = TestGameCenterPlayer()
        let authentication = makeAuthentication(player, presenter: { _ in false })
        let task = Task { try await authentication.authenticate() }
        await waitForInitialization(player)
        player.handlers.last?(UIViewController(), nil)
        do { _ = try await task.value; XCTFail("An unpresentable prompt must fall back") }
        catch { XCTAssertEqual(error as? GameCenterAuthenticationError, .presentationUnavailable) }
        XCTAssertEqual(player.stops, 1)
    }

    func testMissingSignatureCannotProduceIdentity() async {
        let player = TestGameCenterPlayer()
        let authentication = makeAuthentication(player)
        let task = Task { try await authentication.authenticate() }
        await waitForInitialization(player)
        player.emitAuthenticated()
        player.proofRequests.last?(URL(string: "https://static.gc.apple.com/public-key/test.cer"), Data(), Data([1]), 1, nil)
        do { _ = try await task.value; XCTFail("An empty signature must be rejected") }
        catch { XCTAssertEqual(error as? GameCenterAuthenticationError, .invalidProof) }
    }

    func testStalledGameKitIsBounded() async {
        let player = TestGameCenterPlayer()
        let authentication = GameCenterAuthentication(player: player, bundleID: "com.spyclash.ios.gamecenter000", timeout: .milliseconds(1), presenter: { _ in true })
        do { _ = try await authentication.authenticate(); XCTFail("A stalled callback must time out") }
        catch { XCTAssertEqual(error as? GameCenterAuthenticationError, .timedOut) }
        XCTAssertEqual(player.stops, 1)
    }

    func testTaskCancellationRemovesPlayerHandler() async {
        let player = TestGameCenterPlayer()
        let authentication = makeAuthentication(player)
        let task = Task { try await authentication.authenticate() }
        await waitForInitialization(player)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled task must not remain suspended") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(player.stops, 1)
    }

    func testProofUsesServerContractFieldNames() throws {
        let proof = GameCenterIdentityProof(teamPlayerID: "player", bundleID: "com.spyclash.ios.gamecenter000", publicKeyURL: "https://static.gc.apple.com/key", signature: "AQ==", salt: "Ag==", timestamp: 123, displayName: "Agent")
        let encoded = try JSONEncoder().encode(proof)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["team_player_id", "bundle_id", "public_key_url", "signature", "salt", "timestamp", "display_name"]))
        XCTAssertEqual(object["timestamp"] as? UInt64, 123)
        XCTAssertEqual(try JSONDecoder().decode(GameCenterIdentityProof.self, from: encoded), proof)
    }

    private func makeAuthentication(_ player: TestGameCenterPlayer, presenter: @escaping @MainActor (UIViewController) -> Bool = { _ in true }) -> GameCenterAuthentication {
        GameCenterAuthentication(player: player, bundleID: "com.spyclash.ios.gamecenter000", timeout: .seconds(3), presenter: presenter)
    }

    private func waitForInitialization(_ player: TestGameCenterPlayer, count: Int = 1) async {
        for _ in 0..<100 {
            if player.handlers.count >= count { return }
            await Task.yield()
        }
        XCTFail("Authentication did not start")
    }
}

@MainActor
private final class TestGameCenterPlayer: GameCenterPlayerClient {
    var isAuthenticated = true
    var teamPlayerID = "team-player-one"
    var displayName = "Operative"
    var handlers: [@MainActor (UIViewController?, Error?) -> Void] = []
    var proofRequests: [@MainActor (URL?, Data?, Data?, UInt64, Error?) -> Void] = []
    var stops = 0

    func initialize(handler: @escaping @MainActor (UIViewController?, Error?) -> Void) { handlers.append(handler) }
    func fetchIdentity(handler: @escaping @MainActor (URL?, Data?, Data?, UInt64, Error?) -> Void) { proofRequests.append(handler) }
    func stop() { stops += 1 }
    func emitAuthenticated() { handlers.last?(nil, nil) }
    func completeProof(timestamp: UInt64 = 123) {
        proofRequests.last?(URL(string: "https://static.gc.apple.com/public-key/test.cer"), Data([1]), Data([2]), timestamp, nil)
    }
}
