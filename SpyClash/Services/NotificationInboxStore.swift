import Foundation
import Observation

@MainActor
protocol NotificationInboxClientProtocol: AnyObject {
    func notificationInboxSummary() async throws -> NotificationInboxSummary
    func notificationInboxList(
        scope: NotificationInboxScope,
        cursor: String?,
        limit: Int
    ) async throws -> NotificationInboxPage
    func notificationInboxMarkRead(itemID: String) async throws -> NotificationInboxMutationResponse
    func notificationInboxMarkAllRead(
        scope: NotificationInboxScope
    ) async throws -> NotificationInboxMutationResponse
    func notificationInboxPublishGlobal(
        draft: NotificationGlobalDraft
    ) async throws -> NotificationGlobalPublishResponse
}

extension Base44Client: NotificationInboxClientProtocol {}

enum NotificationInboxLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(message: String)
}

struct NotificationInboxFeedState: Equatable {
    var items: [NotificationInboxItem] = []
    var loadState: NotificationInboxLoadState = .idle
    var errorMessage: String?
    var nextCursor: String?
    var isRefreshing = false
    var isLoadingMore = false

    var canLoadMore: Bool { nextCursor?.nilIfBlank != nil }
}

@MainActor
@Observable
final class NotificationInboxStore {
    @ObservationIgnored private let client: any NotificationInboxClientProtocol
    @ObservationIgnored private let pageSize: Int

    private(set) var accountID: String?
    private(set) var unread = NotificationInboxUnreadCounts.zero
    private(set) var isSummaryLoading = false
    private(set) var summaryError: String?
    private(set) var mutationError: String?
    private(set) var publishingError: String?
    private(set) var pendingPublishRequestID: UUID?
    private(set) var pendingItemIDs: Set<String> = []
    private(set) var markingAllScopes: Set<NotificationInboxScope> = []
    private(set) var isPublishing = false
    private(set) var usesPreviewData = false
    private(set) var feeds: [NotificationInboxScope: NotificationInboxFeedState]

    var selectedScope: NotificationInboxScope = .global

    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var activeMutationScopes: Set<NotificationInboxScope> = []

    init(
        client: any NotificationInboxClientProtocol,
        pageSize: Int = 30,
        initialPages: [NotificationInboxScope: NotificationInboxPage] = [:],
        accountID: String? = nil
    ) {
        self.client = client
        self.pageSize = min(max(pageSize, 1), 50)
        self.accountID = accountID?.nilIfBlank

        var initialFeeds = Dictionary(
            uniqueKeysWithValues: NotificationInboxScope.allCases.map {
                ($0, NotificationInboxFeedState())
            }
        )
        for (scope, page) in initialPages {
            initialFeeds[scope] = NotificationInboxFeedState(
                items: page.items,
                loadState: .loaded,
                nextCursor: page.nextCursor
            )
            unread = page.unread
        }
        feeds = initialFeeds
    }

    func bindAccount(_ userID: String?) {
        let normalizedID = userID?.nilIfBlank
        guard normalizedID != accountID else { return }

        generation &+= 1
        accountID = normalizedID
        unread = .zero
        isSummaryLoading = false
        summaryError = nil
        mutationError = nil
        publishingError = nil
        pendingPublishRequestID = nil
        pendingItemIDs = []
        markingAllScopes = []
        activeMutationScopes = []
        isPublishing = false
        usesPreviewData = false
        selectedScope = .global
        feeds = Dictionary(
            uniqueKeysWithValues: NotificationInboxScope.allCases.map {
                ($0, NotificationInboxFeedState())
            }
        )
    }

    func selectScope(_ scope: NotificationInboxScope) {
        selectedScope = scope
        mutationError = nil
    }

    func feed(for scope: NotificationInboxScope) -> NotificationInboxFeedState {
        feeds[scope] ?? NotificationInboxFeedState()
    }

    func unreadCount(for scope: NotificationInboxScope) -> Int {
        unread.count(for: scope)
    }

    func isMutating(scope: NotificationInboxScope) -> Bool {
        activeMutationScopes.contains(scope)
    }

