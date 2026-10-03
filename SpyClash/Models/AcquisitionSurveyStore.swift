import Foundation

/// Device-local, account-scoped progress for the optional acquisition survey.
/// Only distinct completed matches count; opening or abandoning a game does not.
struct AcquisitionSurveyStore {
    static let requiredCompletedGames = 3

    private static let namespace = "spyclash.acquisition-survey"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    @discardableResult
    func recordCompletedGame(id: String, for userID: String) -> Bool {
        let gameID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gameID.isEmpty, let key = accountKey(for: userID) else { return false }
        var progress = load(key: key)
        guard progress.completedGameIDs.count < Self.requiredCompletedGames,
              !progress.completedGameIDs.contains(gameID) else { return false }
        progress.completedGameIDs.append(gameID)
        save(progress, key: key)
        return true
    }

    func completedGameCount(for userID: String) -> Int {
        guard let key = accountKey(for: userID) else { return 0 }
        return load(key: key).completedGameIDs.count
    }

    func isEligible(for userID: String, remoteSource: String?) -> Bool {
        guard let key = accountKey(for: userID),
              (remoteSource ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let progress = load(key: key)
        return progress.completedGameIDs.count >= Self.requiredCompletedGames
            && progress.presentedAt == nil
            && progress.pendingAnswer == nil
    }

    /// Record when the sheet is shown, including when the player then skips it.
    /// A dismissal must not manufacture an acquisition answer or show it again.
    func markPresented(for userID: String) {
        guard let key = accountKey(for: userID) else { return }
        var progress = load(key: key)
        guard progress.presentedAt == nil else { return }
        progress.presentedAt = Date()
        save(progress, key: key)
    }

    func saveAnswer(source: OnboardingAcquisitionSource, for userID: String) {
        guard let key = accountKey(for: userID) else { return }
        var progress = load(key: key)
        progress.presentedAt = progress.presentedAt ?? Date()
        progress.pendingAnswer = source
        save(progress, key: key)
    }

    func pendingAnswer(for userID: String) -> OnboardingAcquisitionSource? {
        guard let key = accountKey(for: userID) else { return nil }
        return load(key: key).pendingAnswer
    }

    /// A late acknowledgement for an older answer must preserve a newer choice.
    func markSynced(source: OnboardingAcquisitionSource, for userID: String) {
        guard let key = accountKey(for: userID) else { return }
        var progress = load(key: key)
        guard progress.pendingAnswer == source else { return }
        progress.pendingAnswer = nil
        save(progress, key: key)
    }

    func clear(for userID: String) {
        guard let key = accountKey(for: userID) else { return }
        defaults.removeObject(forKey: key)
    }

    private struct Progress: Codable {
        // Keep only the first three IDs: no unbounded local match history.
        var completedGameIDs: [String] = []
        var presentedAt: Date?
        var pendingAnswer: OnboardingAcquisitionSource?
    }

    private func load(key: String) -> Progress {
        guard let data = defaults.data(forKey: key),
              let progress = try? JSONDecoder().decode(Progress.self, from: data) else {
            return Progress()
        }
        return progress
    }

    private func save(_ progress: Progress, key: String) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: key)
    }

    private func accountKey(for userID: String) -> String? {
        let userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty else { return nil }
        let accountScope = Data(userID.utf8).base64EncodedString()
        return "\(Self.namespace).\(accountScope)"
    }
}
