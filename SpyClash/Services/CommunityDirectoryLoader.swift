import Foundation
import Observation

/// Loads lightweight directory summaries one page at a time. Profile details
/// keep their separate, on-demand lifecycle in the Community screen.
@MainActor
@Observable
final class CommunityDirectoryLoader {
    typealias Loader = @MainActor (String, Int, Int) async throws -> CommunityDirectoryPage

    private(set) var profiles: [PublicSpyProfile] = []
    private(set) var nextOffset: Int?
    private(set) var isLoading = false
    private(set) var failedOffset: Int?
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private(set) var actorID: String?
    private(set) var query = ""
    private(set) var isSuspended = false
    private(set) var resetRevision = 0
    private(set) var completionRevision = 0

    @ObservationIgnored private var loadPage: Loader?
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let cacheTTL: TimeInterval
    @ObservationIgnored private let maxCachedQueries: Int
    @ObservationIgnored private let maxCachedProfiles: Int
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var lastLoadedAt: Date?
    @ObservationIgnored private var cache: [String: CachedDirectory] = [:]
    @ObservationIgnored private var accessSequence = 0
    @ObservationIgnored private var profileUpdatesDuringRequest: [String: PublicSpyProfile] = [:]
    @ObservationIgnored private var profileRemovalsDuringRequest: Set<String> = []
    @ObservationIgnored private var appendedIDsDuringRequest: [String] = []

    private struct CachedDirectory {
        var profiles: [PublicSpyProfile]
        let nextOffset: Int?
        let loadedAt: Date
        var lastAccess: Int
    }

    init(
        loadPage: Loader? = nil,
        pageSize: Int = 24,
        cacheTTL: TimeInterval = 60,
        maxCachedQueries: Int = 4,
        maxCachedProfiles: Int = 240,
        now: @escaping () -> Date = Date.init
    ) {
        self.loadPage = loadPage
        self.pageSize = min(max(pageSize, 1), 50)
        self.cacheTTL = max(cacheTTL, 0)
        self.maxCachedQueries = max(maxCachedQueries, 0)
        self.maxCachedProfiles = max(maxCachedProfiles, 0)
        self.now = now
    }

    deinit { requestTask?.cancel() }

    /// Call as soon as the account or search changes, before any search debounce.
    /// Superseded responses can then never become visible under the new query.
    func configure(actorID: String?, query: String, loadPage: Loader? = nil) {
        if let loadPage { self.loadPage = loadPage }
        let nextActor = actorID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextActorID = nextActor?.isEmpty == false ? nextActor : nil
        let nextQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nextActorID != self.actorID || nextQuery != self.query else { return }

        let accountChanged = nextActorID != self.actorID
        if accountChanged { cache.removeAll() }
        else { cacheCurrentDirectory() }
        cancelRequest()
        self.actorID = nextActorID
        self.query = nextQuery
        profiles = []
        nextOffset = nil
        hasLoaded = false
        failedOffset = nil
        errorMessage = nil
        lastLoadedAt = nil

        pruneCache()
        if nextActorID != nil, var cached = cache[nextQuery] {
            accessSequence += 1
            cached.lastAccess = accessSequence
            cache[nextQuery] = cached
            profiles = cached.profiles
            nextOffset = cached.nextOffset
            hasLoaded = true
            lastLoadedAt = cached.loadedAt
        }
    }

    func loadInitial(force: Bool = false) async {
        guard force || failedOffset == nil else { return }
        if !force, hasLoaded, let lastLoadedAt,
           now().timeIntervalSince(lastLoadedAt) < cacheTTL { return }
        await load(offset: 0, replacing: true)
    }

    func loadMore() async {
        guard hasLoaded, failedOffset == nil, let nextOffset else { return }
        await load(offset: nextOffset, replacing: false)
    }

    /// A failed page is retried only by an explicit recovery action. A footer
    /// remaining visible must never create an automatic failure/retry loop.
    func retry() async {
        guard let failedOffset else { return }
        await load(offset: failedOffset, replacing: failedOffset == 0)
    }

    func suspend() {
        isSuspended = true
        cancelRequest()
    }

    func resume() { isSuspended = false }

    func invalidateCache() {
        cache.removeAll()
        lastLoadedAt = nil
    }

    func seed(_ profiles: [PublicSpyProfile], nextOffset: Int? = nil) {
        cancelRequest()
        self.profiles = merged([], with: profiles)
        self.nextOffset = nextOffset.flatMap { $0 > 0 ? $0 : nil }
        hasLoaded = true
        failedOffset = nil
        errorMessage = nil
        lastLoadedAt = now()
        cacheCurrentDirectory()
    }