    func loadInitial() async {
        guard !usesPreviewData else { return }
        async let summary: Void = refreshSummary()
        async let page: Void = loadIfNeeded(scope: selectedScope)
        _ = await (summary, page)
    }

    func loadIfNeeded(scope: NotificationInboxScope) async {
        guard !usesPreviewData else { return }
        guard feed(for: scope).loadState == .idle else { return }
        await refresh(scope: scope)
    }

    func refreshSummary() async {
        guard !usesPreviewData else { return }
        guard !isSummaryLoading, let context = requestContext() else { return }

        isSummaryLoading = true
        summaryError = nil
        defer {
            if isCurrent(context) {
                isSummaryLoading = false
            }
        }

        do {
            let response = try await client.notificationInboxSummary()
            guard isCurrent(context) else { return }
            unread = response.unread
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(context) else { return }
            summaryError = errorMessage(from: error)
        }
    }

    func refresh(scope: NotificationInboxScope) async {
        guard !usesPreviewData else { return }
        await load(scope: scope, reset: true)
    }

    func loadNextPage(scope: NotificationInboxScope) async {
        guard !usesPreviewData else { return }
        guard feed(for: scope).canLoadMore else { return }
        await load(scope: scope, reset: false)
    }

    @discardableResult
    func markRead(_ item: NotificationInboxItem) async -> Bool {
        if usesPreviewData {
            return markPreviewItemRead(item)
        }

        let scope = item.scope
        guard item.isUnread,
              let context = requestContext(),
              !activeMutationScopes.contains(scope) else {
            return !item.isUnread
        }

        let originalFeed = feed(for: scope)
        guard !originalFeed.isRefreshing,
              !originalFeed.isLoadingMore,
              let index = originalFeed.items.firstIndex(where: { $0.id == item.id }),
              originalFeed.items[index].isUnread else {
            return false
        }

        let originalUnread = unread
        activeMutationScopes.insert(scope)
        pendingItemIDs.insert(item.id)
        mutationError = nil
        var optimisticFeed = originalFeed
        optimisticFeed.items[index] = optimisticFeed.items[index].markingRead(at: Self.currentTimestamp())
        feeds[scope] = optimisticFeed
        unread = unread.replacing(scope, with: unread.count(for: scope) - 1)

        defer {
            if isCurrent(context) {
                activeMutationScopes.remove(scope)
                pendingItemIDs.remove(item.id)
            }
        }

        do {
            let response = try await client.notificationInboxMarkRead(itemID: item.id)
            guard isCurrent(context) else { return false }

            guard response.ok else {
                throw Base44Error(message: "Notification was not marked as read.", statusCode: 502)
            }

            var committedFeed = feed(for: scope)
            if let serverItem = response.item,
               let committedIndex = committedFeed.items.firstIndex(where: { $0.id == item.id }) {
                committedFeed.items[committedIndex] = serverItem
                feeds[scope] = committedFeed
            }
            unread = response.unread
            return true
        } catch is CancellationError {
            guard isCurrent(context) else { return false }
            feeds[scope] = originalFeed
            unread = originalUnread
            return false
        } catch {
            guard isCurrent(context) else { return false }
            feeds[scope] = originalFeed
            unread = originalUnread
            mutationError = errorMessage(from: error)
            return false
        }
    }

