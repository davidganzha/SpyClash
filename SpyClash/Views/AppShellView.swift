import SwiftUI
import UIKit

@MainActor
private enum ShellTextInputActivity {
    static var isActive: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { window in
                guard let responder = firstResponder(in: window) else { return false }
                return responder is UITextField || responder is UITextView
            }
    }

    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let responder = firstResponder(in: subview) {
                return responder
            }
        }
        return nil
    }
}

@MainActor
private enum ShellHorizontalControlHitTest {
    static func containsInteractiveHorizontalControl(at globalPoint: CGPoint) -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden && $0.alpha > 0 }
            .sorted { $0.isKeyWindow && !$1.isKeyWindow }
            .contains { window in
                let windowPoint = window.convert(globalPoint, from: nil)
                guard window.bounds.contains(windowPoint),
                      let hitView = window.hitTest(windowPoint, with: nil) else {
                    return false
                }
                return hasInteractiveHorizontalAncestor(hitView)
            }
    }

    private static func hasInteractiveHorizontalAncestor(_ hitView: UIView) -> Bool {
        var candidate: UIView? = hitView
        while let view = candidate {
            if view is UISlider {
                return true
            }

            if let scrollView = view as? UIScrollView,
               scrollView.isScrollEnabled,
               isHorizontallyScrollable(scrollView) {
                return true
            }
            candidate = view.superview
        }
        return false
    }

    private static func isHorizontallyScrollable(_ scrollView: UIScrollView) -> Bool {
        if scrollView.alwaysBounceHorizontal {
            return true
        }

        let contentWidth = scrollView.contentSize.width
            + scrollView.adjustedContentInset.left
            + scrollView.adjustedContentInset.right
        return contentWidth > scrollView.bounds.width + 8
    }
}

enum ShellSupplementaryRefreshPolicy {
    static func shouldRun(activeRoomStatus: String?) -> Bool {
        let status = activeRoomStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return status != "roulette" && status != "playing"
    }
}

struct AppShellView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var dockNamespace
    @State private var isCommandMenuPresented = AppShellView.initialCommandMenuPresentation
    @State private var communityTab: CommunityTab = .network
    @State private var communityDockRequest = CommunityDockRequest.initial
    @State private var communityAttention = CommunityAttentionSnapshot.empty
    @State private var communityNetworkState: CommunityState?
    @State private var communityAttentionRequestID: UUID?
    @State private var primarySwipeOffset: CGFloat = 0
    @State private var primarySwipeTarget: AppTab?
    @State private var primarySwipeDirection: TabSwipeDirection?
    @State private var primarySwipeProgress: CGFloat = 0
    @State private var mountedPrimaryTabs: Set<AppTab> = []

    private static var initialCommandMenuPresentation: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--spyclash-preview-command-menu-open")
#else
        false
#endif
    }

    var body: some View {
        @Bindable var appState = appState
        let contentTab = appState.selectedTab == .game && appState.activeRoom == nil ? AppTab.home : appState.selectedTab
        let dockTabs = AppTab.primaryCases
        let isCommunityRoute = appState.shellRoute == .community
        let isNotificationsRoute = appState.shellRoute == .notifications
        let dockSelection = Binding<AppTab>(
            get: { appState.selectedTab },
            set: { tab in
                mountedPrimaryTabs.insert(tab.dockRepresentative)
                appState.openMainTab(tab)
            }
        )
        let shouldShowShellChrome = !appState.isShellChromeSuppressed
        let shouldShowDock = (
            isCommunityRoute || isNotificationsRoute || contentTab.showsBottomDock
        ) && shouldShowShellChrome

        ZStack {
            ZStack {
                ZStack(alignment: .bottom) {
                    Group {
                        if isCommunityRoute {
                            CommunityView(
                                selectedTab: $communityTab,
                                dockRequest: communityDockRequest,
                                externalNetworkState: communityNetworkState,
                                onAttentionChange: { state in
                                    communityAttentionRequestID = nil
                                    installCommunityAttention(state, announceNew: false)
                                }
                            ) {
                                appState.closeCommunity()
                            }
                            .shellDockContentInset(visible: shouldShowDock)
                        } else if isNotificationsRoute {
                            NotificationsInboxView(
                                store: appState.notificationInbox,
                                language: appState.language,
                                canPublishGlobal: appState.user?.role == "admin",
                                onOpenItem: { item in
                                    guard let rawLink = item.actionDeepLink?.nilIfBlank,
                                          let url = URL(string: rawLink) else {
                                        return
                                    }
                                    appState.handleIncomingURL(url)
                                },
                                focusItemID: appState.notificationFocusItemID,
                                focusRequestID: appState.notificationFocusRequestID
                            )
                            .shellDockContentInset(visible: shouldShowDock)
                        } else if AppTab.primaryCases.contains(contentTab) {
                            primaryTabPager(
                                contentTab: contentTab,
                                reservesDock: shouldShowDock
                            )
                        } else {
                            contentTab.makeContentView()
                                .shellDockContentInset(visible: shouldShowDock)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        contentSwipeGesture(
                            contentTab: contentTab,
                            isCommunityRoute: isCommunityRoute,
                            viewportWidth: nil
                        ),
                        including: .all
                    )

                    FloatingDock(
                        selection: dockSelection,
                        tabs: dockTabs,
                        communitySelection: communityTab,
                        isCommunity: isCommunityRoute,
                        communityAttentionCount: communityAttention.totalCount,
                        primarySwipeTarget: primarySwipeTarget,
                        primarySwipeProgress: primarySwipeProgress,
                        namespace: dockNamespace,
                        language: appState.language
                    ) { tab in
                        requestCommunityTab(tab)
                    }
                    .opacity(shouldShowDock ? 1 : 0)
                    .offset(y: shouldShowDock ? 0 : 78)
                    .allowsHitTesting(shouldShowDock)
                    .accessibilityHidden(!shouldShowDock)
                    .animation(.easeOut(duration: 0.20), value: shouldShowDock)
                }
                .background(SpyTheme.black)
                .overlay(alignment: .top) {
                    WebPullDownCommandMenu(
                        isPresented: $isCommandMenuPresented,
                        communityAttentionCount: communityAttention.totalCount,
                        notificationUnreadCount: appState.notificationInbox.unread.total
                    )
                        .opacity(shouldShowShellChrome ? 1 : 0)
                        .offset(y: shouldShowShellChrome ? 0 : -140)
                        .allowsHitTesting(shouldShowShellChrome)
                        .accessibilityHidden(!shouldShowShellChrome)
                        .animation(.easeOut(duration: 0.18), value: shouldShowShellChrome)
                }
            }
            .blur(radius: roomSyncBlurRadius)
            .disabled(showsBlockingRoomSyncOverlay)
            .allowsHitTesting(!showsBlockingRoomSyncOverlay)
            .accessibilityHidden(showsBlockingRoomSyncOverlay)

            if let operation = appState.roomSyncOperation,
               showsBlockingRoomSyncOverlay {
                RoomSynchronizationOverlay(operation: operation, language: appState.language)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .background(SpyTheme.black)
        .animation(
            .easeOut(duration: reduceMotion ? 0.12 : 0.18),
            value: appState.shellRoute
        )
        .animation(
            reduceMotion ? .easeOut(duration: 0.14) : .easeInOut(duration: 0.26),
            value: appState.roomSyncOperation
        )
        .sheet(item: $appState.presentedSheet) { destination in
            switch destination {
            case .qrScanner:
                QRScannerSheet()
                    .spyGlobalToastLayer()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationCornerRadius(0)
            case .roomQR(let room):
                RoomQRSheet(room: room)
                    .spyGlobalToastLayer()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationCornerRadius(0)
            case .legal(let kind):
                LegalDocumentSheet(kind: kind)
                    .spyGlobalToastLayer()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationCornerRadius(0)
            }
        }
        .onAppear {
#if DEBUG
            presentPreviewSheetAfterShellMountIfNeeded()
#endif
        }
        .onChange(of: appState.activeRoom?.id) { _, roomID in
            guard roomID == nil, appState.selectedTab == .game else { return }
            appState.selectedTab = .home
        }
        .onChange(of: appState.shellRoute) { _, route in
            guard route == .main else { return }
            communityTab = .network
            communityDockRequest = .initial
        }
        .task(id: communityAttentionMonitorID) {
            guard appState.user != nil else {
                communityAttention = .empty
                communityNetworkState = nil
                communityAttentionRequestID = nil
                return
            }
            guard scenePhase == .active else { return }
            guard ShellSupplementaryRefreshPolicy.shouldRun(
                activeRoomStatus: appState.activeRoom?.normalizedStatus
            ) else { return }

#if DEBUG
            if let previewCount = communityAttentionPreviewCount {
                communityAttention = .preview(count: previewCount)
                return
            }
#endif

            await monitorCommunityAttention()
        }
        .task(id: notificationInboxMonitorID) {
            guard appState.user != nil else {
                PushNotificationCoordinator.shared.synchronizeBadgeCount(0)
                return
            }
            guard scenePhase == .active else { return }
            guard ShellSupplementaryRefreshPolicy.shouldRun(
                activeRoomStatus: appState.activeRoom?.normalizedStatus
            ) else { return }

#if DEBUG
            if appState.shouldUsePreviewData {
                appState.notificationInbox.installPreview(accountID: appState.user?.id)
                synchronizeNotificationBadge()
                return
            }
#endif

            await monitorNotificationInbox()
        }
        .onChange(of: appState.notificationInbox.unread.total, initial: true) { _, _ in
            synchronizeNotificationBadge()
        }
    }

    private var communityAttentionMonitorID: String {
        let userID = appState.user?.id ?? "signed-out"
        let activity = scenePhase == .active ? "active" : "inactive"
        let traffic = ShellSupplementaryRefreshPolicy.shouldRun(
            activeRoomStatus: appState.activeRoom?.normalizedStatus
        ) ? "supplementary" : "gameplay"
        return "\(userID):\(activity):\(traffic)"
    }

    private var notificationInboxMonitorID: String {
        let userID = appState.user?.id ?? "signed-out"
        let activity = scenePhase == .active ? "active" : "inactive"
        let traffic = ShellSupplementaryRefreshPolicy.shouldRun(
            activeRoomStatus: appState.activeRoom?.normalizedStatus
        ) ? "supplementary" : "gameplay"
        return "\(userID):\(activity):\(traffic):notifications"
    }

    private func monitorNotificationInbox() async {
        while !Task.isCancelled {
            await appState.notificationInbox.refreshSummary()
            synchronizeNotificationBadge()

            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }
        }
    }

    private func synchronizeNotificationBadge() {
        let count = appState.user == nil ? 0 : appState.notificationInbox.unread.total
        PushNotificationCoordinator.shared.synchronizeBadgeCount(count)
    }

    private func primaryTabPager(
        contentTab: AppTab,
        reservesDock: Bool
    ) -> some View {
        let tabs = AppTab.primaryCases
        let selectedIndex = tabs.firstIndex(of: contentTab) ?? 0

        return GeometryReader { proxy in
            let width = max(proxy.size.width, 1)

            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    Group {
                        if tab == contentTab || mountedPrimaryTabs.contains(tab) {
                            tab.makeContentView()
                                .environment(
                                    \.spyEntrancePresentationActive,
                                    tab == contentTab || tab == primarySwipeTarget
                                )
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .shellDockContentInset(visible: reservesDock)
                    .disabled(primarySwipeDirection != nil)
                    .allowsHitTesting(tab == contentTab && primarySwipeDirection == nil)
                    .accessibilityHidden(tab != contentTab)
                }
            }
            .frame(width: width * CGFloat(tabs.count), alignment: .leading)
            .frame(maxHeight: .infinity)
            .offset(x: (-CGFloat(selectedIndex) * width) + primarySwipeOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(
                contentSwipeGesture(
                    contentTab: contentTab,
                    isCommunityRoute: false,
                    viewportWidth: width
                ),
                including: .all
            )
        }
        .onAppear {
            mountedPrimaryTabs.insert(contentTab)
        }
        .onChange(of: contentTab) { _, tab in
            mountedPrimaryTabs.insert(tab)
        }
    }

    private func contentSwipeGesture(
        contentTab: AppTab,
        isCommunityRoute: Bool,
        viewportWidth: CGFloat?
    ) -> some Gesture {
        DragGesture(
            minimumDistance: TabSwipeResolver.gestureMinimumDistance,
            coordinateSpace: .global
        )
        .onChanged { value in
            guard let viewportWidth, !isCommunityRoute else { return }
            updatePrimarySwipe(
                translation: value.translation,
                startLocation: value.startLocation,
                contentTab: contentTab,
                viewportWidth: viewportWidth
            )
        }
        .onEnded { value in
            if let viewportWidth, !isCommunityRoute {
                finishPrimarySwipe(
                    translation: value.translation,
                    predictedTranslation: value.predictedEndTranslation,
                    contentTab: contentTab,
                    viewportWidth: viewportWidth
                )
                return
            }

            guard isCommunityRoute else { return }

            handleContentSwipe(
                translation: value.translation,
                startLocation: value.startLocation,
                contentTab: contentTab,
                isCommunityRoute: isCommunityRoute
            )
        }
    }

    private func updatePrimarySwipe(
        translation: CGSize,
        startLocation: CGPoint,
        contentTab: AppTab,
        viewportWidth: CGFloat
    ) {
        guard AppTab.primaryCases.contains(contentTab),
              canTrackPrimarySwipe(startLocation: startLocation) else {
            resetPrimarySwipe(animated: false)
            return
        }

        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        guard horizontal > vertical * TabSwipeResolver.horizontalDominanceRatio else { return }

        let direction: TabSwipeDirection = translation.width < 0 ? .next : .previous
        primarySwipeDirection = direction
        primarySwipeTarget = contentTab.primaryNeighbor(for: direction)

        if let primarySwipeTarget {
            mountedPrimaryTabs.formUnion([contentTab, primarySwipeTarget])
            primarySwipeOffset = max(-viewportWidth, min(viewportWidth, translation.width))
            primarySwipeProgress = min(abs(primarySwipeOffset) / max(viewportWidth, 1), 1)
        } else {
            primarySwipeOffset = translation.width * 0.12
            primarySwipeProgress = 0
        }
    }

    private func finishPrimarySwipe(
        translation: CGSize,
        predictedTranslation: CGSize,
        contentTab: AppTab,
        viewportWidth: CGFloat
    ) {
        guard let direction = primarySwipeDirection,
              let target = primarySwipeTarget,
              contentTab.primaryNeighbor(for: direction) == target else {
            resetPrimarySwipe(animated: true)
            return
        }

        let actualProgress = abs(primarySwipeOffset) / max(viewportWidth, 1)
        let projectedProgress = abs(predictedTranslation.width) / max(viewportWidth, 1)
        let projectedDirection: TabSwipeDirection = predictedTranslation.width < 0 ? .next : .previous
        let shouldCommit = actualProgress >= 0.28
            || (projectedDirection == direction && projectedProgress >= 0.42)

        guard shouldCommit else {
            resetPrimarySwipe(animated: true)
            return
        }

        let destination = direction == .next ? -viewportWidth : viewportWidth
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.24)) {
            primarySwipeOffset = destination
            primarySwipeProgress = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.12 : 0.24)) {
            guard primarySwipeTarget == target else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                appState.openMainTab(target)
                primarySwipeOffset = 0
                primarySwipeProgress = 0
                primarySwipeTarget = nil
                primarySwipeDirection = nil
            }
            HapticManager.shared.fire(.tabSelection)
        }
    }

    private func canTrackPrimarySwipe(startLocation: CGPoint) -> Bool {
        !isCommandMenuPresented
            && !showsBlockingRoomSyncOverlay
            && !appState.isShellChromeSuppressed
            && appState.presentedSheet == nil
            && appState.shellRoute == .main
            && !ShellTextInputActivity.isActive
            && !ShellHorizontalControlHitTest.containsInteractiveHorizontalControl(at: startLocation)
    }

    private func resetPrimarySwipe(animated: Bool) {
        let animation: Animation? = animated
            ? (reduceMotion ? .easeOut(duration: 0.10) : .smooth(duration: 0.22))
            : nil
        withAnimation(animation) {
            primarySwipeOffset = 0
            primarySwipeProgress = 0
        }

        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.10 : 0.22)) {
                guard primarySwipeOffset == 0 else { return }
                primarySwipeTarget = nil
                primarySwipeDirection = nil
            }
        } else {
            primarySwipeTarget = nil
            primarySwipeDirection = nil
        }
    }

    private func handleContentSwipe(
        translation: CGSize,
        startLocation: CGPoint,
        contentTab: AppTab,
        isCommunityRoute: Bool
    ) {
        guard !isCommandMenuPresented,
              !showsBlockingRoomSyncOverlay,
              !appState.isShellChromeSuppressed,
              appState.presentedSheet == nil,
              let direction = TabSwipeResolver.resolve(
                  translation: translation,
                  isTextInputActive: ShellTextInputActivity.isActive,
                  isInteractiveHorizontalControlActive: ShellHorizontalControlHitTest
                      .containsInteractiveHorizontalControl(at: startLocation)
              ) else {
            return
        }

        if isCommunityRoute {
            guard let target = communityTab.swipeNeighbor(for: direction) else { return }
            requestCommunityTab(target)
            return
        }

        guard appState.shellRoute == .main,
              appState.selectedTab == contentTab,
              let target = contentTab.primaryNeighbor(for: direction) else {
            return
        }

        HapticManager.shared.fire(.tabSelection)
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.20)) {
            appState.openMainTab(target)
        }
    }

    private func requestCommunityTab(_ tab: CommunityTab) {
        // CommunityView commits the visible selection only after its target is
        // available. In particular, a cold-load Me request must not make the
        // dock claim success while the directory is still on screen.
        communityDockRequest = communityDockRequest.next(tab)
    }

