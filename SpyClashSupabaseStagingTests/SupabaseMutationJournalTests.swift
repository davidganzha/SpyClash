import XCTest
@testable import SpyClashSupabaseStaging

@MainActor
final class SupabaseMutationJournalTests: XCTestCase {
    private let actor = "44444444-4444-4444-8444-444444444444"
    private let other = "55555555-5555-4555-8555-555555555555"

    func testRestartRetryKeepsOriginalRequestIDAndAcknowledgementAllowsNewIntent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let body: [String: JSONValue] = ["service": .string("profile"), "action": .string("update"), "display_name": .string("Operative")]
        let original = try SupabaseAppMutationJournal(directory: directory).prepare(actorID: actor, body: body)
        let restarted = SupabaseAppMutationJournal(directory: directory)
        let replay = try restarted.prepare(actorID: actor, body: body)
        XCTAssertEqual(replay, original)
        try restarted.acknowledge(actorID: actor, requestID: original["request_id"]!.string!)
        let subsequent = try restarted.prepare(actorID: actor, body: body)
        XCTAssertNotEqual(subsequent["request_id"], original["request_id"])
    }

    func testPendingActionCannotBeReboundAndOtherAccountNeverInheritsIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SupabaseAppMutationJournal(directory: directory)
        let first: [String: JSONValue] = ["service": .string("community"), "action": .string("add_comment"), "comment": .string("First comment")]
        var changed = first; changed["comment"] = .string("Changed comment")
        let original = try journal.prepare(actorID: actor, body: first)
        XCTAssertThrowsError(try journal.prepare(actorID: actor, body: changed))
        let secondAccount = try journal.prepare(actorID: other, body: changed)
        XCTAssertNotEqual(secondAccount["request_id"], original["request_id"])
        XCTAssertEqual(try journal.prepare(actorID: actor, body: first), original)
    }

    func testReopenedGeneratorUsesSavedRequestInsteadOfNewViewUUID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var body = SupabaseGameAdapter.generationFields(theme: "Animals", count: 5, requestID: UUID(), excluding: ["cat"], preferFresh: false)
        body["service"] = .string("legacy"); body["action"] = .string("generate")
        let original = try SupabaseAppMutationJournal(directory: directory).prepare(actorID: actor, body: body)
        body["request_id"] = .string(UUID().uuidString.lowercased())
        let reopened = SupabaseAppMutationJournal(directory: directory)
        XCTAssertEqual(try reopened.prepare(actorID: actor, body: body), original)
        body["theme"] = .string("Cities")
        XCTAssertThrowsError(try reopened.prepare(actorID: actor, body: body))
    }

    func testLegacyCredentialNeverEntersDiskJournal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SupabaseAppMutationJournal(directory: directory)
        XCTAssertThrowsError(try journal.prepare(actorID: actor, body: ["service": .string("legacy"), "action": .string("link"), "base44_access_token": .string("secret-fixture")]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testAppStorePendingReaderKeepsExactIntentAndRejectsCorruptOrCredentialBearingStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SupabaseAppMutationJournal(directory: directory)
        let command = try journal.prepare(actorID: actor, body: ["service": .string("membership"), "action": .string("sync_transaction"), "signed_transaction": .string("synthetic-JWS-A")])
        XCTAssertEqual(try journal.pendingAppStoreTransaction(actorID: actor), command)
        XCTAssertNil(try journal.pendingAppStoreTransaction(actorID: other))
        let file = directory.appendingPathComponent(actor + ".json")
        let pristine = try Data(contentsOf: file)
        for key in ["base44_access_token", "access_token", "refresh_token"] {
            var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: pristine) as? [[String: Any]])
            var body = try XCTUnwrap(entries[0]["body"] as? [String: Any])
            body[key] = "must-not-replay"
            entries[0]["body"] = body
            try JSONSerialization.data(withJSONObject: entries).write(to: file)
            XCTAssertThrowsError(try journal.pendingAppStoreTransaction(actorID: actor))
        }
        try pristine.write(to: file)
        XCTAssertEqual(try journal.pendingAppStoreTransaction(actorID: actor), command)
    }
}