    @discardableResult
    func markAllRead(scope: NotificationInboxScope) async -> Bool {
        if usesPreviewData {
            return markAllPreviewItemsRead(scope: scope)
        }

        guard unread.count(for: scope) > 0,
              let context = requestContext(),
              !activeMutationScopes.contains(scope) else {
            return unread.count(for: scope) == 0
        }

        let originalFeed = feed(for: scope)
        guard !originalFeed.isRefreshing, !originalFeed.isLoadingMore else { return false }

        let originalUnread = unread
        let timestamp = Self.currentTimestamp()
        activeMutationScopes.insert(scope)
        markingAllScopes.insert(scope)
        mutationError = nil

        var optimisticFeed = originalFeed
        optimisticFeed.items = optimisticFeed.items.map {
            $0.isUnread ? $0.markingRead(at: timestamp) : $0
        }
        feeds[scope] = optimisticFeed
        unread = unread.replacing(scope, with: 0)

        defer {
            if isCurrent(context) {
                activeMutationScopes.remove(scope)
                markingAllScopes.remove(scope)
            }
        }

        do {
            let response = try await client.notificationInboxMarkAllRead(scope: scope)
            guard isCurrent(context) else { return false }

            guard response.ok else {
                throw Base44Error(message: "Notifications were not marked as read.", statusCode: 502)
            }
            unread = response.unread
            return true
        } catch is CancellationError {
            guard isCurrent(context) else { return false }
            feeds[scope] = originalFeed
            unread = originalUnread
            return false
        } catch {
            guard isCurrent(context) else { return false }
            feeds[scope] = originalFeed
            unread = originalUnread
            mutationError = errorMessage(from: error)
            return false
        }
    }

    @discardableResult
    func publishGlobal(_ draft: NotificationGlobalDraft) async -> Bool {
        if usesPreviewData {
            return publishPreviewGlobal(draft)
        }

        guard !isPublishing, let context = requestContext() else { return false }

        if let pendingPublishRequestID, pendingPublishRequestID != draft.requestID {
            publishingError = "Finish or cancel the pending transmission before publishing another one."
            return false
        }

        isPublishing = true
        pendingPublishRequestID = draft.requestID
        publishingError = nil
        defer {
            if isCurrent(context) {
                isPublishing = false
            }
        }

        do {
            let response = try await client.notificationInboxPublishGlobal(draft: draft)
            guard isCurrent(context) else { return false }

            guard response.ok else {
                throw Base44Error(message: "Global notification was not published.", statusCode: 502)
            }

            var globalFeed = feed(for: .global)
            globalFeed.items.removeAll { $0.id == response.item.id }
            globalFeed.items.insert(response.item, at: 0)
            globalFeed.loadState = .loaded
            globalFeed.errorMessage = nil
            feeds[.global] = globalFeed
            if let responseUnread = response.unread {
                unread = responseUnread
            }
            pendingPublishRequestID = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrent(context) else { return false }
            publishingError = errorMessage(from: error)
            return false
        }
    }

    func clearMutationError() {
        mutationError = nil
    }

    func clearPublishingError() {
        publishingError = nil
    }

    func cancelPendingPublish(requestID: UUID) {
        guard !isPublishing, pendingPublishRequestID == requestID else { return }
        pendingPublishRequestID = nil
        publishingError = nil
    }

#if DEBUG
    func installPreview(accountID: String? = nil) {
        generation &+= 1
        self.accountID = accountID?.nilIfBlank ?? "spyclash-notification-preview"
        unread = NotificationInboxPreview.unread
        isSummaryLoading = false
        summaryError = nil
        mutationError = nil
        publishingError = nil
        pendingPublishRequestID = nil
        pendingItemIDs = []
        markingAllScopes = []
        activeMutationScopes = []
        isPublishing = false
        usesPreviewData = true
        selectedScope = .global
        feeds = Dictionary(
            uniqueKeysWithValues: NotificationInboxScope.allCases.map { scope in
                let page = NotificationInboxPreview.page(for: scope)
                return (
                    scope,
                    NotificationInboxFeedState(
                        items: page.items,
                        loadState: .loaded,
                        nextCursor: page.nextCursor
                    )
                )
            }
        )
    }
#endif