#if DEBUG
    private var communityAttentionPreviewCount: Int? {
        ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--spyclash-preview-community-attention=") }
            .flatMap { Int($0.dropFirst("--spyclash-preview-community-attention=".count)) }
            .map { max(0, $0) }
    }
#endif

    private func monitorCommunityAttention() async {
        while !Task.isCancelled {
            await refreshCommunityAttention()

            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }
        }
    }

    private func refreshCommunityAttention() async {
        guard let userID = appState.user?.id else {
            communityAttention = .empty
            communityNetworkState = nil
            communityAttentionRequestID = nil
            return
        }

        let requestID = UUID()
        communityAttentionRequestID = requestID

        do {
            let state = try await appState.client.communityState()
            guard !Task.isCancelled,
                  appState.user?.id == userID,
                  communityAttentionRequestID == requestID else {
                return
            }
            installCommunityAttention(state, for: userID, announceNew: true)
            await retryPendingRoomInviteCleanups(for: userID)
        } catch is CancellationError {
            return
        } catch {
            // Attention polling is supplementary. Community keeps its own
            // visible retry/error path, so a transient poll must stay silent.
        }

        if communityAttentionRequestID == requestID {
            communityAttentionRequestID = nil
        }
    }

    private func installCommunityAttention(
        _ state: CommunityState,
        for userID: String? = nil,
        announceNew: Bool
    ) {
        guard let resolvedUserID = userID ?? appState.user?.id else {
            communityAttention = .empty
            return
        }

        let visibleState = stateHidingPendingRoomInviteCleanups(state, userID: resolvedUserID)
        let next = CommunityAttentionSnapshot(state: visibleState)
        let seenIDs = storedCommunityAttentionIDs(for: resolvedUserID)
        let newIDs = next.allIDs.subtracting(seenIDs)

        communityAttention = next
        communityNetworkState = visibleState
        guard !newIDs.isEmpty else { return }

        storeCommunityAttentionIDs(seenIDs.union(next.allIDs), for: resolvedUserID)
        if announceNew {
            publishCommunityAttentionToast(for: next, newIDs: newIDs)
        }
    }

    private func publishCommunityAttentionToast(
        for snapshot: CommunityAttentionSnapshot,
        newIDs: Set<String>
    ) {
        let newFriendCount = snapshot.friendRequestIDs.intersection(newIDs).count
        let newRoomInviteCount = snapshot.roomInviteIDs.intersection(newIDs).count
        let title: String
        let detail: String
        let systemImage: String

        if newRoomInviteCount > 0, newFriendCount > 0 {
            title = localizedCommunityAttention(
                en: "NEW COMMUNITY ACTIVITY",
                ru: "НОВОЕ В СООБЩЕСТВЕ",
                es: "NOVEDADES EN COMUNIDAD",
                uk: "НОВА АКТИВНІСТЬ У СПІЛЬНОТІ"
            )
            detail = localizedCommunityAttention(
                en: "Room invite and friend request received.",
                ru: "Получены приглашение в комнату и запрос в друзья.",
                es: "Recibiste una invitacion y una solicitud de amistad.",
                uk: "Отримано запрошення до кімнати та запит у друзі."
            )
            systemImage = "bell.badge.fill"
        } else if newRoomInviteCount > 0 {
            title = localizedCommunityAttention(
                en: "ROOM INVITE RECEIVED",
                ru: "ПРИГЛАШЕНИЕ В КОМНАТУ",
                es: "INVITACIÓN A UNA SALA",
                uk: "ЗАПРОШЕННЯ ДО КІМНАТИ"
            )
            detail = snapshot.senderName(forRoomInviteIDs: newIDs).map {
                localizedCommunityAttention(
                    en: "From \($0). Open Community to respond.",
                    ru: "От \($0). Откройте Сообщество, чтобы ответить.",
                    es: "De \($0). Abre Comunidad para responder.",
                    uk: "Від \($0). Відкрийте Спільноту, щоб відповісти."
                )
            } ?? localizedCommunityAttention(
                en: "Open Community to respond.",
                ru: "Откройте Сообщество, чтобы ответить.",
                es: "Abre Comunidad para responder.",
                uk: "Відкрийте Спільноту, щоб відповісти."
            )
            systemImage = "door.left.hand.open"
        } else {
            title = localizedCommunityAttention(
                en: "NEW FRIEND REQUEST",
                ru: "НОВЫЙ ЗАПРОС В ДРУЗЬЯ",
                es: "NUEVA SOLICITUD DE AMISTAD",
                uk: "НОВИЙ ЗАПИТ У ДРУЗІ"
            )
            detail = snapshot.senderName(forFriendRequestIDs: newIDs).map {
                localizedCommunityAttention(
                    en: "From \($0). Open Community to respond.",
                    ru: "От \($0). Откройте Сообщество, чтобы ответить.",
                    es: "De \($0). Abre Comunidad para responder.",
                    uk: "Від \($0). Відкрийте Спільноту, щоб відповісти."
                )
            } ?? localizedCommunityAttention(
                en: "Open Community to respond.",
                ru: "Откройте Сообщество, чтобы ответить.",
                es: "Abre Comunidad para responder.",
                uk: "Відкрийте Спільноту, щоб відповісти."
            )
            systemImage = "person.crop.circle.badge.plus"
        }

        HapticManager.shared.fire(.notification(.warning))
        appState.showToast(
            title,
            kind: .warning,
            detail: detail,
            systemImage: systemImage,
            duration: .seconds(5)
        )
    }

    private func storedCommunityAttentionIDs(for userID: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: communityAttentionStorageKey(for: userID)) ?? [])
    }

    private func storeCommunityAttentionIDs(_ ids: Set<String>, for userID: String) {
        UserDefaults.standard.set(Array(ids).sorted(), forKey: communityAttentionStorageKey(for: userID))
    }

    private func communityAttentionStorageKey(for userID: String) -> String {
        "spyclash.community-attention.seen.\(userID)"
    }

    private func pendingRoomInviteCleanupStorageKey(userID: String) -> String {
        "spyclash.community-room-invite-cleanup.\(userID)"
    }

    private func pendingRoomInviteCleanupIDs(for userID: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(
            forKey: pendingRoomInviteCleanupStorageKey(userID: userID)
        ) ?? [])
    }

    private func removePendingRoomInviteCleanup(_ inviteID: String, userID: String) {
        let key = pendingRoomInviteCleanupStorageKey(userID: userID)
        var pendingIDs = pendingRoomInviteCleanupIDs(for: userID)
        pendingIDs.remove(inviteID)
        if pendingIDs.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(Array(pendingIDs).sorted(), forKey: key)
        }
    }

    private func stateHidingPendingRoomInviteCleanups(
        _ state: CommunityState,
        userID: String
    ) -> CommunityState {
        var hiddenInviteIDs = pendingRoomInviteCleanupIDs(for: userID)
        guard !hiddenInviteIDs.isEmpty else { return state }
        let reusedPendingIDs = Set(
            state.incomingRoomInvites
                .filter {
                    hiddenInviteIDs.contains($0.id) && $0.status.lowercased() == "pending"
                }
                .map(\.id)
        )
        for inviteID in reusedPendingIDs {
            removePendingRoomInviteCleanup(inviteID, userID: userID)
        }
        hiddenInviteIDs.subtract(reusedPendingIDs)
        return CommunityState(
            me: state.me,
            friends: state.friends,
            incoming: state.incoming,
            outgoing: state.outgoing,
            blocked: state.blocked,
            incomingRoomInvites: state.incomingRoomInvites.filter {
                !hiddenInviteIDs.contains($0.id)
            }
        )
    }

    private func retryPendingRoomInviteCleanups(for userID: String) async {
        let pendingIDs = pendingRoomInviteCleanupIDs(for: userID)
        guard !pendingIDs.isEmpty else { return }

        for inviteID in pendingIDs.sorted() {
            guard !Task.isCancelled, appState.user?.id == userID else { return }
            do {
                _ = try await appState.client.communityRoomInviteAction(
                    "consume_room_invite",
                    inviteID: inviteID
                )
                guard appState.user?.id == userID else { return }
                removePendingRoomInviteCleanup(inviteID, userID: userID)
            } catch let error as Base44Error
                where error.statusCode == 404 || error.statusCode == 409 {
                guard appState.user?.id == userID else { return }
                removePendingRoomInviteCleanup(inviteID, userID: userID)
            } catch {
                continue
            }
        }
    }

    private func localizedCommunityAttention(en: String, ru: String, es: String, uk: String) -> String {
        return switch appState.language {
        case .en: en
        case .ru: ru
        case .es: es
        case .uk: uk
        }
    }

    private var showsBlockingRoomSyncOverlay: Bool {
        guard let operation = appState.roomSyncOperation else { return false }
        if case .updatingDuration = operation { return false }
        return true
    }

    private var roomSyncBlurRadius: CGFloat {
        guard let operation = appState.roomSyncOperation else { return 0 }
        switch operation {
        case .updatingDuration:
            return 0
        case .creatingRoom, .closingRoom:
            return 1.2
        default:
            return 0.8
        }
    }

