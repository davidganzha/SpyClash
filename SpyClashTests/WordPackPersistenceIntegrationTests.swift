import Foundation
import XCTest
@testable import SpyClash

/// Exercises the native draft -> encoded HTTP payload -> decoded list -> reopened
/// draft boundary. The in-memory transport is not a backend or production test.
@MainActor
final class WordPackPersistenceIntegrationTests: XCTestCase {
    private func makeClient(store: WordPackFixtureStore) -> Base44Client {
        WordPackFixtureURLProtocol.handler = { try store.respond(to: $0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WordPackFixtureURLProtocol.self]
        let client = Base44Client(session: URLSession(configuration: configuration))
        client.setToken("word-pack-fixture-token")
        return client
    }

    func testManualCardsSaveOnlySelectedWordsAndReopenFromList() async throws {
        let store = WordPackFixtureStore()
        let client = makeClient(store: store)
        defer { WordPackFixtureURLProtocol.handler = nil }
        var draft = WordPackDraft(name: "  QA   Places ", wordsText: "Harbor, Museum; Airport\nHARBOR")
        draft.toggleWord("Museum")
        // This is the same draft operation invoked by Save for unsubmitted input.
        draft.addWords("Vault; Airport")
        XCTAssertTrue(draft.isValid)

        let saved = try await client.createWordPack(
            name: draft.normalizedName, category: draft.normalizedCategory,
            words: draft.selectedWords, ownerEmail: "fixture@example.invalid"
        )
        let listed = try await client.wordPacks(ownerEmail: "fixture@example.invalid")
        let reopened = WordPackDraft(pack: try XCTUnwrap(listed.first))
        XCTAssertEqual(saved.name, "QA Places")
        XCTAssertEqual(reopened.normalizedName, "QA Places")
        XCTAssertEqual(reopened.normalizedCategory, "QA Places")
        XCTAssertEqual(reopened.selectedWords, ["Harbor", "Airport", "Vault"])
        XCTAssertEqual(reopened.wordAnalysis.words, reopened.selectedWords)
        XCTAssertFalse(reopened.wordAnalysis.words.contains("Museum"))
        let writes = store.requests.filter { $0.action == "create" }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.words, ["Harbor", "Airport", "Vault"])
        XCTAssertEqual(writes.first?.accessToken, "word-pack-fixture-token")
        XCTAssertNil(writes.first?.packID)
        XCTAssertEqual(store.requests.map(\.action), ["create", "list"])
    }

    func testEditCardsCanRestoreAWordThenSaveAndReopenWithoutExcludedWords() async throws {
        let original = WordPack(
            id: "fixture-existing", name: "Places", category: "Travel",
            words: ["Harbor", "Museum", "Airport", "Vault"],
            ownerEmail: "fixture@example.invalid", isPublic: false
        )
        let store = WordPackFixtureStore(records: [original])
        let client = makeClient(store: store)
        defer { WordPackFixtureURLProtocol.handler = nil }
        let listed = try await client.wordPacks(ownerEmail: "fixture@example.invalid")
        let pack = try XCTUnwrap(listed.first)
        var draft = WordPackDraft(pack: pack)
        draft.toggleWord("Harbor")
        draft.toggleWord("Harbor")
        draft.toggleWord("Museum")
        draft.addWords("Embassy, VAULT")
        draft.name = "Edited Places"

        _ = try await client.updateWordPack(
            pack: pack, name: draft.normalizedName, category: draft.normalizedCategory,
            words: draft.selectedWords
        )
        let refreshed = try await client.wordPacks(ownerEmail: "fixture@example.invalid")
        let reopenedPack = try XCTUnwrap(refreshed.first)
        let reopened = WordPackDraft(pack: reopenedPack)
        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(reopenedPack.id, original.id)
        XCTAssertEqual(reopened.normalizedName, "Edited Places")
        XCTAssertEqual(reopened.selectedWords, ["Harbor", "Airport", "Vault", "Embassy"])
        XCTAssertEqual(reopened.wordAnalysis.words, reopened.selectedWords)
        XCTAssertEqual(store.requests.map(\.action), ["list", "update", "list"])
        XCTAssertEqual(store.requests[1].packID, original.id)
        XCTAssertEqual(store.requests[1].words, reopened.selectedWords)
    }

