import XCTest
#if SPYCLASH_SUPABASE_STAGING_TESTS
@testable import SpyClashSupabaseStaging
#else
@testable import SpyClash
#endif

@MainActor
final class CommunityDirectoryLoadingTests: XCTestCase {
    func testRepeatedVisibilitySignalsLoadEachPageOnlyOnce() async throws {
        let client = DirectoryClientStub()
        let loader = CommunityDirectoryLoader(loadPage: client.load)
        loader.configure(actorID: "alice", query: "")
        let initial = Task { await loader.loadInitial() }
        try await waitForCalls(1, client: client)
        await loader.loadInitial()
        await loader.loadMore()
        XCTAssertEqual(client.calls, [.init(query: "", offset: 0, limit: 24)])
        client.succeed(0, profiles: [profile("one")], nextOffset: 24)
        await initial.value

        let more = Task { await loader.loadMore() }
        try await waitForCalls(2, client: client)
        await loader.loadMore()
        await loader.loadInitial(force: true)
        XCTAssertEqual(client.calls.count, 2)
        XCTAssertEqual(client.calls[1].offset, 24)
        client.succeed(1, profiles: [profile("two")], nextOffset: nil)
        await more.value
        await loader.loadMore()
        XCTAssertEqual(loader.profiles.map(\.id), ["one", "two"])
        XCTAssertNil(loader.nextOffset)
        XCTAssertEqual(client.calls.count, 2)
    }

    func testChangedQueryRejectsOldResultEvenWhenTransportIgnoresCancellation() async throws {
        let client = DirectoryClientStub()
        let loader = CommunityDirectoryLoader(loadPage: client.load)
        loader.configure(actorID: "alice", query: "old")
        let old = Task { await loader.loadInitial() }
        try await waitForCalls(1, client: client)
        loader.configure(actorID: "alice", query: "new")
        let current = Task { await loader.loadInitial() }
        try await waitForCalls(2, client: client)
        client.succeed(0, profiles: [profile("old")], nextOffset: 24)
        await old.value
        XCTAssertTrue(loader.profiles.isEmpty)
        XCTAssertTrue(loader.isLoading, "An old completion cannot clear the new request's loading state.")
        client.succeed(1, profiles: [profile("new")], nextOffset: nil)
        await current.value
        XCTAssertEqual(loader.profiles.map(\.id), ["new"])
        XCTAssertNil(loader.failedOffset)
    }

    func testChangedQueryRejectsStaleFailureAndClearsOldPaginationImmediately() async throws {
        let client = DirectoryClientStub()
        let loader = CommunityDirectoryLoader(loadPage: client.load)
        loader.configure(actorID: "alice", query: "old")
        loader.seed([profile("old")], nextOffset: 24)
        let old = Task { await loader.loadMore() }
        try await waitForCalls(1, client: client)
        loader.configure(actorID: "alice", query: "new")
        XCTAssertTrue(loader.profiles.isEmpty)
        XCTAssertNil(loader.nextOffset)
        XCTAssertFalse(loader.hasLoaded)
        client.fail(0)
        await old.value
        XCTAssertNil(loader.errorMessage)
        XCTAssertNil(loader.failedOffset)
        XCTAssertFalse(loader.isLoading)
    }

    func testAccountSwitchClearsCacheAndRejectsPreviousAccountResponse() async throws {
        let client = DirectoryClientStub()
        let loader = CommunityDirectoryLoader(loadPage: client.load)
        loader.configure(actorID: "alice", query: "")
        loader.seed([profile("alice-only")], nextOffset: 24)
        let old = Task { await loader.loadMore() }
        try await waitForCalls(1, client: client)
        loader.configure(actorID: "bob", query: "")
        XCTAssertTrue(loader.profiles.isEmpty)
        client.succeed(0, profiles: [profile("alice-next")], nextOffset: 48)
        await old.value
        XCTAssertTrue(loader.profiles.isEmpty)
        loader.seed([profile("bob-only")])
        loader.configure(actorID: "alice", query: "")
        XCTAssertTrue(loader.profiles.isEmpty, "Switching back cannot resurrect a previous account's cached directory.")
        XCTAssertFalse(loader.hasLoaded)
    }