#if DEBUG
    private func presentPreviewSheetAfterShellMountIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        let previewSheet = arguments
            .first { $0.hasPrefix("--spyclash-preview-sheet=") }
            .map { String($0.dropFirst("--spyclash-preview-sheet=".count)) }

        guard let previewSheet else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            switch previewSheet {
            case "community":
                appState.openCommunity()
            case "notifications", "inbox":
                appState.notificationInbox.installPreview(accountID: appState.user?.id ?? "debug-ui-preview-user")
                appState.openNotifications()
            case "privacy":
                appState.presentedSheet = .legal(.privacy)
            case "terms":
                appState.presentedSheet = .legal(.terms)
            case "roomQR", "room-qr", "qr":
                appState.presentedSheet = .roomQR(appState.activeRoom ?? GameRoom.previewRoom(status: "waiting"))
            case "scanner", "qrScanner", "qr-scanner":
                appState.presentedSheet = .qrScanner
            default:
                break
            }
        }
    }
#endif
}

private struct RoomSynchronizationOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let operation: RoomSyncOperation
    let language: AppLanguage

    @State private var isSpinning = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.08)

            if operation == .creatingRoom || operation == .closingRoom {
                RoomSynchronizationTerminalLine(operation: operation, language: language)
            } else {
                Circle()
                    .trim(from: 0.12, to: 0.82)
                    .stroke(
                        SpyTheme.red,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .frame(width: 34, height: 34)
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(operation.title(for: language)). \(operation.detail(for: language))")
        .accessibilityIdentifier("roomSync.overlay")
        .onAppear {
            guard operation != .creatingRoom,
                  operation != .closingRoom,
                  !reduceMotion else { return }
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                isSpinning = true
            }
        }
    }
}

private struct RoomSynchronizationTerminalLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let operation: RoomSyncOperation
    let language: AppLanguage

    @State private var renderedText = ""
    @State private var isCursorVisible = true

    var body: some View {
        HStack(spacing: 0) {
            Text("> ")
                .foregroundStyle(SpyTheme.red)
            Text(renderedText)
                .foregroundStyle(.white.opacity(0.88))
            Text("_")
                .foregroundStyle(SpyTheme.red)
                .opacity(isCursorVisible ? 1 : 0.18)
                .scaleEffect(x: isCursorVisible ? 1 : 0.45, anchor: .leading)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.12),
                    value: isCursorVisible
                )
                .task {
                    isCursorVisible = true
                    guard !reduceMotion else { return }

                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(480))
                        guard !Task.isCancelled else { return }
                        isCursorVisible.toggle()
                    }
                }
        }
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .tracking(0.7)
        .task(id: terminalText) {
            renderedText = ""
            guard !reduceMotion else {
                renderedText = terminalText
                return
            }

            for character in terminalText {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(55))
                guard !Task.isCancelled else { return }
                renderedText.append(character)
            }
        }
    }

    private var terminalText: String {
        switch (operation, language) {
        case (.creatingRoom, .ru): "Создание комнаты"
        case (.creatingRoom, .es): "Creando sala"
        case (.creatingRoom, .uk): "Створення кімнати"
        case (.creatingRoom, _): "Creating Room"
        case (.closingRoom, .ru): "Закрытие комнаты"
        case (.closingRoom, .es): "Cerrando sala"
        case (.closingRoom, .uk): "Закриття кімнати"
        case (.closingRoom, _): "Shutting Down"
        default: operation.title(for: language)
        }
    }
}

private struct PullDownCommandMenu: View {
    @Binding var isPresented: Bool
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragTranslation: CGFloat = 0
    @State private var didFireDragHaptic = false

