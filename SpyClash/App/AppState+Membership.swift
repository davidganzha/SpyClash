import Foundation

extension AppState {
    var membershipScope: MembershipScope {
        MembershipScope(userID: user?.id, accessToken: client.currentAccessToken)
    }

    func bindMembershipAccount() {
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
        storeKit.bind(shouldUsePreviewData ? MembershipScope(userID: nil, accessToken: nil) : membershipScope)
    }

    func monitorMembership() async {
        bindMembershipAccount()
        guard !shouldUsePreviewData, membershipScope.isAuthenticated else { return }
        let expectedScope = membershipScope
        membershipRealtime.bind(expectedScope)
        _ = await membership.refresh()
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
        }
    }
}