    func testSuspendCancelsAndResumeCanLoadBeforeOldTransportUnwinds() async throws {
        let client = DirectoryClientStub()
        let loader = CommunityDirectoryLoader(loadPage: client.load)
        loader.configure(actorID: "alice", query: "")
        loader.seed([profile("one")], nextOffset: 24)
        let old = Task { await loader.loadMore() }
        try await waitForCalls(1, client: client)
        loader.suspend()
        XCTAssertFalse(loader.isLoading)
        await loader.loadMore()
        XCTAssertEqual(client.calls.count, 1)
        loader.resume()
        let current = Task { await loader.loadMore() }
        try await waitForCalls(2, client: client)
        client.succeed(0, profiles: [profile("stale")], nextOffset: 48)
        await old.value
        XCTAssertEqual(loader.profiles.map(\.id), ["one"])
        XCTAssertTrue(loader.isLoading)
        client.succeed(1, profiles: [profile("two")], nextOffset: nil)
        await current.value
        XCTAssertEqual(loader.profiles.map(\.id), ["one", "two"])
        XCTAssertNil(loader.failedOffset)
    }

    func testCancelledInitialViewTaskLeavesFirstPageRetryable() async throws {
        let client = DirectoryClientStub()
        let loader = CommunityDirectoryLoader(loadPage: client.load)
        loader.configure(actorID: "alice", query: "")
        let first = Task { await loader.loadInitial() }
        try await waitForCalls(1, client: client)
        first.cancel()
        for _ in 0..<1_000 where loader.isLoading { await Task.yield() }
        XCTAssertFalse(loader.isLoading)
        XCTAssertFalse(loader.hasLoaded)
        XCTAssertNil(loader.failedOffset)
        let next = Task { await loader.loadInitial() }
        try await waitForCalls(2, client: client)
        client.succeed(0, profiles: [profile("stale")], nextOffset: nil)
        await first.value
        XCTAssertTrue(loader.isLoading)
        client.succeed(1, profiles: [profile("fresh")], nextOffset: nil)
        await next.value
        XCTAssertEqual(loader.profiles.map(\.id), ["fresh"])
    }

    func testFailureKeepsRowsStopsAutomaticRequestsAndRetryUsesSameOffset() async throws {
        let client = DirectoryClientStub()
        let loader = CommunityDirectoryLoader(loadPage: client.load)
        loader.configure(actorID: "alice", query: "")
        loader.seed([profile("one")], nextOffset: 24)
        let next = Task { await loader.loadMore() }
        try await waitForCalls(1, client: client)
        client.fail(0)
        await next.value
        XCTAssertEqual(loader.failedOffset, 24)
        XCTAssertEqual(loader.profiles.map(\.id), ["one"])
        await loader.loadMore()
        await loader.loadInitial()
        XCTAssertEqual(client.calls.count, 1)
        let retry = Task { await loader.retry() }
        try await waitForCalls(2, client: client)
        XCTAssertEqual(client.calls[1].offset, 24)
        client.succeed(1, profiles: [profile("two")], nextOffset: nil)
        await retry.value
        XCTAssertNil(loader.failedOffset)
        XCTAssertNil(loader.errorMessage)
        XCTAssertEqual(loader.profiles.map(\.id), ["one", "two"])
    }

    func testFailedInitialPageDoesNotCreateAnAutomaticRetryLoop() async throws {
        let client = DirectoryClientStub()
        let loader = CommunityDirectoryLoader(loadPage: client.load)
        loader.configure(actorID: "alice", query: "")
        let first = Task { await loader.loadInitial() }
        try await waitForCalls(1, client: client)
        client.fail(0)
        await first.value
        XCTAssertEqual(loader.failedOffset, 0)
        XCTAssertFalse(loader.hasLoaded)
        await loader.loadInitial()
        XCTAssertEqual(client.calls.count, 1)
        let retry = Task { await loader.retry() }
        try await waitForCalls(2, client: client)
        client.succeed(1, profiles: [], nextOffset: nil)
        await retry.value
        XCTAssertTrue(loader.hasLoaded)
        XCTAssertTrue(loader.profiles.isEmpty)
    }

    func testPagesDeduplicateInternallyAndReplaceEarlierSummaryWithoutReordering() async {
        var calls = 0
        let loader = CommunityDirectoryLoader(loadPage: { _, offset, _ in
            calls += 1
            if offset == 0 {
                return CommunityDirectoryPage(profiles: [self.profile("one"), self.profile("one", name: "new one")], nextOffset: 24)
            }
            return CommunityDirectoryPage(profiles: [self.profile("one", name: "latest one"), self.profile("two"), self.profile("two")], nextOffset: 48)
        })
        loader.configure(actorID: "alice", query: "")
        await loader.loadInitial()
        XCTAssertEqual(loader.profiles.map(\.displayName), ["new one"])
        await loader.loadMore()
        XCTAssertEqual(loader.profiles.map(\.id), ["one", "two"])
        XCTAssertEqual(loader.profiles.first?.displayName, "latest one")
        XCTAssertEqual(calls, 2)
    }