    var body: some View {
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top
            let visualTopInset = topInset > 0 ? min(topInset, 54) : 54
            let travelDistance = min(proxy.size.height * 0.62, 500)
            let closedHandleHeight = max(visualTopInset + 88, 142)
            let openHandleHeight: CGFloat = 58
            let visibleHeight = drawerHeight(
                travelDistance: travelDistance,
                closedHandleHeight: closedHandleHeight,
                translation: dragTranslation
            )
            let openProgress = progressFromHeight(
                visibleHeight,
                travelDistance: travelDistance,
                closedHandleHeight: closedHandleHeight
            )
            let contentProgress = smoothStep(clamp((openProgress - 0.08) / 0.78))
            let handleProgress = smoothStep(openProgress)
            let handleHeight = closedHandleHeight - ((closedHandleHeight - openHandleHeight) * handleProgress)
            let restingHeight = isPresented ? closedHandleHeight + travelDistance : closedHandleHeight
            let hasVisibleDrag = abs(visibleHeight - restingHeight) > 0.5
            let isInteracting = hasVisibleDrag || didFireDragHaptic
            let hitAreaHeight = isPresented || openProgress > 0.08 ? proxy.size.height : visibleHeight

            ZStack(alignment: .top) {
                if isPresented || openProgress > 0.08 {
                    Color.black
                        .opacity(0.20 * openProgress)
                        .ignoresSafeArea()
                        .onTapGesture {
                            closeMenu()
                        }
                        .transition(.opacity)
                }

                drawerSurface(
                    topInset: visualTopInset,
                    travelDistance: travelDistance,
                    closedHandleHeight: closedHandleHeight,
                    visibleHeight: visibleHeight,
                    handleHeight: handleHeight,
                    openProgress: openProgress,
                    contentProgress: contentProgress,
                    isInteracting: isInteracting
                )

            }
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: hitAreaHeight, alignment: .top)
            .transaction { transaction in
                if isInteracting {
                    transaction.animation = nil
                }
            }
        }
        .ignoresSafeArea()
    }

    private func commandMenuGesture(travelDistance: CGFloat, closedHandleHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let directionalTranslation = dragDirectionAdjusted(value.translation.height)
                let meaningfulDrag = abs(directionalTranslation) > 1.5

                if !didFireDragHaptic, meaningfulDrag {
                    didFireDragHaptic = true
                    HapticManager.shared.fire(.tabSelection)
                }

                updateDragTranslation(directionalTranslation)
            }
            .onEnded { value in
                didFireDragHaptic = false

                let predictedHeight = drawerHeight(
                    travelDistance: travelDistance,
                    closedHandleHeight: closedHandleHeight,
                    translation: dragDirectionAdjusted(value.predictedEndTranslation.height)
                )
                let settledHeight = drawerHeight(
                    travelDistance: travelDistance,
                    closedHandleHeight: closedHandleHeight,
                    translation: dragDirectionAdjusted(value.translation.height)
                )
                let predictedProgress = progressFromHeight(
                    predictedHeight,
                    travelDistance: travelDistance,
                    closedHandleHeight: closedHandleHeight
                )
                let settledProgress = progressFromHeight(
                    settledHeight,
                    travelDistance: travelDistance,
                    closedHandleHeight: closedHandleHeight
                )

                setMenuPresented(shouldPresentAfterRelease(predictedProgress: predictedProgress, settledProgress: settledProgress))
            }
    }

    private func drawerSurface(
        topInset: CGFloat,
        travelDistance: CGFloat,
        closedHandleHeight: CGFloat,
        visibleHeight: CGFloat,
        handleHeight: CGFloat,
        openProgress: CGFloat,
        contentProgress: CGFloat,
        isInteracting: Bool
    ) -> some View {
        let drawerCut = 18 + (openProgress * 8)
        let menuHeight = max(320, visibleHeight - 8)
        let shouldRenderMenu = isPresented || openProgress > 0.04

        return ZStack(alignment: .bottom) {
            if shouldRenderMenu {
                CompactCommandMenuPanel(
                    progress: contentProgress,
                    topInset: topInset,
                    close: closeMenu
                )
                    .frame(maxWidth: 430)
                    .frame(height: menuHeight, alignment: .top)
                    .padding(.horizontal, 0)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .opacity(contentProgress)
                    .offset(y: reduceMotion ? 0 : -14 + (contentProgress * 14))
                    .allowsHitTesting(contentProgress > 0.86)
            }

            drawerTopChrome(
                progress: openProgress,
                isInteracting: isInteracting
            )
            .frame(height: handleHeight, alignment: .bottom)
            .contentShape(Rectangle())
            .accessibilityLabel(
                isPresented
                    ? localized(en: "Close command menu", ru: "Закрыть командное меню", es: "Cerrar menú de comandos", uk: "Закрити командне меню")
                    : localized(en: "Pull down command menu", ru: "Потяните вниз, чтобы открыть командное меню", es: "Desliza hacia abajo para abrir el menú de comandos", uk: "Потягніть униз, щоб відкрити командне меню")
            )
            .highPriorityGesture(commandMenuGesture(travelDistance: travelDistance, closedHandleHeight: closedHandleHeight))
        }
        .frame(maxWidth: .infinity)
        .frame(height: visibleHeight, alignment: .top)
        .background {
            drawerBrandSurface(cut: drawerCut, progress: openProgress)
        }
        .overlay {
            drawerShape(cut: drawerCut)
                .stroke(
                    LinearGradient(
                        colors: [
                            SpyTheme.red.opacity(openProgress > 0.08 ? 0.64 : 0.18),
                            SpyTheme.strokeStrong.opacity(0.78),
                            SpyTheme.red.opacity(openProgress > 0.08 ? 0.38 : 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .overlay(alignment: .bottom) {
            closedChromeBottomBreak(progress: openProgress)
        }
        .overlay(alignment: .bottom) {
            if openProgress < 0.52 {
                closedChromeMarker(topInset: topInset, progress: openProgress, isInteracting: isInteracting)
                    .frame(height: closedHandleHeight)
                    .opacity(Double(1 - clamp(openProgress * 1.9)))
                    .allowsHitTesting(false)
            }
        }
        .clipShape(drawerShape(cut: drawerCut))
        .shadow(
            color: .black.opacity(0.58 - (openProgress * 0.12)),
            radius: 24 + (openProgress * 12),
            y: 13 + (openProgress * 6)
        )
        .contentShape(Rectangle())
    }

    private func drawerBrandSurface(cut: CGFloat, progress: CGFloat) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            let openBias = smoothStep(progress)
            let closedBias = 1 - smoothStep(clamp(progress * 1.7))

            ZStack {
                drawerShape(cut: cut)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color(red: 3 / 255, green: 3 / 255, blue: 4 / 255), location: 0.00),
                                .init(color: Color(red: 11 / 255, green: 8 / 255, blue: 9 / 255), location: 0.58),
                                .init(color: Color(red: 2 / 255, green: 2 / 255, blue: 3 / 255), location: 1.00)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(0.60 * closedBias), location: 0.00),
                        .init(color: Color(red: 10 / 255, green: 6 / 255, blue: 7 / 255).opacity(0.26 * closedBias), location: 0.58),
                        .init(color: .clear, location: 1.00)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: min(size.height, 152), alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                RadialGradient(
                    colors: [
                        SpyTheme.red.opacity(0.030 + (0.020 * openBias)),
                        SpyTheme.red.opacity(0.010 + (0.010 * openBias)),
                        .clear
                    ],
                    center: UnitPoint(x: 0.20, y: 0.46),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.62
                )

                RadialGradient(
                    colors: [
                        Color(red: 100 / 255, green: 100 / 255, blue: 150 / 255).opacity(0.028),
                        .clear
                    ],
                    center: UnitPoint(x: 0.82, y: 0.22),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.50
                )
                .opacity(0.72 + (0.28 * openBias))

                RadialGradient(
                    colors: [
                        SpyTheme.red.opacity(0.016 + (0.018 * openBias)),
                        .clear
                    ],
                    center: UnitPoint(x: 0.50, y: 0.94),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.42
                )

                Canvas { context, canvasSize in
                    var path = Path()
                    let spacing: CGFloat = 50

                    stride(from: CGFloat.zero, through: canvasSize.width, by: spacing).forEach { x in
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: canvasSize.height))
                    }
                    stride(from: CGFloat.zero, through: canvasSize.height, by: spacing).forEach { y in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: canvasSize.width, y: y))
                    }

                    context.stroke(path, with: .color(SpyTheme.red.opacity(0.014 + (0.018 * openBias))), lineWidth: 1)
                }
                .mask {
                    RadialGradient(
                        stops: [
                            .init(color: .black.opacity(0.78), location: 0.20),
                            .init(color: .black.opacity(0.36), location: 0.75),
                            .init(color: .clear, location: 1.00)
                        ],
                        center: .center,
                        startRadius: min(size.width, size.height) * 0.12,
                        endRadius: max(size.width, size.height) * 0.82
                    )
                }

                LinearGradient(
                    colors: [
                        .clear,
                        SpyTheme.red.opacity(0.035 + (0.020 * openBias)),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)
                .offset(y: size.height * 0.33)

                LinearGradient(
                    colors: [
                        SpyTheme.black.opacity(0.00),
                        SpyTheme.black.opacity(0.22 - (0.08 * openBias))
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                LinearGradient(
                    colors: [
                        .clear,
                        Color.white.opacity(0.035),
                        .clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .clipShape(drawerShape(cut: cut))
        }
        .allowsHitTesting(false)
    }

    private var drawerContentFadeMask: some View {
        VStack(spacing: 0) {
            Color.white

            LinearGradient(
                stops: [
                    .init(color: .white, location: 0.00),
                    .init(color: .white.opacity(0.96), location: 0.28),
                    .init(color: .white.opacity(0.74), location: 0.58),
                    .init(color: .white.opacity(0.26), location: 0.86),
                    .init(color: .clear, location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 118)
        }
    }

    private var drawerBottomContentVeil: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: SpyTheme.graphite.opacity(0.00), location: 0.00),
                    .init(color: SpyTheme.graphite.opacity(0.00), location: 0.30),
                    .init(color: Color(red: 12 / 255, green: 8 / 255, blue: 9 / 255).opacity(0.10), location: 0.54),
                    .init(color: Color(red: 12 / 255, green: 8 / 255, blue: 9 / 255).opacity(0.42), location: 0.78),
                    .init(color: Color(red: 12 / 255, green: 8 / 255, blue: 9 / 255).opacity(0.78), location: 0.93),
                    .init(color: Color(red: 12 / 255, green: 8 / 255, blue: 9 / 255).opacity(0.92), location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .blur(radius: 0.35)

            LinearGradient(
                stops: [
                    .init(color: SpyTheme.graphite.opacity(0.00), location: 0.00),
                    .init(color: Color(red: 12 / 255, green: 8 / 255, blue: 9 / 255).opacity(0.38), location: 0.46),
                    .init(color: Color(red: 12 / 255, green: 8 / 255, blue: 9 / 255).opacity(0.90), location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 50)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 112)
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [
                    SpyTheme.red.opacity(0.00),
                    SpyTheme.red.opacity(0.08),
                    SpyTheme.red.opacity(0.00)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, 76)
            .padding(.bottom, 1)
        }
    }

    private func drawerShape(cut: CGFloat) -> DrawerCutShape {
        DrawerCutShape(cut: cut)
    }

    private func closedChromeBottomBreak(progress: CGFloat) -> some View {
        let alpha = Double(1 - smoothStep(clamp(progress * 2.5)))

        return VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    SpyTheme.red.opacity(0.00),
                    SpyTheme.red.opacity(0.20),
                    SpyTheme.strokeStrong.opacity(0.62),
                    SpyTheme.red.opacity(0.10),
                    SpyTheme.red.opacity(0.00)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, 34)

            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.34), location: 0.00),
                    .init(color: Color.black.opacity(0.16), location: 0.40),
                    .init(color: .clear, location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 18)
        }
        .opacity(alpha)
        .allowsHitTesting(false)
    }

    private func drawerTopChrome(progress: CGFloat, isInteracting: Bool) -> some View {
        let gripWidth = 36 + (progress * 18) + (isInteracting ? 8 : 0)
        let gripOpacity = 0.42 + (progress * 0.20) + (isInteracting ? 0.16 : 0)
        let openChromeOpacity = Double(smoothStep(clamp((progress - 0.18) / 0.24)) * (1 - smoothStep(clamp((progress - 0.48) / 0.18))))

        return ZStack(alignment: .bottom) {
            grabberBars(width: gripWidth, opacity: gripOpacity, progress: progress, isInteracting: isInteracting)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .padding(.bottom, 8)
                .opacity(openChromeOpacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .bottom) {
            bottomChromeFill(progress: progress)
        }
        .contentShape(Rectangle())
    }

    private func closedChromeMarker(topInset: CGFloat, progress: CGFloat, isInteracting: Bool) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                spyClashLogo(fontSize: 18)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white.opacity(0.88))
                    .rotationEffect(.degrees(progress * 180))
                    .frame(width: 40, height: 32)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 28)
            .opacity(Double(1 - clamp(progress * 2.4)))

            grabberBars(
                    width: 38 + (isInteracting ? 8 : 0),
                    opacity: isInteracting ? 0.62 : 0.48,
                    progress: progress,
                    isInteracting: isInteracting
                )

            Text("\(statusLinePrefix)  •  \(statusLineValue)")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(0.22)
                .foregroundStyle(statusLineColor(progress: progress))
                .spyFitted(scale: 0.66, alignment: .center)
                .padding(.horizontal, 18)
                .shadow(color: .black.opacity(0.80), radius: 8, y: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, max(10, topInset + 2))
    }

    private func spyClashLogo(fontSize: CGFloat) -> some View {
        ShellWordmark(fontSize: fontSize)
            .shadow(color: .black.opacity(0.70), radius: 8, y: 3)
    }

    private func grabberBars(width: CGFloat, opacity: CGFloat, progress: CGFloat, isInteracting: Bool) -> some View {
        ZStack {
            Capsule()
                .fill((isInteracting ? SpyTheme.red : Color.white).opacity(opacity))
                .frame(width: width, height: 4)
                .shadow(color: SpyTheme.red.opacity(isInteracting ? 0.40 : 0.12 * progress), radius: 8 + (progress * 7))

            Capsule()
                .fill(Color.white.opacity(0.08 + (progress * 0.12)))
                .frame(width: max(22, width * 0.62), height: 2)
                .offset(y: 9)
        }
        .frame(width: 96, height: 18)
    }

    private func bottomChromeFill(progress: CGFloat) -> some View {
        LinearGradient(
            colors: [.clear, SpyTheme.graphite.opacity(0.08 * smoothStep(progress))],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 8)
        .allowsHitTesting(false)
    }

    private var statusLineValue: String {
        if let room = appState.activeRoom {
            return appState.language.home.statusLabel(room.status).uppercased()
        }
        return localized(en: "ONLINE", ru: "В СЕТИ", es: "EN LÍNEA", uk: "У МЕРЕЖІ")
    }

    private var statusLinePrefix: String {
        localized(en: "STATUS:", ru: "СТАТУС:", es: "ESTADO:", uk: "СТАТУС:")
    }

    private func statusLineColor(progress: CGFloat) -> Color {
        SpyTheme.red
    }

    private func dragDirectionAdjusted(_ translation: CGFloat) -> CGFloat {
        if isPresented {
            min(0, translation)
        } else {
            max(0, translation)
        }
    }

    private func drawerHeight(travelDistance: CGFloat, closedHandleHeight: CGFloat, translation: CGFloat) -> CGFloat {
        let openHeight = closedHandleHeight + travelDistance
        let restingHeight = isPresented ? openHeight : closedHandleHeight
        let rawHeight = restingHeight + translation
        return min(openHeight, max(closedHandleHeight, rawHeight))
    }

    private func progressFromHeight(_ height: CGFloat, travelDistance: CGFloat, closedHandleHeight: CGFloat) -> CGFloat {
        clamp((height - closedHandleHeight) / max(travelDistance, 1))
    }

    private func shouldPresentAfterRelease(predictedProgress: CGFloat, settledProgress: CGFloat) -> Bool {
        if isPresented {
            return !(predictedProgress < 0.74 || settledProgress < 0.80)
        }

        return predictedProgress > 0.18 || settledProgress > 0.12
    }

    private func updateDragTranslation(_ value: CGFloat) {
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            dragTranslation = value
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        let clamped = clamp(value)
        return clamped * clamped * (3 - (2 * clamped))
    }

    private func localized(en: String, ru: String, es: String, uk: String) -> String {
        switch appState.language {
        case .en: en
        case .ru: ru
        case .es: es
        case .uk: uk
        }
    }

    private func closeMenu() {
        setMenuPresented(false)
    }

    private func setMenuPresented(_ presented: Bool) {
        if isPresented != presented {
            HapticManager.shared.fire(.buttonPress)
        }

        let animation: Animation = reduceMotion ? .easeOut(duration: 0.18) : settleAnimation
        withAnimation(animation) {
            isPresented = presented
            dragTranslation = 0
        }
    }

    private var settleAnimation: Animation {
        .timingCurve(0.18, 0.86, 0.18, 1.0, duration: 0.34)
    }
}

