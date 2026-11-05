import Foundation

extension AppState {
    var membershipScope: MembershipScope {
        MembershipScope(userID: user?.id, accessToken: client.currentAccessToken,
                        sessionGeneration: client.membershipSessionGeneration)
    }

    func bindMembershipAccount() {
        if SupabaseTestEnvironment.isEnabled {
            membershipRealtime.stop()
            let disabled = MembershipScope(userID: nil, accessToken: nil)
            membership.bind(disabled)
            generationRewards.bind(disabled)
            storeKit.bind(disabled)
            return
        }
        if membership.scope != membershipScope { membershipRealtime.stop() }
        let preview: MembershipSnapshot?
        if shouldUsePreviewData {
#if DEBUG
            preview = ProcessInfo.processInfo.arguments.contains("--spyclash-preview-limitless")
                ? .freePreview : .universalPreview
#else
            preview = nil
#endif
        } else { preview = nil }
        membership.bind(membershipScope, preview: preview)
        var generationPreview: GenerationRewardStatus?
#if DEBUG
        if shouldUsePreviewData, ProcessInfo.processInfo.arguments.contains("--spyclash-preview-generations") {
            let unlimited = ProcessInfo.processInfo.arguments.contains("--spyclash-preview-generations-unlimited")
            let exhausted = ProcessInfo.processInfo.arguments.contains("--spyclash-preview-generations-exhausted")
            generationPreview = GenerationRewardStatus(enabled: true, unlimited: unlimited, freeRemaining: unlimited ? nil : exhausted ? 0 : 3, resetsAt: Date().addingTimeInterval(3600), adAvailable: true)
        }
#endif
        generationRewards.bind(membershipScope, preview: generationPreview)
        storeKit.bind(shouldUsePreviewData ? MembershipScope(userID: nil, accessToken: nil) : membershipScope)
    }

    func monitorMembership() async {
        guard !SupabaseTestEnvironment.isEnabled else { return }
        bindMembershipAccount()
        guard !shouldUsePreviewData, membershipScope.isAuthenticated else { return }
        let expectedScope = membershipScope
        membershipRealtime.bind(expectedScope)
        _ = await membership.refresh()
        _ = await generationRewards.refresh()
        if membership.snapshot?.accessProtocol == "limitless" {
            await storeKit.synchronizeAfterActivation()
        }
        while !Task.isCancelled, membershipScope == expectedScope {
            // Expiry is checked locally as well; polling also recovers missed signals.
            let expiryDelay = membership.snapshot?.expiresAt?.timeIntervalSinceNow ?? 60
            let delay = expiryDelay > 0 ? min(60, expiryDelay + 0.05) : 60
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            _ = await membership.refresh()
            _ = await generationRewards.refresh()
        }
    }
}