    func testNonAdvancingCursorStopsButEmptyAdvancingPageCanContinue() async {
        var calls = 0
        let loader = CommunityDirectoryLoader(loadPage: { _, offset, _ in
            calls += 1
            return CommunityDirectoryPage(profiles: [], nextOffset: offset == 0 ? 24 : 24)
        })
        loader.configure(actorID: "alice", query: "")
        await loader.loadInitial()
        XCTAssertEqual(loader.nextOffset, 24)
        await loader.loadMore()
        XCTAssertNil(loader.nextOffset)
        await loader.loadMore()
        XCTAssertEqual(calls, 2)
        loader.configure(actorID: "alice", query: "backwards", loadPage: { _, _, _ in
            CommunityDirectoryPage(profiles: [], nextOffset: -1)
        })
        await loader.loadInitial()
        XCTAssertNil(loader.nextOffset)
    }

    func testFreshQueryCacheRestoresContinuationAndExpiredCacheReloads() async {
        var date = Date(timeIntervalSince1970: 1_000)
        var calls: [String] = []
        let loader = CommunityDirectoryLoader(loadPage: { query, _, _ in
            calls.append(query)
            return CommunityDirectoryPage(profiles: [self.profile(query)], nextOffset: 24)
        }, now: { date })
        loader.configure(actorID: "alice", query: "  first  ")
        await loader.loadInitial()
        loader.configure(actorID: "alice", query: "second")
        await loader.loadInitial()
        loader.configure(actorID: "alice", query: "first")
        await loader.loadInitial()
        XCTAssertEqual(calls, ["first", "second"])
        XCTAssertEqual(loader.nextOffset, 24)
        date.addTimeInterval(61)
        loader.configure(actorID: "alice", query: "second")
        XCTAssertFalse(loader.hasLoaded)
        await loader.loadInitial()
        XCTAssertEqual(calls, ["first", "second", "second"])
    }

    func testQueryCacheEvictsLeastRecentlyUsedAndSkipsOversizedDirectories() async {
        var calls = 0
        let loader = CommunityDirectoryLoader(loadPage: { query, _, _ in
            calls += 1
            return CommunityDirectoryPage(profiles: [self.profile(query)], nextOffset: nil)
        }, maxCachedQueries: 2, maxCachedProfiles: 2)
        for query in ["a", "b", "a", "c", "b"] {
            loader.configure(actorID: "alice", query: query)
            await loader.loadInitial()
        }
        XCTAssertEqual(calls, 4, "Using a again must keep it cached and evict b when c arrives.")
        loader.configure(actorID: "alice", query: "large")
        loader.seed([profile("one"), profile("two"), profile("three")])
        loader.configure(actorID: "alice", query: "other")
        loader.configure(actorID: "alice", query: "large")
        XCTAssertFalse(loader.hasLoaded, "Large active directories stay visible but are not copied into the query cache.")
    }

    func testStaleFirstPageRefreshResetsServerCursorAndDoesNotSkipDisplacedProfiles() async {
        var date = Date(timeIntervalSince1970: 1_000)
        var calls: [Int] = []
        let loader = CommunityDirectoryLoader(loadPage: { _, offset, _ in
            calls.append(offset)
            if offset > 0 { return CommunityDirectoryPage(profiles: [self.profile("tail")], nextOffset: 48) }
            let head = calls.count == 1 ? [self.profile("removed-head"), self.profile("head")] : [self.profile("head", name: "updated head"), self.profile("new-head")]
            return CommunityDirectoryPage(profiles: head, nextOffset: 24)
        }, now: { date })
        loader.configure(actorID: "alice", query: "")
        await loader.loadInitial()
        date.addTimeInterval(50)
        await loader.loadMore()
        await loader.loadInitial()
        XCTAssertEqual(calls, [0, 24])
        date.addTimeInterval(11)
        await loader.loadInitial()
        XCTAssertEqual(calls, [0, 24, 0], "Loading another page must not extend the first page's freshness.")
        XCTAssertEqual(loader.profiles.map(\.id), ["head", "new-head"])
        XCTAssertEqual(loader.profiles.first?.displayName, "updated head")
        XCTAssertEqual(loader.nextOffset, 24, "Restart from the authoritative cursor so inserts/deletes cannot skip displaced profiles.")
        XCTAssertEqual(loader.resetRevision, 2)
        await loader.loadMore()
        XCTAssertEqual(calls, [0, 24, 0, 24])
        XCTAssertEqual(loader.profiles.map(\.id), ["head", "new-head", "tail"])
        await loader.loadInitial(force: true)
        XCTAssertEqual(loader.profiles.map(\.id), ["head", "new-head"])
        XCTAssertEqual(loader.nextOffset, 24)
    }