private struct CompactCommandMenuPanel: View {
    @Environment(AppState.self) private var appState

    let progress: CGFloat
    let topInset: CGFloat
    let close: () -> Void

    private var profileCopy: ProfileCopy {
        appState.language.profile
    }

    var body: some View {
        ZStack {
            menuSurface

            VStack(alignment: .leading, spacing: 0) {
                header
                    .opacity(phase(0.02, 0.24))
                    .offset(y: stagedOffset(0.02, 0.24, distance: -14))

                Spacer(minLength: 34)

                VStack(alignment: .leading, spacing: 4) {
                    menuRow(
                        icon: "👤",
                        title: appState.language.tabTitle(.profile),
                        selected: appState.selectedTab == .profile,
                        phaseStart: 0.22
                    ) {
                        closeThen { appState.openMainTab(.profile) }
                    }

                    menuRow(
                        icon: "📦",
                        title: appState.language.tabTitle(.packs),
                        selected: appState.selectedTab == .packs,
                        phaseStart: 0.32
                    ) {
                        closeThen { appState.openMainTab(.packs) }
                    }

                    menuRow(
                        icon: "🪪",
                        title: localized(en: "COMMUNITY", ru: "СООБЩЕСТВО", es: "COMUNIDAD", uk: "СПІЛЬНОТА"),
                        selected: appState.shellRoute == .community,
                        phaseStart: 0.42
                    ) {
                        closeThen { appState.openCommunity() }
                    }

                    Rectangle()
                        .fill(SpyTheme.strokeStrong.opacity(0.58))
                        .frame(height: 1)
                        .padding(.vertical, 11)
                        .opacity(phase(0.56, 0.70))

                    menuRow(
                        icon: "🚪",
                        title: profileCopy.logOut,
                        highlighted: true,
                        phaseStart: 0.62
                    ) {
                        close()
                        appState.logout()
                    }
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 16)

                languageFooter
                    .opacity(phase(0.62, 0.90))
                    .offset(y: stagedOffset(0.62, 0.90, distance: 14))
            }
            .padding(.top, topInset + 24)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var menuSurface: some View {
        ZStack {
            Color.black

            RadialGradient(
                colors: [
                    SpyTheme.red.opacity(0.060),
                    SpyTheme.red.opacity(0.022),
                    .clear
                ],
                center: UnitPoint(x: 0.18, y: 0.44),
                startRadius: 0,
                endRadius: 360
            )

            LinearGradient(
                colors: [
                    .clear,
                    SpyTheme.red.opacity(0.040),
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            menuGrid
                .opacity(0.40)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(SpyTheme.strokeStrong.opacity(0.38))
                .frame(height: 1)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(SpyTheme.red.opacity(0.90))
                .frame(width: 2)
                .opacity(phase(0.28, 0.62))
        }
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [
                    SpyTheme.red.opacity(0.00),
                    SpyTheme.red.opacity(0.82),
                    SpyTheme.red.opacity(0.00)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, 10)
            .opacity(phase(0.42, 0.80))
        }
        .overlay {
            menuCorners
                .opacity(phase(0.08, 0.36))
        }
    }

    private var menuGrid: some View {
        Canvas { context, size in
            var path = Path()
            let spacing: CGFloat = 58

            stride(from: CGFloat.zero, through: size.width, by: spacing).forEach { x in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }

            stride(from: CGFloat.zero, through: size.height, by: spacing).forEach { y in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }

            context.stroke(path, with: .color(SpyTheme.red.opacity(0.035)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    private var menuCorners: some View {
        VStack {
            HStack {
                CornerStroke(color: Color.white.opacity(0.55))
                    .frame(width: 18, height: 18)
                Spacer()
                CornerStroke(color: Color.white.opacity(0.55))
                    .rotationEffect(.degrees(90))
                    .frame(width: 18, height: 18)
            }

            Spacer()

            HStack {
                CornerStroke(color: SpyTheme.red)
                    .rotationEffect(.degrees(270))
                    .frame(width: 18, height: 18)
                Spacer()
                CornerStroke(color: SpyTheme.red)
                    .rotationEffect(.degrees(180))
                    .frame(width: 18, height: 18)
            }
        }
        .padding(10)
        .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                spyClashLogo(fontSize: 30)
                SpyAppVersionMark()
            }

            Spacer()

            Button {
                close()
            } label: {
                menuLines
                    .frame(width: 56, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SpyWebPressStyle())
            .accessibilityLabel(localized(en: "Close menu", ru: "Закрыть меню", es: "Cerrar menu", uk: "Закрити меню"))
        }
        .padding(.horizontal, 28)
    }

    private var menuLines: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Capsule()
                .frame(width: 26, height: 3)
            Capsule()
                .frame(width: 26, height: 3)
            Capsule()
                .frame(width: 18, height: 3)
        }
        .foregroundStyle(SpyTheme.red)
        .shadow(color: SpyTheme.red.opacity(0.25), radius: 7)
    }

    private func spyClashLogo(fontSize: CGFloat) -> some View {
        ShellWordmark(fontSize: fontSize)
            .shadow(color: .black.opacity(0.70), radius: 8, y: 3)
    }

    private var languageFooter: some View {
        HStack(spacing: 12) {
            Text(localized(en: "LANG", ru: "ЯЗЫК", es: "IDIOMA", uk: "МОВА"))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.22)
                .foregroundStyle(SpyTheme.faint)
                .spyFitted(scale: 0.74)

            HStack(spacing: 6) {
                languageChip(.en)
                languageChip(.es)
                languageChip(.ru)
                languageChip(.uk)
            }

            Spacer()

            Button {
                close()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(SpyTheme.red)
                    .frame(width: 46, height: 40)
                    .background(Color.black.opacity(0.42), in: CutCornerShape(cut: 6))
                    .overlay(CutCornerShape(cut: 6).stroke(SpyTheme.strokeStrong.opacity(0.88), lineWidth: 1))
            }
            .buttonStyle(SpyWebPressStyle())
            .accessibilityLabel(localized(en: "Close menu", ru: "Закрыть меню", es: "Cerrar menu", uk: "Закрити меню"))
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(SpyTheme.strokeStrong.opacity(0.42))
                .frame(height: 1)
                .padding(.horizontal, 24)
        }
    }

    private func languageChip(_ language: AppLanguage) -> some View {
        Button {
            HapticManager.shared.fire(.buttonPress)
            Task {
                try? await appState.setLanguage(language, syncRemote: appState.user != nil)
            }
        } label: {
            Text(language.shortCode)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(0.08)
                .foregroundStyle(appState.language == language ? .white : SpyTheme.dim)
                .frame(minWidth: 42, minHeight: 36)
                .background(appState.language == language ? SpyTheme.red : Color.clear, in: CutCornerShape(cut: 4))
                .overlay(CutCornerShape(cut: 4).stroke(appState.language == language ? SpyTheme.red : SpyTheme.inputBorder, lineWidth: 1))
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private func menuRow(
        icon: String,
        title: String,
        selected: Bool = false,
        highlighted: Bool = false,
        phaseStart: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        let rowProgress = phase(phaseStart, phaseStart + 0.22)

        return Button(action: action) {
            HStack(spacing: 12) {
                Text(icon)
                    .font(.system(size: 24, weight: .black))
                    .frame(width: 35)

                Text(title)
                    .font(.system(size: 19, weight: .black, design: .monospaced))
                    .tracking(title.count > 10 ? 0.10 : 0.22)
                    .spyFitted(lines: 2, scale: 0.62)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .black))
            }
            .foregroundStyle(highlighted || selected ? SpyTheme.red : SpyTheme.bodyText)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 64)
            .padding(.horizontal, 8)
            .background {
                if highlighted || selected {
                    LinearGradient(
                        colors: [
                            SpyTheme.red.opacity(0.12),
                            SpyTheme.red.opacity(0.032),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(highlighted || selected ? SpyTheme.red : Color.clear)
                    .frame(width: 2, height: 44)
            }
        }
        .buttonStyle(SpyWebPressStyle())
        .opacity(rowProgress)
        .offset(y: stagedOffset(phaseStart, phaseStart + 0.22, distance: 18))
        .contentShape(Rectangle())
    }

    private func closeThen(_ action: @escaping @MainActor () -> Void) {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            action()
        }
    }

    private func localized(en: String, ru: String, es: String, uk: String) -> String {
        switch appState.language {
        case .ru: ru
        case .es: es
        case .uk: uk
        default: en
        }
    }

    private func phase(_ start: CGFloat, _ end: CGFloat) -> Double {
        guard end > start else { return progress >= end ? 1 : 0 }
        let value = (progress - start) / (end - start)
        return Double(smoothStep(clamp(value)))
    }

    private func stagedOffset(_ start: CGFloat, _ end: CGFloat, distance: CGFloat) -> CGFloat {
        let resolved = CGFloat(phase(start, end))
        return distance * (1 - resolved)
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        let clamped = clamp(value)
        return clamped * clamped * (3 - (2 * clamped))
    }
}

private struct DrawerCutShape: Shape {
    var cut: CGFloat

    func path(in rect: CGRect) -> Path {
        let resolvedCut = min(max(cut, 0), min(rect.width, rect.height) * 0.24)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - resolvedCut))
        path.addLine(to: CGPoint(x: rect.maxX - resolvedCut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + resolvedCut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - resolvedCut))
        path.closeSubpath()

        return path
    }
}

private extension View {
    func shellDockContentInset(visible: Bool) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if visible {
                Color.clear
                    .frame(height: 76)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct DockGlassSurface: ViewModifier {
    private let cornerRadius: CGFloat = 15

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .clear,
                    in: .rect(cornerRadius: cornerRadius)
                )
                .background(
                    Color.black.opacity(0.30),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.09), lineWidth: 0.75)
                }
        } else {
            content
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .opacity(0.52)

                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.black.opacity(0.30))

                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.075), lineWidth: 0.75)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
        }
    }
}

