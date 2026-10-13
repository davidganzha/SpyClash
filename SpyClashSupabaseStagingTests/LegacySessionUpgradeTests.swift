import XCTest
@testable import SpyClashSupabaseStaging

@MainActor
final class LegacySessionUpgradeTests: XCTestCase {
    private func response() throws -> LoginResponse {
        try JSONDecoder().decode(LoginResponse.self, from: Data(#"{"access_token":"new-session","user":{"id":"11111111-1111-4111-8111-111111111111","email":"11111111-1111-4111-8111-111111111111@example.test"}}"#.utf8))
    }

    func testUpgradeCommitsOnlyAfterVerifiedExchange() async throws {
        let verified = try response()
        var operations: [String] = []
        try await SupabaseLegacySessionUpgrade.restore(token: "old-base44-session", ownsAttempt: { true }, exchange: {
            XCTAssertEqual($0, "old-base44-session")
            operations.append("exchange")
            return verified
        }, commit: {
            XCTAssertEqual($0.accessToken, "new-session")
            operations.append("commit")
        })
        XCTAssertEqual(operations, ["exchange", "commit"])
    }

    func testLogoutDuringExchangeCannotInstallOldAccount() async throws {
        let verified = try response()
        var ownsAttempt = true
        var committed = false
        do {
            try await SupabaseLegacySessionUpgrade.restore(token: "old-base44-session", ownsAttempt: { ownsAttempt }, exchange: { _ in
                ownsAttempt = false
                return verified
            }, commit: { _ in committed = true })
            XCTFail("Superseded restore must be cancelled")
        } catch is CancellationError { }
        XCTAssertFalse(committed)
    }

    func testUnavailableImportLeavesOriginalCredentialUntouched() async throws {
        var stored = "old-base44-session"
        do {
            try await SupabaseLegacySessionUpgrade.restore(token: stored, ownsAttempt: { true }, exchange: { _ in
                throw Base44Error(message: "Pending import", statusCode: 503, code: "legacy_import_pending")
            }, commit: { stored = $0.accessToken })
            XCTFail("A partial import must not install credentials")
        } catch let error as Base44Error { XCTAssertEqual(error.code, "legacy_import_pending") }
        XCTAssertEqual(stored, "old-base44-session")
    }

    func testLogoutDuringCommitPreventsRestoreFromPublishingAUser() async throws {
        let verified = try response()
        var ownsAttempt = true
        do {
            try await SupabaseLegacySessionUpgrade.restore(token: "old-base44-session", ownsAttempt: { ownsAttempt }, exchange: { _ in verified }, commit: { _ in
                ownsAttempt = false
            })
            XCTFail("Restore must not continue after logout")
        } catch is CancellationError { }
    }
}
