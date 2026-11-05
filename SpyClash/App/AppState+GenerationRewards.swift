import Foundation

extension AppState {
    /// All explicit AI entry points share the same server-owned allowance. A
    /// stale client balance never prevents replaying an already paid request.
    func generateWordPack(theme: String, count: Int, requestID: UUID, excluding: [String] = [], preferFresh: Bool = false) async throws -> GeneratedWordPack {
        let account = membershipScope
        do {
            let generated = try await client.generateWordPack(theme: theme, count: count, requestID: requestID, excluding: excluding, preferFresh: preferFresh)
            guard membershipScope == account else { throw CancellationError() }
            membership.updateAIUsage(used: generated.aiGenerationsToday, remaining: generated.aiRemaining)
            generationRewards.generationDidComplete()
            Task { _ = await generationRewards.refresh() }
            return generated
        } catch {
            guard membershipScope == account else { throw CancellationError() }
            Task { _ = await generationRewards.refresh() }
            if let server = error as? Base44Error, ["ai_limit_reached", "daily_ai_limit_reached", "generation_credit_required"].contains(server.code) {
                generationRewards.reportLimitReached()
                throw Base44Error(message: GenerationRewardCopy(language: language).notice(.limitReached), statusCode: 429, code: "daily_ai_limit_reached")
            }
            throw error
        }
    }
}