private struct FloatingDock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: AppTab
    let tabs: [AppTab]
    let communitySelection: CommunityTab
    let isCommunity: Bool
    let communityAttentionCount: Int
    let primarySwipeTarget: AppTab?
    let primarySwipeProgress: CGFloat
    let namespace: Namespace.ID
    let language: AppLanguage
    let communityAction: (CommunityTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(dockItems.enumerated()), id: \.offset) { index, item in
                Button {
                    handleTap(at: index)
                } label: {
                    DockItem(
                        symbol: item.symbol,
                        selectionPosition: item.selectionPosition,
                        itemIndex: index,
                        inactiveOpacity: item.inactiveOpacity,
                        badgeCount: item.badgeCount,
                        showsMatchedSelectionLine: isCommunity,
                        namespace: namespace,
                        accessibilityLabel: item.accessibilityLabel,
                        language: language
                    )
                }
                .buttonStyle(DockPressStyle())
                .accessibilityLabel(item.accessibilityLabel)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: 348)
        .frame(height: 62)
        .overlay(alignment: .bottomLeading) {
            if !isCommunity {
                DockSelectionIndicator(
                    position: primaryDockPosition,
                    itemCount: tabs.count
                )
                .fill(SpyTheme.red)
                .frame(height: 2)
                .offset(y: -2)
                .allowsHitTesting(false)
            }
        }
        .modifier(DockGlassSurface())
        .shadow(color: .black.opacity(0.24), radius: 9, y: 5)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .animation(dockSelectionAnimation, value: selection.dockRepresentative)
    }

    private var dockItems: [ShellDockItem] {
        if isCommunity {
            let selectedIndex = CommunityTab.allCases.firstIndex(of: communitySelection) ?? 1
            return CommunityTab.allCases.map { tab in
                ShellDockItem(
                    symbol: tab.symbol,
                    selectionPosition: CGFloat(selectedIndex),
                    inactiveOpacity: tab == .exit ? 0.70 : 0.44,
                    badgeCount: tab == .network ? communityAttentionCount : 0,
                    accessibilityLabel: tab.accessibilityLabel(language: language)
                )
            }
        }

        return tabs.enumerated().map { index, tab in
            ShellDockItem(
                symbol: tab.symbol,
                selectionPosition: primaryDockPosition,
                inactiveOpacity: 0.44,
                badgeCount: 0,
                accessibilityLabel: language.tabTitle(tab)
            )
        }
    }

    private var primaryDockPosition: CGFloat {
        let selectedTab = selection.dockRepresentative
        let selectedIndex = tabs.firstIndex(of: selectedTab) ?? 0
        guard let primarySwipeTarget,
              let targetIndex = tabs.firstIndex(of: primarySwipeTarget) else {
            return CGFloat(selectedIndex)
        }

        return CGFloat(selectedIndex)
            + (CGFloat(targetIndex - selectedIndex) * min(max(primarySwipeProgress, 0), 1))
    }

    private var dockSelectionAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.10)
            : .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.36)
    }

    private func handleTap(at index: Int) {
        if isCommunity {
            guard CommunityTab.allCases.indices.contains(index) else { return }
            HapticManager.shared.fire(.tabSelection)
            communityAction(CommunityTab.allCases[index])
        } else {
            guard tabs.indices.contains(index) else { return }
            HapticManager.shared.fire(.tabSelection)
            selection = tabs[index]
        }
    }
}

private struct ShellDockItem {
    let symbol: String
    let selectionPosition: CGFloat
    let inactiveOpacity: Double
    let badgeCount: Int
    let accessibilityLabel: String
}

private struct DockPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.94 : 1)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.06)
                    : .timingCurve(
                        0.22,
                        0.61,
                        0.36,
                        1,
                        duration: configuration.isPressed ? 0.14 : 0.30
                    ),
                value: configuration.isPressed
            )
    }
}

private struct DockItem: View {
    let symbol: String
    let selectionPosition: CGFloat
    let itemIndex: Int
    let inactiveOpacity: Double
    let badgeCount: Int
    let showsMatchedSelectionLine: Bool
    let namespace: Namespace.ID
    let accessibilityLabel: String
    let language: AppLanguage

    var body: some View {
        let amount = selectionAmount

        Image(systemName: symbol)
            .font(.system(size: 25, weight: .semibold))
            .modifier(
                DockIconAppearance(
                    selectionPosition: selectionPosition,
                    itemIndex: CGFloat(itemIndex),
                    inactiveOpacity: inactiveOpacity
                )
            )
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .overlay(alignment: .bottom) {
                if showsMatchedSelectionLine, amount > 0.5 {
                    Rectangle()
                        .fill(SpyTheme.red)
                        .frame(width: 28, height: 2)
                        .matchedGeometryEffect(id: "dock-active-redline", in: namespace)
                        .offset(y: -2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if badgeCount > 0 {
                    CommunityAttentionBadge(count: badgeCount, compact: true)
                        .offset(x: -14, y: 4)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.14), value: symbol)
            .animation(.easeOut(duration: 0.18), value: badgeCount)
            .animation(
                showsMatchedSelectionLine
                    ? .interpolatingSpring(mass: 1, stiffness: 420, damping: 26, initialVelocity: 0)
                    : nil,
                value: amount
            )
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(badgeCount > 0 ? pendingItemsValue : "")
    }

    private var pendingItemsValue: String {
        switch language {
        case .en: "\(badgeCount) pending items"
        case .es: "\(badgeCount) elementos pendientes"
        case .ru: "Ожидают действия: \(badgeCount)"
        case .uk: "Очікують дії: \(badgeCount)"
        }
    }

    private var selectionAmount: CGFloat {
        min(max(1 - abs(selectionPosition - CGFloat(itemIndex)), 0), 1)
    }
}

private struct DockSelectionIndicator: Shape {
    var position: CGFloat
    let itemCount: Int

    nonisolated var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard itemCount > 0 else { return Path() }

        let horizontalInset: CGFloat = 8
        let indicatorWidth: CGFloat = 28
        let contentWidth = max(rect.width - (horizontalInset * 2), 1)
        let itemWidth = contentWidth / CGFloat(itemCount)
        let originX = horizontalInset
            + (itemWidth * (position + 0.5))
            - (indicatorWidth * 0.5)

        return Path(CGRect(x: originX, y: rect.minY, width: indicatorWidth, height: rect.height))
    }
}

private struct DockIconAppearance: AnimatableModifier {
    var selectionPosition: CGFloat
    let itemIndex: CGFloat
    let inactiveOpacity: Double

    nonisolated var animatableData: CGFloat {
        get { selectionPosition }
        set { selectionPosition = newValue }
    }

    func body(content: Content) -> some View {
        let rawAmount = min(max(1 - abs(selectionPosition - itemIndex), 0), 1)
        let amount = rawAmount * rawAmount * (3 - (2 * rawAmount))
        let red = 1 + ((CGFloat(229) / 255) - 1) * amount
        let green = 1 + ((CGFloat(53) / 255) - 1) * amount
        let blue = 1 + ((CGFloat(53) / 255) - 1) * amount
        let opacity = inactiveOpacity + ((1 - inactiveOpacity) * Double(amount))

        content
            .foregroundStyle(Color(red: red, green: green, blue: blue).opacity(opacity))
            .scaleEffect(1 + (0.10 * amount))
            .offset(y: -0.9 * amount)
    }
}

// Native translation of the Base44 Layout.jsx drawer. Its geometry and reveal
// phases intentionally mirror the web source so both shells share one rhythm.
private struct WebPullDownCommandMenu: View {
    @Binding var isPresented: Bool
    let communityAttentionCount: Int
    let notificationUnreadCount: Int
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var dragTranslation: CGFloat = 0
    @State private var didFireDragHaptic = false