    func updateProfile(_ profile: PublicSpyProfile, appendIfMissing: Bool = false) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else if appendIfMissing {
            profiles.append(profile)
            if isLoading { appendedIDsDuringRequest.append(profile.id) }
        }
        if isLoading {
            profileUpdatesDuringRequest[profile.id] = profile
            profileRemovalsDuringRequest.remove(profile.id)
        }
        for key in Array(cache.keys) {
            if let index = cache[key]?.profiles.firstIndex(where: { $0.id == profile.id }) {
                cache[key]?.profiles[index] = profile
            }
        }
        cacheCurrentDirectory()
    }

    func removeProfile(userID: String) {
        profiles.removeAll { $0.id == userID }
        if isLoading {
            profileRemovalsDuringRequest.insert(userID)
            profileUpdatesDuringRequest[userID] = nil
            appendedIDsDuringRequest.removeAll { $0 == userID }
        }
        for key in Array(cache.keys) {
            cache[key]?.profiles.removeAll { $0.id == userID }
        }
        cacheCurrentDirectory()
    }

    private func load(offset: Int, replacing: Bool) async {
        guard !Task.isCancelled, !isSuspended, !isLoading,
              actorID != nil, let loadPage else { return }
        // A previously captured footer cursor cannot skip or repeat a page.
        guard replacing || nextOffset == offset else { return }

        let id = UUID()
        let requestedQuery = query
        requestID = id
        isLoading = true
        failedOffset = nil
        errorMessage = nil
        clearRequestProfileChanges()
        let pageSize = pageSize
        let task = Task { @MainActor [weak self] in
            do {
                let page = try await loadPage(requestedQuery, offset, pageSize)
                guard !Task.isCancelled else {
                    self?.finishCancellation(id: id)
                    return
                }
                self?.receive(page, offset: offset, replacing: replacing, id: id)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    self?.finishCancellation(id: id)
                } else {
                    self?.receiveFailure(error, offset: offset, id: id)
                }
            }
        }
        requestTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in self?.finishCancellation(id: id) }
        }
    }

    private func receive(_ page: CommunityDirectoryPage, offset: Int, replacing: Bool, id: UUID) {
        guard requestID == id else { return }
        let updatedPage = page.profiles.compactMap { profile -> PublicSpyProfile? in
            guard !profileRemovalsDuringRequest.contains(profile.id) else { return nil }
            return profileUpdatesDuringRequest[profile.id] ?? profile
        }
        profiles = merged(replacing ? [] : profiles, with: updatedPage)
        for profileID in appendedIDsDuringRequest {
            if let profile = profileUpdatesDuringRequest[profileID],
               !profiles.contains(where: { $0.id == profileID }) {
                profiles.append(profile)
            }
        }
        // An absent, repeated or backwards cursor ends pagination. Empty pages
        // with an advancing cursor are allowed (e.g. after visibility filtering).
        nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
        if replacing {
            lastLoadedAt = now()
            resetRevision &+= 1
        }
        hasLoaded = true
        failedOffset = nil
        errorMessage = nil
        finishRequest()
        cacheCurrentDirectory()
    }

    private func receiveFailure(_ error: Error, offset: Int, id: UUID) {
        guard requestID == id else { return }
        failedOffset = offset
        errorMessage = error.localizedDescription
        finishRequest()
    }

    private func finishCancellation(id: UUID) {
        guard requestID == id else { return }
        finishRequest()
    }

    private func cancelRequest() {
        requestTask?.cancel()
        finishRequest()
    }

    private func finishRequest() {
        if requestID != nil { completionRevision &+= 1 }
        requestID = nil
        requestTask = nil
        isLoading = false
        clearRequestProfileChanges()
    }

    private func clearRequestProfileChanges() {
        profileUpdatesDuringRequest.removeAll()
        profileRemovalsDuringRequest.removeAll()
        appendedIDsDuringRequest.removeAll()
    }

    private func merged(_ existing: [PublicSpyProfile], with page: [PublicSpyProfile]) -> [PublicSpyProfile] {
        var result = existing
        var indices = Dictionary(uniqueKeysWithValues: existing.enumerated().map { ($0.element.id, $0.offset) })
        for profile in page {
            if let index = indices[profile.id] { result[index] = profile }
            else {
                indices[profile.id] = result.count
                result.append(profile)
            }
        }
        return result
    }

    private func cacheCurrentDirectory() {
        guard actorID != nil, hasLoaded, let loadedAt = lastLoadedAt,
              cacheTTL > 0, maxCachedQueries > 0,
              profiles.count <= maxCachedProfiles else {
            cache[query] = nil
            return
        }
        accessSequence += 1
        cache[query] = CachedDirectory(profiles: profiles, nextOffset: nextOffset,
                                      loadedAt: loadedAt, lastAccess: accessSequence)
        pruneCache()
    }

    private func pruneCache() {
        let date = now()
        cache = cache.filter { date.timeIntervalSince($0.value.loadedAt) < cacheTTL }
        while cache.count > maxCachedQueries,
              let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            cache[oldest] = nil
        }
    }
}