    private func load(scope: NotificationInboxScope, reset: Bool) async {
        guard let context = requestContext(),
              !activeMutationScopes.contains(scope) else {
            return
        }

        var currentFeed = feed(for: scope)
        guard !currentFeed.isRefreshing, !currentFeed.isLoadingMore else { return }
        if !reset, currentFeed.nextCursor?.nilIfBlank == nil { return }

        let cursor = reset ? nil : currentFeed.nextCursor
        if reset {
            currentFeed.isRefreshing = true
            if currentFeed.items.isEmpty {
                currentFeed.loadState = .loading
            }
        } else {
            currentFeed.isLoadingMore = true
        }
        currentFeed.errorMessage = nil
        feeds[scope] = currentFeed

        defer {
            if isCurrent(context) {
                var finishedFeed = feed(for: scope)
                finishedFeed.isRefreshing = false
                finishedFeed.isLoadingMore = false
                feeds[scope] = finishedFeed
            }
        }

        do {
            let response = try await client.notificationInboxList(
                scope: scope,
                cursor: cursor,
                limit: pageSize
            )
            guard isCurrent(context) else { return }
            if let responseScope = response.scope, responseScope != scope {
                throw Base44Error(message: "Notification scope mismatch.", statusCode: 502)
            }

            var loadedFeed = feed(for: scope)
            loadedFeed.items = reset
                ? Self.uniqueItems(response.items)
                : Self.merging(loadedFeed.items, with: response.items)
            loadedFeed.loadState = .loaded
            loadedFeed.errorMessage = nil
            loadedFeed.nextCursor = response.nextCursor
            feeds[scope] = loadedFeed
            unread = response.unread
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(context) else { return }
            let message = errorMessage(from: error)
            var failedFeed = feed(for: scope)
            failedFeed.errorMessage = message
            failedFeed.loadState = failedFeed.items.isEmpty ? .failed(message: message) : .loaded
            feeds[scope] = failedFeed
        }
    }

    private func requestContext() -> RequestContext? {
        guard let accountID else { return nil }
        return RequestContext(generation: generation, accountID: accountID)
    }

    private func isCurrent(_ context: RequestContext) -> Bool {
        context.generation == generation && context.accountID == accountID
    }

    private func errorMessage(from error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Notification request failed." : message
    }

    private static func uniqueItems(_ items: [NotificationInboxItem]) -> [NotificationInboxItem] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }

    private static func merging(
        _ existing: [NotificationInboxItem],
        with page: [NotificationInboxItem]
    ) -> [NotificationInboxItem] {
        var merged = existing
        var indices = Dictionary(uniqueKeysWithValues: existing.enumerated().map { ($1.id, $0) })
        for item in page {
            if let index = indices[item.id] {
                merged[index] = item
            } else {
                indices[item.id] = merged.count
                merged.append(item)
            }
        }
        return merged
    }

    private static func currentTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func markPreviewItemRead(_ item: NotificationInboxItem) -> Bool {
        var previewFeed = feed(for: item.scope)
        guard let index = previewFeed.items.firstIndex(where: { $0.id == item.id }),
              previewFeed.items[index].isUnread else {
            return !item.isUnread
        }
        previewFeed.items[index] = previewFeed.items[index].markingRead(at: Self.currentTimestamp())
        feeds[item.scope] = previewFeed
        unread = unread.replacing(item.scope, with: unread.count(for: item.scope) - 1)
        return true
    }

    private func markAllPreviewItemsRead(scope: NotificationInboxScope) -> Bool {
        let timestamp = Self.currentTimestamp()
        var previewFeed = feed(for: scope)
        previewFeed.items = previewFeed.items.map {
            $0.isUnread ? $0.markingRead(at: timestamp) : $0
        }
        feeds[scope] = previewFeed
        unread = unread.replacing(scope, with: 0)
        return true
    }

    private func publishPreviewGlobal(_ draft: NotificationGlobalDraft) -> Bool {
        guard draft.title.nilIfBlank != nil, draft.body.nilIfBlank != nil else { return false }
        let item = NotificationInboxItem(
            id: "preview-\(draft.requestID.uuidString.lowercased())",
            scope: .global,
            kind: "announcement",
            importance: draft.importance,
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: draft.body.trimmingCharacters(in: .whitespacesAndNewlines),
            publishedAt: Self.currentTimestamp(),
            readAt: Self.currentTimestamp(),
            actionDeepLink: draft.actionDeepLink?.nilIfBlank
        )
        var previewFeed = feed(for: .global)
        previewFeed.items.insert(item, at: 0)
        previewFeed.loadState = .loaded
        feeds[.global] = previewFeed
        pendingPublishRequestID = nil
        publishingError = nil
        return true
    }

    private struct RequestContext {
        let generation: UInt64
        let accountID: String
    }
}