    func testGeneratedCardsPersistSelectionAndLargeSavedPackIsNotTruncated() async throws {
        let store = WordPackFixtureStore()
        let client = makeClient(store: store)
        defer { WordPackFixtureURLProtocol.handler = nil }
        var draft = WordPackDraft()
        draft.applyGenerated(
            GeneratedWordPack(category: "Places", words: (1...252).map { "Place \($0)" }),
            fallbackName: "QA Generated Places"
        )
        draft.toggleWord("Place 2")
        let expected = draft.selectedWords
        _ = try await client.createWordPack(
            name: draft.normalizedName, category: draft.normalizedCategory,
            words: expected, ownerEmail: "fixture@example.invalid"
        )
        let listed = try await client.wordPacks(ownerEmail: "fixture@example.invalid")
        let reopened = WordPackDraft(pack: try XCTUnwrap(listed.first))
        XCTAssertEqual(reopened.selectedWords, expected)
        XCTAssertEqual(reopened.selectedWords.count, 251)
        XCTAssertEqual(reopened.selectedWords.last, "Place 252")
        XCTAssertFalse(reopened.selectedWords.contains("Place 2"))
        let restoredCount = LocalWordPool.restoredCount(Double(expected.count), hasCustomTheme: false)
        XCTAssertEqual(LocalWordPool.playableWords(reopened.selectedWords, selectedCount: Int(restoredCount)), expected)
    }
}

private final class WordPackFixtureStore: @unchecked Sendable {
    struct Payload: Decodable {
        let action: String
        let accessToken: String
        let packID: String?
        let name: String?
        let category: String?
        let words: [String]?

        enum CodingKeys: String, CodingKey {
            case action, name, category, words
            case accessToken = "access_token"
            case packID = "pack_id"
        }
    }

    private let lock = NSLock()
    private var records: [String: WordPack]
    private var recordedRequests: [Payload] = []

    init(records: [WordPack] = []) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    var requests: [Payload] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func respond(to request: URLRequest) throws -> (HTTPURLResponse, Data) {
        // Every request is intercepted. Unexpected endpoints fail locally.
        guard let url = request.url, url.path.hasSuffix("/functions/wordPackAction"),
              request.httpMethod == "POST" else { throw URLError(.unsupportedURL) }
        let payload = try JSONDecoder().decode(Payload.self, from: Self.body(of: request))
        guard payload.accessToken == "word-pack-fixture-token" else { throw URLError(.userAuthenticationRequired) }
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(payload)
        let data: Data
        switch payload.action {
        case "list":
            data = try JSONEncoder().encode(records.values.sorted { $0.id < $1.id })
        case "create", "update":
            guard let name = payload.name, let words = payload.words,
                  !name.isEmpty, words.count >= 2 else { throw URLError(.badServerResponse) }
            let id: String
            if payload.action == "update" {
                guard let packID = payload.packID, records[packID] != nil else { throw URLError(.resourceUnavailable) }
                id = packID
            } else {
                id = "fixture-created-\(records.count + 1)"
            }
            // Deliberately store wire values verbatim: client normalization and
            // omitted/returned cards must be verified by test expectations.
            let pack = WordPack(
                id: id, name: name, category: payload.category, words: words,
                ownerEmail: "fixture@example.invalid", isPublic: false
            )
            records[id] = pack
            data = try JSONEncoder().encode(pack)
        default:
            throw URLError(.unsupportedURL)
        }
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"])!, data)
    }

    private static func body(of request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw URLError(.cannotDecodeContentData) }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let length = stream.read(buffer, maxLength: 4096)
            if length < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if length == 0 { break }
            data.append(buffer, count: length)
        }
        return data
    }
}

private final class WordPackFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