    var body: some View {
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top > 0 ? proxy.safeAreaInsets.top : 54
            let topBarHeight = topInset + 80
            let menuHeight = proxy.size.height * 0.50
            let revealedHeight = currentRevealHeight(menuHeight: menuHeight)
            let progress = clamp(revealedHeight / max(menuHeight, 1))
            let totalHeight = topBarHeight + revealedHeight
            let isInteracting = abs(dragTranslation) > 0.5 || didFireDragHaptic

            ZStack(alignment: .top) {
                if progress > 0.001 {
                    Color.black
                        .opacity(0.60 * progress)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture(perform: closeMenu)
                }

                VStack(spacing: 0) {
                    WebMenuTopBar(
                        progress: progress,
                        topInset: topInset,
                        communityAttentionCount: communityAttentionCount,
                        notificationUnreadCount: notificationUnreadCount
                    )
                        .frame(height: topBarHeight)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(commandMenuAccessibilityLabel)
                        .accessibilityIdentifier("spy-command-menu-drag-handle")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction {
                            setPresented(!isPresented)
                        }

                    if revealedHeight > 0.5 || isPresented {
                        WebCommandMenuPanel(
                            progress: progress,
                            communityAttentionCount: communityAttentionCount,
                            notificationUnreadCount: notificationUnreadCount,
                            close: closeMenu
                        )
                            .frame(height: revealedHeight)
                            .clipped()
                            .allowsHitTesting(progress > 0.92)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: totalHeight, alignment: .top)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    menuDragGesture(menuHeight: menuHeight),
                    including: .all
                )
                .background(Color.black.opacity(0.97))
                .overlay(alignment: .bottom) {
                    ZStack {
                        Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)
                            .opacity(1 - progress)
                        SpyTheme.red.opacity(progress)
                    }
                    .frame(height: 1)
                }
                .clipped()
                .shadow(color: .black.opacity(0.42 * progress), radius: 18, y: 10)
                // Keep the large wordmark button outside the subtree that owns
                // the pull-down DragGesture. A small amount of finger jitter can
                // therefore never promote the parent drag and cancel this tap.
                .overlay(alignment: .topLeading) {
                    WebHeaderHomeButton(
                        attentionCount: communityAttentionCount + notificationUnreadCount,
                        action: openHomeRoot
                    )
                    .frame(height: 80, alignment: .leading)
                    .padding(.leading, 24)
                    .padding(.top, topInset)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: progress > 0.001 ? proxy.size.height : totalHeight, alignment: .top)
            .transaction { transaction in
                if isInteracting {
                    transaction.animation = nil
                }
            }
        }
        .ignoresSafeArea()
    }

    private func menuDragGesture(menuHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                let directional = isPresented
                    ? min(0, value.translation.height)
                    : max(0, value.translation.height)

                if !didFireDragHaptic, abs(directional) > 5 {
                    didFireDragHaptic = true
                    HapticManager.shared.fire(.tabSelection)
                }

                var transaction = Transaction()
                transaction.animation = nil
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragTranslation = directional
                }
            }
            .onEnded { value in
                didFireDragHaptic = false

                let predicted = isPresented
                    ? menuHeight + min(0, value.predictedEndTranslation.height)
                    : max(0, value.predictedEndTranslation.height)
                let settled = isPresented
                    ? menuHeight + min(0, value.translation.height)
                    : max(0, value.translation.height)
                let predictedProgress = clamp(predicted / max(menuHeight, 1))
                let settledProgress = clamp(settled / max(menuHeight, 1))

                setPresented(shouldRemainOpen(
                    predictedProgress: predictedProgress,
                    settledProgress: settledProgress
                ))
            }
    }

    private func shouldRemainOpen(predictedProgress: CGFloat, settledProgress: CGFloat) -> Bool {
        if isPresented {
            // Closing is measured from the open edge. A deliberate 24% pull,
            // or a shorter fast pull predicted past 30%, commits the close.
            let deliberateClose = settledProgress < 0.76
            let fastClose = predictedProgress < 0.70
            return !(deliberateClose || fastClose)
        }

        let deliberateOpen = settledProgress > 0.24
        let fastOpen = predictedProgress > 0.30
        return deliberateOpen || fastOpen
    }

    private func currentRevealHeight(menuHeight: CGFloat) -> CGFloat {
        let resting = isPresented ? menuHeight : 0
        return min(menuHeight, max(0, resting + dragTranslation))
    }

    private func closeMenu() {
        setPresented(false)
    }

    private func openHomeRoot() {
        if isPresented {
            setPresented(false)
        } else {
            HapticManager.shared.fire(.buttonPress)
        }
        appState.openHomeRoot()
    }

    private func setPresented(_ presented: Bool) {
        if isPresented != presented {
            HapticManager.shared.fire(.buttonPress)
        }

        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.18)
            : .timingCurve(0.22, 0.61, 0.36, 1, duration: presented ? 0.45 : 0.30)

        withAnimation(animation) {
            isPresented = presented
            dragTranslation = 0
        }
    }

    private var commandMenuAccessibilityLabel: String {
        switch (appState.language, isPresented) {
        case (.en, true): "Close command menu"
        case (.en, false): "Pull down command menu"
        case (.es, true): "Cerrar menú de comandos"
        case (.es, false): "Desliza hacia abajo para abrir el menú de comandos"
        case (.ru, true): "Закрыть командное меню"
        case (.ru, false): "Потяните вниз, чтобы открыть командное меню"
        case (.uk, true): "Закрити командне меню"
        case (.uk, false): "Потягніть униз, щоб відкрити командне меню"
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}

private struct WebMenuTopBar: View {
    @Environment(AppState.self) private var appState

    let progress: CGFloat
    let topInset: CGFloat
    let communityAttentionCount: Int
    let notificationUnreadCount: Int

    private var totalAttentionCount: Int {
        communityAttentionCount + notificationUnreadCount
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: topInset)

            ZStack {
                HStack(spacing: 0) {
                    Spacer()

                    toggleIndicator
                        .frame(width: 44, height: 40)
                        .overlay(alignment: .topTrailing) {
                            if totalAttentionCount > 0 {
                                CommunityAttentionBadge(
                                    count: totalAttentionCount,
                                    compact: true
                                )
                                    .offset(x: 3, y: -4)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                }
                .padding(.horizontal, 24)

                VStack(spacing: 3) {
                    Capsule()
                        .fill(progress > 0.01 ? SpyTheme.red : Color(red: 51 / 255, green: 51 / 255, blue: 51 / 255))
                        .frame(width: 32, height: 2)
                    Capsule()
                        .fill(progress > 0.01 ? SpyTheme.red : Color(red: 34 / 255, green: 34 / 255, blue: 34 / 255))
                        .frame(width: 20, height: 2)
                }
                .animation(.easeOut(duration: 0.20), value: progress > 0.01)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 6)
            }
            .frame(height: 80)
            .overlay(alignment: .topLeading) {
                WebCornerMark(edges: [.top, .leading], color: Color(red: 51 / 255, green: 51 / 255, blue: 51 / 255))
                    .frame(width: 16, height: 16)
                    .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                WebCornerMark(edges: [.top, .trailing], color: Color(red: 51 / 255, green: 51 / 255, blue: 51 / 255))
                    .frame(width: 16, height: 16)
                    .padding(8)
            }
        }
        .background(Color.black.opacity(0.97))
        .overlay(alignment: .bottom) {
            ZStack {
                Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)
                    .opacity(1 - progress)
                SpyTheme.red.opacity(progress)
            }
            .frame(height: 1)
        }
        .animation(.easeOut(duration: 0.18), value: totalAttentionCount)
        .accessibilityValue(attentionAccessibilityValue)
    }

    private var attentionAccessibilityValue: String {
        switch (appState.language, totalAttentionCount > 0) {
        case (.en, true): "\(totalAttentionCount) pending items"
        case (.en, false): "No pending items"
        case (.es, true): "\(totalAttentionCount) elementos pendientes"
        case (.es, false): "No hay elementos pendientes"
        case (.ru, true): "Ожидают действия: \(totalAttentionCount)"
        case (.ru, false): "Нет ожидающих элементов"
        case (.uk, true): "Очікують дії: \(totalAttentionCount)"
        case (.uk, false): "Немає елементів, що очікують дії"
        }
    }

    private var toggleIndicator: some View {
        ZStack {
            Image(systemName: "chevron.down")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(.white)
                .opacity(Double(clamp(1 - (progress / 0.10))))

            VStack(spacing: 5) {
                menuLine(threshold: 0)
                menuLine(threshold: 0.33)
                menuLine(threshold: 0.66)
            }
            .frame(width: 20)
            .opacity(Double(clamp((progress - 0.05) / 0.05)))
        }
        .accessibilityHidden(true)
    }

    private func menuLine(threshold: CGFloat) -> some View {
        GeometryReader { proxy in
            let fill = clamp((progress - threshold) / 0.34)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(red: 42 / 255, green: 42 / 255, blue: 42 / 255))
                Capsule()
                    .fill(SpyTheme.red)
                    .frame(width: proxy.size.width * fill)
            }
        }
        .frame(height: 2)
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}

private struct ShellWordmark: View {
    let fontSize: CGFloat