    func testRealtimeChangesWinOverInflightPageAndUpdateCachedQueries() async throws {
        let client = DirectoryClientStub()
        let loader = CommunityDirectoryLoader(loadPage: client.load)
        loader.configure(actorID: "alice", query: "cached")
        loader.seed([profile("updated"), profile("removed")])
        loader.configure(actorID: "alice", query: "")
        loader.seed([profile("updated"), profile("removed")])
        let loading = Task { await loader.loadInitial(force: true) }
        try await waitForCalls(1, client: client)
        loader.updateProfile(profile("updated", name: "realtime name"))
        loader.removeProfile(userID: "removed")
        loader.updateProfile(profile("appended"), appendIfMissing: true)
        client.succeed(0, profiles: [profile("updated"), profile("removed")], nextOffset: 24)
        await loading.value
        XCTAssertEqual(loader.profiles.map(\.id), ["updated", "appended"])
        XCTAssertEqual(loader.profiles.first?.displayName, "realtime name")
        loader.configure(actorID: "alice", query: "cached")
        XCTAssertEqual(loader.profiles.map(\.id), ["updated"])
        XCTAssertEqual(loader.profiles.first?.displayName, "realtime name")
    }

    func testInvalidationCannotRecacheCurrentDirectoryAndInjectionWorksAfterInit() async {
        let loader = CommunityDirectoryLoader()
        loader.configure(actorID: "alice", query: "", loadPage: { _, _, _ in
            CommunityDirectoryPage(profiles: [self.profile("one")], nextOffset: nil)
        })
        await loader.loadInitial()
        loader.invalidateCache()
        loader.configure(actorID: "alice", query: "other")
        loader.configure(actorID: "alice", query: "")
        XCTAssertFalse(loader.hasLoaded)
        XCTAssertTrue(loader.profiles.isEmpty)
        loader.configure(actorID: nil, query: "")
        await loader.loadInitial()
        XCTAssertFalse(loader.hasLoaded, "Signing out must not send an authenticated directory request.")
    }

    private func waitForCalls(_ count: Int, client: DirectoryClientStub) async throws {
        for _ in 0..<1_000 {
            if client.calls.count >= count { return }
            await Task.yield()
        }
        XCTFail("Expected \(count) directory requests; received \(client.calls.count).")
        throw DirectoryTestError.timedOut
    }

    private func profile(_ id: String, name: String? = nil) -> PublicSpyProfile {
        PublicSpyProfile(id: id, spyID: "123-456", displayName: name ?? id, avatar: "🕵️",
                         spyCardTheme: "field", spyCardAccent: "signal_red", spyCardBadge: "operative",
                         rating: 0, gamesPlayed: 0, gamesWon: 0, winRate: 0)
    }
}

private enum DirectoryTestError: Error { case offline, timedOut }

@MainActor
private final class DirectoryClientStub {
    struct Call: Equatable {
        let query: String
        let offset: Int
        let limit: Int
    }
    private(set) var calls: [Call] = []
    private var pending: [Int: CheckedContinuation<CommunityDirectoryPage, Error>] = [:]

    /// Deliberately ignores cancellation, exercising generation checks even
    /// when a transport's completion races a query change or a view dismissal.
    func load(query: String, offset: Int, limit: Int) async throws -> CommunityDirectoryPage {
        let index = calls.count
        calls.append(Call(query: query, offset: offset, limit: limit))
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func succeed(_ index: Int, profiles: [PublicSpyProfile], nextOffset: Int?) {
        pending.removeValue(forKey: index)?.resume(returning: CommunityDirectoryPage(profiles: profiles, nextOffset: nextOffset))
    }

    func fail(_ index: Int) {
        pending.removeValue(forKey: index)?.resume(throwing: DirectoryTestError.offline)
    }
}