    var body: some View {
        // The logotype already has a spoken accessibility label. Cap only its
        // decorative glyphs so fixed shell chrome cannot overlap nearby actions.
        SpyWordmark(fontSize: fontSize)
            .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

private struct WebHeaderHomeButton: View {
    @Environment(AppState.self) private var appState

    let attentionCount: Int
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: action) {
                ShellWordmark(fontSize: 30)
                    .fixedSize()
                    .contentShape(Rectangle())
            }
            .buttonStyle(SpyWebPressStyle(pressedScale: 0.97))
            .accessibilityLabel(homeAccessibilityLabel)
            .accessibilityValue(attentionCount > 0 ? pendingItemsAccessibilityValue : "")
            .accessibilityIdentifier("shell.header.home")

            SpyAppVersionMark()
                .allowsHitTesting(false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var homeAccessibilityLabel: String {
        switch appState.language {
        case .en: "Open SpyClash home"
        case .es: "Abrir el inicio de SpyClash"
        case .ru: "Открыть главную SpyClash"
        case .uk: "Відкрити головну SpyClash"
        }
    }

    private var pendingItemsAccessibilityValue: String {
        switch appState.language {
        case .en: "\(attentionCount) pending items"
        case .es: "\(attentionCount) elementos pendientes"
        case .ru: "Ожидают действия: \(attentionCount)"
        case .uk: "Очікують дії: \(attentionCount)"
        }
    }
}

private struct WebCommandMenuPanel: View {
    @Environment(AppState.self) private var appState

    let progress: CGFloat
    let communityAttentionCount: Int
    let notificationUnreadCount: Int
    let close: () -> Void

    private let itemHeight: CGFloat = 40
    private let totalItems: CGFloat = 6

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                revealItem(index: 0) {
                    menuButton(
                        icon: "👤",
                        title: localized(en: "PROFILE", ru: "ПРОФИЛЬ", es: "PERFIL", uk: "ПРОФІЛЬ"),
                        selected: appState.shellRoute == .main && appState.selectedTab == .profile
                    ) {
                        closeThen {
                            appState.openMainTab(.profile)
                        }
                    }
                }

                revealItem(index: 1) {
                    menuButton(
                        icon: "📦",
                        title: localized(en: "WORD-PACKS", ru: "НАБОРЫ", es: "PAQUETES", uk: "НАБОРИ СЛІВ"),
                        selected: appState.shellRoute == .main && appState.selectedTab == .packs
                    ) {
                        closeThen {
                            appState.openMainTab(.packs)
                        }
                    }
                }

                revealItem(index: 2) {
                    menuButton(
                        icon: "🪪",
                        title: localized(en: "COMMUNITY", ru: "СООБЩЕСТВО", es: "COMUNIDAD", uk: "СПІЛЬНОТА"),
                        selected: appState.shellRoute == .community,
                        badgeCount: communityAttentionCount
                    ) {
                        closeThen { appState.openCommunity() }
                    }
                }

                revealItem(index: 3) {
                    menuButton(
                        icon: "🔔",
                        title: localized(
                            en: "NOTIFICATIONS",
                            ru: "УВЕДОМЛЕНИЯ",
                            es: "NOTIFICACIONES",
                            uk: "СПОВІЩЕННЯ"
                        ),
                        selected: appState.shellRoute == .notifications,
                        badgeCount: notificationUnreadCount,
                        badgeAccessibilityDescription: localized(
                            en: "unread notifications",
                            ru: "непрочитанных уведомлений",
                            es: "notificaciones sin leer",
                            uk: "непрочитаних сповіщень"
                        )
                    ) {
                        closeThen { appState.openNotifications() }
                    }
                    .accessibilityIdentifier("spy-command-menu.notifications")
                }

                revealDivider(index: 4)

                revealItem(index: 5) {
                    menuButton(
                        icon: "🚪",
                        title: localized(en: "LOGOUT", ru: "ВЫХОД", es: "SALIR", uk: "ВИЙТИ"),
                        highlighted: true
                    ) {
                        close()
                        appState.logout()
                    }
                }
            }
            .padding(.horizontal, 24)
            .frame(maxHeight: .infinity, alignment: .center)

            languageFooter
                .opacity(Double(footerProgress))
                .offset(y: 10 * (1 - footerProgress))
        }
        .background(Color.black.opacity(0.97))
        .overlay(alignment: .bottomLeading) {
            WebCornerMark(edges: [.bottom, .leading], color: SpyTheme.red)
                .frame(width: 16, height: 16)
        }
        .overlay(alignment: .bottomTrailing) {
            WebCornerMark(edges: [.bottom, .trailing], color: SpyTheme.red)
                .frame(width: 16, height: 16)
        }
    }

    private func revealItem<Content: View>(index: Int, @ViewBuilder content: () -> Content) -> some View {
        let itemProgress = progressForItem(index)

        return content()
            .frame(height: itemHeight)
            .opacity(Double(itemProgress))
            .offset(x: -20 * (1 - itemProgress))
            .frame(height: itemHeight * itemProgress, alignment: .top)
            .clipped()
    }

    private func revealDivider(index: Int) -> some View {
        let itemProgress = progressForItem(index)

        return Rectangle()
            .fill(Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255))
            .frame(height: 1)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .opacity(Double(itemProgress))
            .frame(height: 17 * itemProgress, alignment: .top)
            .clipped()
    }

    private func menuButton(
        icon: String,
        title: String,
        selected: Bool = false,
        highlighted: Bool = false,
        badgeCount: Int = 0,
        badgeAccessibilityDescription: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(icon)
                    .font(.system(size: 20))
                    .frame(width: 28, alignment: .leading)

                Text(title)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .tracking(3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 0)

                if badgeCount > 0 {
                    CommunityAttentionBadge(
                        count: badgeCount,
                        accessibilityDescription: badgeAccessibilityDescription
                    )
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .foregroundStyle(selected || highlighted ? SpyTheme.red : Color(red: 187 / 255, green: 187 / 255, blue: 187 / 255))
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: itemHeight, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(selected ? SpyTheme.red : Color.clear)
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
        .animation(.easeOut(duration: 0.18), value: badgeCount)
    }

    private var languageFooter: some View {
        HStack(spacing: 12) {
            Text(localized(en: "LANGUAGE", ru: "ЯЗЫК", es: "IDIOMA", uk: "МОВА"))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Color(red: 68 / 255, green: 68 / 255, blue: 68 / 255))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            HStack(spacing: 6) {
                languageButton(.en)
                languageButton(.es)
                languageButton(.ru)
                languageButton(.uk)
            }

            Spacer()

            Button {
                close()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(SpyTheme.red)
                    .frame(width: 32, height: 32)
                    .overlay(Rectangle().stroke(Color(red: 42 / 255, green: 42 / 255, blue: 42 / 255), lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(SpyWebPressStyle())
            .accessibilityLabel(localized(en: "Close menu", ru: "Закрыть меню", es: "Cerrar menu", uk: "Закрити меню"))
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255))
                .frame(height: 1)
        }
    }

    private func languageButton(_ language: AppLanguage) -> some View {
        Button {
            guard appState.language != language else { return }
            HapticManager.shared.fire(.tabSelection)
            Task {
                try? await appState.setLanguage(language, syncRemote: appState.user != nil)
            }
        } label: {
            Text(language.shortCode)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(appState.language == language ? .white : Color(red: 85 / 255, green: 85 / 255, blue: 85 / 255))
                .padding(.horizontal, 12)
                .frame(minHeight: 28)
                .background(appState.language == language ? SpyTheme.red : Color.clear)
                .overlay(Rectangle().stroke(appState.language == language ? SpyTheme.red : Color(red: 42 / 255, green: 42 / 255, blue: 42 / 255), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private var footerProgress: CGFloat {
        clamp((progress - 0.70) / 0.30)
    }

    private func progressForItem(_ index: Int) -> CGFloat {
        clamp((progress * totalItems) - CGFloat(index))
    }

    private func closeThen(_ action: @escaping @MainActor () -> Void) {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            action()
        }
    }

    private func localized(en: String, ru: String, es: String, uk: String) -> String {
        switch appState.language {
        case .en: en
        case .ru: ru
        case .es: es
        case .uk: uk
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}

private struct SpyAppVersionMark: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Text(SpyClashRelease.headerVersionLabel)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(2.1)
            .foregroundStyle(Color.white.opacity(0.46))
            .accessibilityLabel(versionAccessibilityLabel)
    }

    private var versionAccessibilityLabel: String {
        switch appState.language {
        case .en: "SpyClash version \(SpyClashRelease.headerVersionLabel)"
        case .es: "Versión de SpyClash \(SpyClashRelease.headerVersionLabel)"
        case .ru: "Версия SpyClash \(SpyClashRelease.headerVersionLabel)"
        case .uk: "Версія SpyClash \(SpyClashRelease.headerVersionLabel)"
        }
    }
}

private struct CommunityAttentionSnapshot: Equatable {
    let friendRequestIDs: Set<String>
    let roomInviteIDs: Set<String>
    let friendRequestSendersByID: [String: String]
    let roomInviteSendersByID: [String: String]

    static let empty = CommunityAttentionSnapshot(
        friendRequestIDs: [],
        roomInviteIDs: [],
        friendRequestSendersByID: [:],
        roomInviteSendersByID: [:]
    )

    init(state: CommunityState) {
        let friendRequests = state.incoming.filter { $0.status.lowercased() == "pending" }
        let roomInvites = state.incomingRoomInvites.filter { $0.status.lowercased() == "pending" }

        friendRequestIDs = Set(friendRequests.map { "friend:\($0.id)" })
        roomInviteIDs = Set(roomInvites.map { "room:\($0.id)" })
        friendRequestSendersByID = Dictionary(
            uniqueKeysWithValues: friendRequests.map { ("friend:\($0.id)", $0.profile.displayName) }
        )
        roomInviteSendersByID = Dictionary(
            uniqueKeysWithValues: roomInvites.map { ("room:\($0.id)", $0.sender.displayName) }
        )
    }

    private init(
        friendRequestIDs: Set<String>,
        roomInviteIDs: Set<String>,
        friendRequestSendersByID: [String: String],
        roomInviteSendersByID: [String: String]
    ) {
        self.friendRequestIDs = friendRequestIDs
        self.roomInviteIDs = roomInviteIDs
        self.friendRequestSendersByID = friendRequestSendersByID
        self.roomInviteSendersByID = roomInviteSendersByID
    }

    var allIDs: Set<String> {
        friendRequestIDs.union(roomInviteIDs)
    }

    var totalCount: Int {
        allIDs.count
    }

    func senderName(forFriendRequestIDs ids: Set<String>) -> String? {
        ids.sorted().compactMap { friendRequestSendersByID[$0] }.first
    }

    func senderName(forRoomInviteIDs ids: Set<String>) -> String? {
        ids.sorted().compactMap { roomInviteSendersByID[$0] }.first
    }

#if DEBUG
    static func preview(count: Int) -> CommunityAttentionSnapshot {
        CommunityAttentionSnapshot(
            friendRequestIDs: Set((0..<count).map { "preview-friend:\($0)" }),
            roomInviteIDs: [],
            friendRequestSendersByID: count > 0 ? ["preview-friend:0": "RED RAVEN"] : [:],
            roomInviteSendersByID: [:]
        )
    }
#endif
}

private struct CommunityAttentionBadge: View {
    @Environment(AppState.self) private var appState

    let count: Int
    var compact = false
    var accessibilityDescription: String? = nil

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: compact ? 9 : 10, weight: .black, design: .monospaced))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, compact ? 5 : 7)
            .frame(minWidth: compact ? 19 : 24, minHeight: compact ? 19 : 22)
            .background(SpyTheme.red, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.90), lineWidth: 1))
            .shadow(color: SpyTheme.red.opacity(0.72), radius: 7)
            .accessibilityLabel("\(count) \(resolvedAccessibilityDescription)")
    }

    private var resolvedAccessibilityDescription: String {
        if let accessibilityDescription {
            return accessibilityDescription
        }
        return switch appState.language {
        case .en: "pending Community items"
        case .es: "elementos pendientes de Comunidad"
        case .ru: "ожидающих элементов Сообщества"
        case .uk: "елементів Спільноти, що очікують дії"
        }
    }
}

private struct WebCornerMark: View {
    let edges: Edge.Set
    let color: Color

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .overlay(alignment: .top) {
                if edges.contains(.top) {
                    Rectangle().fill(color).frame(height: 1)
                }
            }
            .overlay(alignment: .bottom) {
                if edges.contains(.bottom) {
                    Rectangle().fill(color).frame(height: 1)
                }
            }
            .overlay(alignment: .leading) {
                if edges.contains(.leading) {
                    Rectangle().fill(color).frame(width: 1)
                }
            }
            .overlay(alignment: .trailing) {
                if edges.contains(.trailing) {
                    Rectangle().fill(color).frame(width: 1)
                }
            }
            .allowsHitTesting(false)
    }
}
