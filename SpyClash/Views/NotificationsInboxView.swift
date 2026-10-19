import SwiftUI
import UserNotifications

@MainActor
enum NotificationInboxRowInteraction {
    @discardableResult
    static func activate(
        item: NotificationInboxItem,
        store: NotificationInboxStore,
        onOpen: (NotificationInboxItem) -> Void
    ) -> Task<Void, Never>? {
        // Route first. The read receipt is an independent best-effort mutation
        // and must never hold navigation hostage to the network.
        if item.actionableDeepLink != nil {
            onOpen(item)
        }

        guard item.isUnread else { return nil }
        return Task {
            _ = await store.markRead(item)
        }
    }
}

enum NotificationPublishConfirmationPolicy {
    static func requiresConfirmation(for importance: NotificationInboxImportance) -> Bool {
        importance == .important
    }
}

struct NotificationsInboxView: View {
    let store: NotificationInboxStore
    let language: AppLanguage
    var canPublishGlobal = false
    var onOpenItem: (NotificationInboxItem) -> Void = { _ in }
    var onClose: (() -> Void)?
    var focusItemID: String?
    var focusRequestID = 0
    var pendingRequests: [NotificationInboxPendingRequest] = []
    var hasLoadedPendingRequests = false
    var pendingSocialItemIDs: Set<String> = []
    var onSocialAction: ((NotificationInboxPendingRequest, NotificationInboxSocialActionKind) -> Void)?
    var onRefreshPendingRequests: @MainActor @Sendable () async -> Void = {}

    @State private var composerRoute: NotificationComposerRoute?

    private var copy: NotificationInboxCopy {
        NotificationInboxCopy(language: language)
    }

    var body: some View {
        ScrollViewReader { proxy in
            PageChrome(
                eyebrow: copy.eyebrow,
                status: copy.status(unread: store.unread.total)
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        NotificationAuthorizationControl(language: language)
                    }
                    scopeSelector
                    scopeActions
                    inboxContent
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
            }
            .refreshable {
                async let page: Void = store.refresh(scope: store.selectedScope)
                async let requests: Void = onRefreshPendingRequests()
                _ = await (page, requests)
            }
            .task(id: store.accountID) {
                guard store.accountID != nil else { return }
                async let page: Void = store.loadInitial()
                async let requests: Void = onRefreshPendingRequests()
                _ = await (page, requests)
            }
            .task(id: store.selectedScope) {
                guard store.accountID != nil else { return }
                await store.loadIfNeeded(scope: store.selectedScope)
            }
            .task(id: focusRequestID) {
                await revealFocusedItem(using: proxy)
            }
            .sheet(item: $composerRoute) { _ in
                NotificationGlobalComposerSheet(store: store, language: language)
                    .spyInterfaceScale()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(SpyTheme.black)
                    .interactiveDismissDisabled(store.isPublishing)
            }
        }
    }

    private func revealFocusedItem(using proxy: ScrollViewProxy) async {
        guard let focusItemID = focusItemID?.nilIfBlank else { return }
        let scope: NotificationInboxScope = focusItemID.hasPrefix("personal:")
            ? .personal
            : .global
        store.selectScope(scope)
        await store.loadIfNeeded(scope: scope)
        guard let item = store.feed(for: scope).items.first(where: { $0.id == focusItemID }) else {
            return
        }
        await Task.yield()
        let targetID = item.isSocialRequest && hasLoadedPendingRequests && onSocialAction != nil
            ? pendingRequests.first?.id
            : item.id
        if let targetID {
            withAnimation(.easeOut(duration: 0.24)) {
                proxy.scrollTo(targetID, anchor: .center)
            }
        }
        _ = await store.markRead(item)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(copy.title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(copy.subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(SpyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if canPublishGlobal {
                    Button {
                        store.clearPublishingError()
                        composerRoute = NotificationComposerRoute()
                        HapticManager.shared.fire(.buttonPress)
                    } label: {
                        Image(systemName: "megaphone.fill")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(SpyTheme.red)
                            .frame(width: 44, height: 44)
                            .background(SpyTheme.panel, in: CutCornerShape(cut: 8))
                            .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.red.opacity(0.62), lineWidth: 1))
                    }
                    .buttonStyle(SpyWebPressStyle(pressedScale: 0.92))
                    .accessibilityLabel(copy.compose)
                    .accessibilityIdentifier("notifications.compose")
                }

                if let onClose {
                    Button {
                        HapticManager.shared.fire(.navigation)
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(SpyTheme.muted)
                            .frame(width: 44, height: 44)
                            .background(SpyTheme.panel, in: CutCornerShape(cut: 8))
                            .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.strokeStrong, lineWidth: 1))
                    }
                    .buttonStyle(SpyWebPressStyle(pressedScale: 0.92))
                    .accessibilityLabel(copy.close)
                }
            }

        }
    }

    private var scopeSelector: some View {
        HStack(spacing: 4) {
            ForEach([NotificationInboxScope.personal, .global]) { scope in
                scopeButton(scope)
            }
        }
        .padding(4)
        .background(SpyTheme.control, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notifications.scopes")
    }

    private func scopeButton(_ scope: NotificationInboxScope) -> some View {
        let isSelected = store.selectedScope == scope
        let count = store.unreadCount(for: scope)

        return Button {
            HapticManager.shared.fire(.tabSelection)
            withAnimation(.smooth(duration: 0.18)) {
                store.selectScope(scope)
            }
        } label: {
            HStack(spacing: 8) {
                Text(copy.scopeTitle(scope))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)

                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(SpyTheme.red, in: Capsule())
                }
            }
            .foregroundStyle(isSelected ? Color.white : SpyTheme.muted)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(isSelected ? SpyTheme.panel : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.96))
        .accessibilityLabel(copy.scopeAccessibility(scope, unread: count))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("notifications.scope.\(scope.rawValue)")
    }

    private var scopeActions: some View {
        HStack {
            Text(copy.scopeDetail(store.selectedScope))
                .font(.system(size: 12))
                .foregroundStyle(SpyTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if store.unreadCount(for: store.selectedScope) > 0 {
                markAllReadButton
            }
        }
    }

    private var markAllReadButton: some View {
        Button {
            Task {
                let succeeded = await store.markAllRead(scope: store.selectedScope)
                HapticManager.shared.fire(
                    succeeded ? .notification(.success) : .notification(.error)
                )
            }
        } label: {
            HStack(spacing: 7) {
                if store.markingAllScopes.contains(store.selectedScope) {
                    SpySpinner(size: 14, accent: SpyTheme.green)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 13, weight: .bold))
                        .accessibilityHidden(true)
                }

                Text(copy.markAll)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(
                store.unreadCount(for: store.selectedScope) > 0 ? SpyTheme.green : SpyTheme.dim
            )
            .frame(minHeight: 44)
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.94))
        .disabled(
            store.unreadCount(for: store.selectedScope) == 0 ||
                store.isMutating(scope: store.selectedScope)
        )
        .accessibilityLabel(copy.markAll)
        .accessibilityIdentifier("notifications.markAll")
    }

    @ViewBuilder
    private var inboxContent: some View {
        let scope = store.selectedScope
        let feed = store.feed(for: scope)
        let showsRequests = scope == .personal && hasLoadedPendingRequests && onSocialAction != nil
        let items = showsRequests ? feed.items.filter { !$0.isSocialRequest } : feed.items

        if showsRequests && !pendingRequests.isEmpty {
            LazyVStack(spacing: 12) {
                ForEach(pendingRequests) { request in
                    pendingRequestRow(request)
                }
            }
        }

        if let mutationError = store.mutationError {
            inlineError(mutationError)
        }

        if let error = feed.errorMessage, !feed.items.isEmpty {
            inlineError(error)
        }

        switch feed.loadState {
        case .idle, .loading:
            loadingPanel
        case let .failed(message):
            failedPanel(message: message, scope: scope)
        case .loaded:
            if items.isEmpty {
                if (!showsRequests || pendingRequests.isEmpty) && (!feed.canLoadMore || showsRequests) {
                    emptyPanel(scope: scope)
                }
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        notificationRow(item)
                    }

                }
            }

            if feed.isLoadingMore && (!showsRequests || !items.isEmpty) {
                HStack(spacing: 10) {
                    ProgressView().tint(SpyTheme.muted)
                    Text(copy.loadingMore)
                        .font(.system(size: 13))
                        .foregroundStyle(SpyTheme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 54)
            } else if feed.canLoadMore && (!showsRequests || !items.isEmpty) {
                Button {
                    Task { await store.loadNextPage(scope: scope) }
                } label: {
                    Label(copy.loadMore, systemImage: "arrow.down")
                }
                .buttonStyle(SpyButtonStyle(variant: .ghost))
                .accessibilityIdentifier("notifications.loadMore")
            }
        }
    }

    private func pendingRequestRow(_ request: NotificationInboxPendingRequest) -> some View {
        let isPending = pendingSocialItemIDs.contains(request.id)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Group {
                    if let avatar = request.avatar?.nilIfBlank {
                        Text(avatar).font(.system(size: 26))
                    } else {
                        Image(systemName: request.primaryAction == .join ? "gamecontroller.fill" : "person.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(SpyTheme.green)
                    }
                }
                .frame(width: 50, height: 50)
                .background(SpyTheme.control, in: Circle())
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(request.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(request.subtitle ?? copy.requestDetail(request.primaryAction))
                        .font(.system(size: 13))
                        .foregroundStyle(SpyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    HapticManager.shared.fire(.buttonPress)
                    onSocialAction?(request, request.primaryAction)
                } label: {
                    HStack(spacing: 8) {
                        if isPending {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: request.primaryAction == .join ? "arrow.right" : "checkmark")
                        }
                        Text(copy.actionTitle(request.primaryAction))
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(SpyTheme.red, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(SpyWebPressStyle(pressedScale: 0.97))
                .accessibilityIdentifier("notifications.request.\(request.id).primary")

                Button {
                    HapticManager.shared.fire(.buttonPress)
                    onSocialAction?(request, .decline)
                } label: {
                    Text(copy.actionTitle(.decline))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(SpyTheme.bodyText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(SpyTheme.control, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(SpyWebPressStyle(pressedScale: 0.97))
                .accessibilityIdentifier("notifications.request.\(request.id).decline")
            }
            .disabled(isPending)
        }
        .padding(16)
        .background(SpyTheme.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(SpyTheme.stroke, lineWidth: 1))
        .id(request.id)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notifications.request.\(request.id)")
    }

    private var loadingPanel: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(SpyTheme.muted)
            Text(copy.loading)
                .font(.system(size: 14))
                .foregroundStyle(SpyTheme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .accessibilityIdentifier("notifications.loading")
    }

    private func failedPanel(message: String, scope: NotificationInboxScope) -> some View {
        SpyPanel(accent: SpyTheme.red, motionDelay: 0.06) {
            VStack(alignment: .leading, spacing: 14) {
                Label(copy.unavailable, systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(0.07)
                    .foregroundStyle(.white)

                Text(message)
                    .font(SpyTheme.micro)
                    .foregroundStyle(SpyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await store.refresh(scope: scope) }
                } label: {
                    Label(copy.retry, systemImage: "arrow.clockwise")
                }
                .buttonStyle(SpyButtonStyle(variant: .outline))
            }
        }
        .accessibilityIdentifier("notifications.failed")
    }

    private func emptyPanel(scope: NotificationInboxScope) -> some View {
        VStack(spacing: 12) {
            Image(systemName: scope == .personal ? "person.2" : "bell")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(SpyTheme.muted)
                .frame(width: 64, height: 64)
                .background(SpyTheme.control, in: Circle())

            Text(copy.emptyTitle(scope))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)

            Text(copy.emptyDetail(scope))
                .font(.system(size: 14))
                .foregroundStyle(SpyTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityIdentifier("notifications.empty.\(scope.rawValue)")
    }

    private func inlineError(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SpyTheme.red)
            Text(message)
                .font(SpyTheme.micro)
                .foregroundStyle(SpyTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
        }
        .padding(12)
        .background(SpyTheme.red.opacity(0.08), in: CutCornerShape(cut: 8))
        .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.red.opacity(0.35), lineWidth: 1))
    }

    private func notificationRow(_ item: NotificationInboxItem) -> some View {
        Button {
            NotificationInboxRowInteraction.activate(
                item: item,
                store: store,
                onOpen: onOpenItem
            )
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(item.isSocialRequest ? SpyTheme.green.opacity(0.12) : SpyTheme.control)
                    Image(systemName: item.kind == "friend_request" ? "person.badge.plus" : item.kind == "room_invite" ? "gamecontroller.fill" : "megaphone.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(item.isSocialRequest ? SpyTheme.green : SpyTheme.muted)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        if item.isUnread {
                            Circle()
                                .fill(SpyTheme.red)
                                .frame(width: 7, height: 7)
                                .shadow(color: SpyTheme.red.opacity(0.65), radius: 5)
                        }

                        Text(item.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(item.isUnread ? Color.white : SpyTheme.bodyText)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 2)
                    }

                    Text(item.body)
                        .font(.system(size: 14))
                        .foregroundStyle(item.isUnread ? SpyTheme.bodyText : SpyTheme.muted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        if item.isImportant && !item.isSocialRequest {
                            Text(copy.important)
                                .foregroundStyle(SpyTheme.red)
                        }
                        Text(formattedTimestamp(item.publishedAt))
                            .foregroundStyle(SpyTheme.dim)
                        if item.actionableDeepLink != nil {
                            Spacer(minLength: 4)
                            Text(copy.openTitle(item))
                                .foregroundStyle(SpyTheme.green)
                            Image(systemName: "arrow.up.right")
                                .foregroundStyle(SpyTheme.green)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                }

            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                item.isUnread ? SpyTheme.panel : SpyTheme.panel.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(
                        SpyTheme.stroke,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.985))
        .id(item.id)
        .accessibilityLabel(copy.itemAccessibility(item))
        .accessibilityIdentifier("notifications.item.\(item.id)")
    }

    private func formattedTimestamp(_ rawValue: String) -> String {
        guard let date = NotificationInboxTimestampParser.date(from: rawValue) else { return rawValue }
        return date.formatted(
            .dateTime
                .locale(Locale(identifier: language.localeIdentifier))
                .day()
                .month(.abbreviated)
                .hour()
                .minute()
        )
    }
}

private struct NotificationAuthorizationControl: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    let language: AppLanguage

    @State private var authorizationStatus: UNAuthorizationStatus?
    @State private var isRequesting = false
    @State private var requestFailed = false

    private var copy: NotificationInboxCopy {
        NotificationInboxCopy(language: language)
    }

    private var needsAuthorization: Bool {
        authorizationStatus == .notDetermined || authorizationStatus == .denied
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if SupabaseAppRuntime.isEnabled && !SupabaseAppRuntime.permitsPush {
                Text(copy.stagingPushUnavailable)
                    .font(SpyTheme.micro)
                    .foregroundStyle(SpyTheme.muted)
                    .padding(14)
                    .accessibilityIdentifier("notifications.stagingPushUnavailable")
            } else if needsAuthorization {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        HapticManager.shared.fire(.buttonPress)
                        if authorizationStatus == .denied {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            openURL(url)
                        } else {
                            requestFailed = false
                            isRequesting = true
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if isRequesting {
                                SpySpinner(size: 18, accent: SpyTheme.green)
                                    .accessibilityHidden(true)
                            } else {
                                Image(systemName: "bell.badge")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(SpyTheme.green)
                                    .accessibilityHidden(true)
                            }

                            VStack(alignment: .leading, spacing: 5) {
                                Text(copy.enableNotifications)
                                    .font(.system(size: 11, weight: .black, design: .monospaced))
                                    .foregroundStyle(.white)
                                Text(authorizationStatus == .denied
                                    ? copy.notificationSettingsDetail
                                    : copy.notificationPermissionDetail)
                                    .font(SpyTheme.micro)
                                    .foregroundStyle(SpyTheme.muted)
                            }
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 0)

                            Image(systemName: authorizationStatus == .denied ? "arrow.up.right" : "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(SpyTheme.dim)
                                .accessibilityHidden(true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                        .background(SpyTheme.panel, in: CutCornerShape(cut: 8))
                        .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.strokeStrong, lineWidth: 1))
                        .contentShape(CutCornerShape(cut: 8))
                    }
                    .buttonStyle(SpyWebPressStyle(pressedScale: 0.98))
                    .disabled(isRequesting)
                    .accessibilityIdentifier("notifications.enablePush")

                    if requestFailed {
                        Text(copy.notificationPermissionError)
                            .font(SpyTheme.micro)
                            .foregroundStyle(SpyTheme.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("notifications.enablePush.error")
                    }
                }
                .padding(.top, 16)
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, !isRequesting else { return }
            let status = await PushNotificationCoordinator.shared.notificationAuthorizationStatus()
            guard !Task.isCancelled, !isRequesting else { return }
            authorizationStatus = status
        }
        .task(id: isRequesting) {
            guard isRequesting else { return }
            defer { isRequesting = false }
            do {
                let status = try await PushNotificationCoordinator.shared.requestNotificationAuthorization()
                guard !Task.isCancelled else { return }
                authorizationStatus = status
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                requestFailed = true
            }
        }
    }
}

private struct NotificationComposerRoute: Identifiable {
    let id = UUID()
}

private struct NotificationGlobalComposerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: NotificationInboxStore
    let language: AppLanguage

    @State private var draft = NotificationGlobalDraft()
    @State private var isConfirmingImportantPublish = false

    private var copy: NotificationInboxCopy {
        NotificationInboxCopy(language: language)
    }

    private var canPublish: Bool {
        draft.title.nilIfBlank != nil &&
            draft.body.nilIfBlank != nil &&
            !store.isPublishing
    }

    var body: some View {
        ZStack {
            SpyBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    sheetHeader

                    SpyPanel(accent: draft.importance == .important ? SpyTheme.red : SpyTheme.green) {
                        VStack(alignment: .leading, spacing: 16) {
                            importanceSelector
                            composerField(
                                title: copy.composerTitleField,
                                placeholder: copy.composerTitlePlaceholder,
                                text: titleBinding,
                                maxLength: 80
                            )
                            bodyEditor
                            composerField(
                                title: copy.deepLink,
                                placeholder: "spyclash://...",
                                text: Binding(
                                    get: { draft.actionDeepLink ?? "" },
                                    set: { value in
                                        updateDraft { $0.actionDeepLink = value.boundedUnicodeScalars(512) }
                                    }
                                ),
                                maxLength: 512
                            )
                        }
                    }

                    if let error = store.publishingError {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(SpyTheme.red)
                            Text(error)
                                .font(SpyTheme.micro)
                                .foregroundStyle(SpyTheme.muted)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SpyTheme.red.opacity(0.08), in: CutCornerShape(cut: 8))
                    }

                    Button {
                        if NotificationPublishConfirmationPolicy.requiresConfirmation(
                            for: draft.importance
                        ) {
                            isConfirmingImportantPublish = true
                        } else {
                            publishDraft()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if store.isPublishing {
                                SpySpinner(size: 17, accent: .white)
                            } else {
                                Image(systemName: "paperplane.fill")
                            }
                            Text(store.isPublishing ? copy.publishing : copy.publish)
                        }
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .tracking(0.08)
                        .frame(maxWidth: .infinity, minHeight: 58)
                    }
                    .buttonStyle(SpyPrimaryCommandStyle())
                    .disabled(!canPublish)
                    .opacity(canPublish ? 1 : 0.45)
                    .accessibilityIdentifier("notifications.composer.publish")
                }
                .padding(.horizontal, 18)
                .padding(.top, 24)
                .padding(.bottom, 36)
            }
        }
        .confirmationDialog(
            copy.importantConfirmationTitle,
            isPresented: $isConfirmingImportantPublish,
            titleVisibility: .visible
        ) {
            Button(copy.importantConfirmationAction, role: .destructive) {
                publishDraft()
            }
            Button(copy.cancel, role: .cancel) {}
        } message: {
            Text(copy.importantConfirmationDetail)
        }
        .onDisappear {
            store.cancelPendingPublish(requestID: draft.requestID)
        }
    }

    private var sheetHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text(copy.composerTitle)
                    .font(.system(size: 25, weight: .black, design: .monospaced))
                    .tracking(0.06)
                    .foregroundStyle(.white)
                Text(copy.composerDetail)
                    .font(SpyTheme.micro)
                    .foregroundStyle(SpyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(SpyTheme.muted)
                    .frame(width: 44, height: 44)
                    .background(SpyTheme.panel, in: CutCornerShape(cut: 8))
                    .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.strokeStrong, lineWidth: 1))
            }
            .buttonStyle(SpyWebPressStyle(pressedScale: 0.92))
            .disabled(store.isPublishing)
            .accessibilityLabel(copy.close)
        }
    }

    private var importanceSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(copy.deliveryMode)
                .font(SpyTheme.micro)
                .tracking(0.10)
                .foregroundStyle(SpyTheme.dim)

            HStack(spacing: 8) {
                ForEach(NotificationInboxImportance.allCases) { importance in
                    Button {
                        updateDraft { $0.importance = importance }
                        HapticManager.shared.fire(.tabSelection)
                    } label: {
                        Label(
                            copy.importanceTitle(importance),
                            systemImage: importance == .important ? "exclamationmark.triangle.fill" : "moon.fill"
                        )
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(0.06)
                        .foregroundStyle(
                            draft.importance == importance
                                ? Color.white
                                : SpyTheme.muted
                        )
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(
                            draft.importance == importance
                                ? (importance == .important ? SpyTheme.red.opacity(0.18) : SpyTheme.green.opacity(0.12))
                                : SpyTheme.control,
                            in: CutCornerShape(cut: 7)
                        )
                        .overlay(
                            CutCornerShape(cut: 7)
                                .stroke(
                                    draft.importance == importance
                                        ? (importance == .important ? SpyTheme.red : SpyTheme.green)
                                        : SpyTheme.strokeStrong,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(SpyWebPressStyle(pressedScale: 0.95))
                }
            }
        }
    }

    private func composerField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        maxLength: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(text.wrappedValue.unicodeScalars.count)/\(maxLength)")
            }
            .font(SpyTheme.micro)
            .tracking(0.08)
            .foregroundStyle(SpyTheme.dim)

            TextField(placeholder, text: Binding(
                get: { text.wrappedValue },
                set: { text.wrappedValue = $0.boundedUnicodeScalars(maxLength) }
            ))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.sentences)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(minHeight: 52)
            .background(SpyTheme.panelDeep, in: CutCornerShape(cut: 8))
            .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.inputBorder, lineWidth: 1))
        }
    }

    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(copy.composerBody)
                Spacer()
                Text("\(draft.body.unicodeScalars.count)/800")
            }
            .font(SpyTheme.micro)
            .tracking(0.08)
            .foregroundStyle(SpyTheme.dim)

            ZStack(alignment: .topLeading) {
                if draft.body.isEmpty {
                    Text(copy.composerBodyPlaceholder)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(SpyTheme.dim)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 17)
                        .allowsHitTesting(false)
                }

                TextEditor(text: Binding(
                    get: { draft.body },
                    set: { value in
                        updateDraft { $0.body = value.boundedUnicodeScalars(800) }
                    }
                ))
                .scrollContentBackground(.hidden)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(10)
                .frame(minHeight: 160)
            }
            .background(SpyTheme.panelDeep, in: CutCornerShape(cut: 8))
            .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.inputBorder, lineWidth: 1))
        }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { draft.title },
            set: { value in
                updateDraft { $0.title = value.boundedUnicodeScalars(80) }
            }
        )
    }

    private func updateDraft(_ update: (inout NotificationGlobalDraft) -> Void) {
        var nextDraft = draft
        update(&nextDraft)
        guard nextDraft != draft else { return }

        store.cancelPendingPublish(requestID: draft.requestID)
        store.clearPublishingError()
        nextDraft.requestID = UUID()
        draft = nextDraft
    }

    private func publishDraft() {
        Task {
            let succeeded = await store.publishGlobal(draft)
            if succeeded {
                HapticManager.shared.fire(.notification(.success))
                dismiss()
            } else {
                HapticManager.shared.fire(.notification(.error))
            }
        }
    }
}

private struct NotificationInboxCopy {
    let language: AppLanguage

    var eyebrow: String { text("// NOTIFICATIONS", "// УВЕДОМЛЕНИЯ", "// NOTIFICACIONES", "// СПОВІЩЕННЯ") }
    var title: String { text("Notifications", "Уведомления", "Notificaciones", "Сповіщення") }
    var subtitle: String { text("Friends, invitations and news", "Друзья, приглашения и новости", "Amigos, invitaciones y novedades", "Друзі, запрошення та новини") }
    var markAll: String { text("Read all", "Прочитать все", "Leer todo", "Прочитати все") }
    var loading: String { text("Loading notifications…", "Загружаем уведомления…", "Cargando notificaciones…", "Завантажуємо сповіщення…") }
    var loadingMore: String { text("LOADING MORE", "ЗАГРУЗКА", "CARGANDO", "ЗАВАНТАЖЕННЯ") }
    var loadMore: String { text("LOAD MORE", "ЗАГРУЗИТЬ ЕЩЕ", "CARGAR MÁS", "ЗАВАНТАЖИТИ ЩЕ") }
    var unavailable: String { text("CHANNEL UNAVAILABLE", "КАНАЛ НЕДОСТУПЕН", "CANAL NO DISPONIBLE", "КАНАЛ НЕДОСТУПНИЙ") }
    var retry: String { text("RETRY", "ПОВТОРИТЬ", "REINTENTAR", "ПОВТОРИТИ") }
    var important: String { text("IMPORTANT", "ВАЖНО", "IMPORTANTE", "ВАЖЛИВО") }
    var compose: String { text("Publish global notification", "Опубликовать общее уведомление", "Publicar notificación global", "Опублікувати загальне сповіщення") }
    var close: String { text("Close", "Закрыть", "Cerrar", "Закрити") }
    var enableNotifications: String { text("ENABLE NOTIFICATIONS", "ВКЛЮЧИТЬ УВЕДОМЛЕНИЯ", "ACTIVAR NOTIFICACIONES", "УВІМКНУТИ СПОВІЩЕННЯ") }
    var notificationPermissionDetail: String { text("Get game invitations and friend requests.", "Получайте приглашения в игру и запросы в друзья.", "Recibe invitaciones a partidas y solicitudes de amistad.", "Отримуйте запрошення до гри та запити в друзі.") }
    var notificationSettingsDetail: String { text("Enable SpyClash notifications in iPhone Settings.", "Включите уведомления SpyClash в настройках iPhone.", "Activa las notificaciones de SpyClash en los ajustes del iPhone.", "Увімкніть сповіщення SpyClash у налаштуваннях iPhone.") }
    var stagingPushUnavailable: String { text("Push delivery is not configured for this test app yet. Your inbox remains available here.", "Push-уведомления пока не подключены к тестовой сборке. Сообщения доступны здесь, во входящих.", "Las notificaciones push aún no están configuradas para esta app de prueba. La bandeja de entrada sigue disponible aquí.", "Push-сповіщення ще не підключено до тестової збірки. Повідомлення доступні тут, у вхідних.") }
    var notificationPermissionError: String { text("Couldn't enable notifications. Try again.", "Не удалось включить уведомления. Попробуйте ещё раз.", "No se pudieron activar las notificaciones. Inténtalo de nuevo.", "Не вдалося увімкнути сповіщення. Спробуйте ще раз.") }
    var composerTitle: String { text("GLOBAL TRANSMISSION", "ОБЩАЯ ПЕРЕДАЧА", "TRANSMISIÓN GLOBAL", "ЗАГАЛЬНА ПЕРЕДАЧА") }
    var composerDetail: String { text("Admin-only message for every operative", "Сообщение администратора для всех игроков", "Mensaje de administración para todos", "Повідомлення адміністратора для всіх гравців") }
    var composerTitleField: String { text("TITLE", "ЗАГОЛОВОК", "TÍTULO", "ЗАГОЛОВОК") }
    var composerTitlePlaceholder: String { text("Operation update", "Обновление операции", "Actualización de operación", "Оновлення операції") }
    var composerBody: String { text("MESSAGE", "СООБЩЕНИЕ", "MENSAJE", "ПОВІДОМЛЕННЯ") }
    var composerBodyPlaceholder: String { text("Enter the transmission text…", "Введите текст передачи…", "Introduce el mensaje…", "Введіть текст повідомлення…") }
    var deepLink: String { text("OPTIONAL DEEP LINK", "ССЫЛКА В ПРИЛОЖЕНИИ — НЕОБЯЗАТЕЛЬНО", "ENLACE OPCIONAL", "ПОСИЛАННЯ У ЗАСТОСУНКУ — НЕОБОВʼЯЗКОВО") }
    var deliveryMode: String { text("DELIVERY MODE", "РЕЖИМ ДОСТАВКИ", "MODO DE ENTREGA", "РЕЖИМ ДОСТАВЛЕННЯ") }
    var publish: String { text("PUBLISH TRANSMISSION", "ОПУБЛИКОВАТЬ", "PUBLICAR TRANSMISIÓN", "ОПУБЛІКУВАТИ") }
    var publishing: String { text("PUBLISHING", "ПУБЛИКАЦИЯ", "PUBLICANDO", "ПУБЛІКАЦІЯ") }
    var cancel: String { text("CANCEL", "ОТМЕНА", "CANCELAR", "СКАСУВАТИ") }
    var importantConfirmationTitle: String { text("SEND IMPORTANT ALERT?", "ОТПРАВИТЬ ВАЖНОЕ УВЕДОМЛЕНИЕ?", "¿ENVIAR ALERTA IMPORTANTE?", "НАДІСЛАТИ ВАЖЛИВЕ СПОВІЩЕННЯ?") }
    var importantConfirmationAction: String { text("SEND TO ALL OPERATIVES", "ОТПРАВИТЬ ВСЕМ ИГРОКАМ", "ENVIAR A TODOS", "НАДІСЛАТИ ВСІМ ГРАВЦЯМ") }
    var importantConfirmationDetail: String { text(
        "This transmission may display a system notification and ping every eligible operative.",
        "Эта передача может показать системное уведомление и оповестить каждого доступного игрока.",
        "Esta transmisión puede mostrar una notificación del sistema y avisar a todos los jugadores disponibles.",
        "Це повідомлення може показати системне сповіщення та сповістити всіх доступних гравців."
    ) }

    func status(unread: Int) -> String {
        unread == 0
            ? text("CLEAR", "ЧИСТО", "DESPEJADO", "ЧИСТО")
            : text("\(unread) UNREAD", "НЕПРОЧИТАНО: \(unread)", "\(unread) SIN LEER", "НЕПРОЧИТАНО: \(unread)")
    }

    func scopeTitle(_ scope: NotificationInboxScope) -> String {
        switch scope {
        case .global: text("General", "Общие", "Generales", "Загальні")
        case .personal: text("Personal", "Личные", "Personales", "Особисті")
        }
    }

    func scopeDetail(_ scope: NotificationInboxScope) -> String {
        switch scope {
        case .global: text("News from SpyClash", "Новости SpyClash", "Novedades de SpyClash", "Новини SpyClash")
        case .personal: text("Friend requests and game invitations", "Заявки в друзья и приглашения в игру", "Solicitudes de amistad e invitaciones", "Заявки в друзі та запрошення до гри")
        }
    }

    func requestDetail(_ action: NotificationInboxSocialActionKind) -> String {
        action == .join
            ? text("Invites you to a game", "Приглашает вас в игру", "Te invita a una partida", "Запрошує вас до гри")
            : text("Wants to add you as a friend", "Хочет добавить вас в друзья", "Quiere añadirte como amigo", "Хоче додати вас у друзі")
    }

    func actionTitle(_ action: NotificationInboxSocialActionKind) -> String {
        switch action {
        case .accept: text("Accept", "Принять", "Aceptar", "Прийняти")
        case .decline: text("Decline", "Отклонить", "Rechazar", "Відхилити")
        case .join: text("Join game", "Войти в игру", "Unirse", "Увійти в гру")
        }
    }

    func openTitle(_ item: NotificationInboxItem) -> String {
        switch item.kind {
        case "friend_request": text("View request", "Открыть заявку", "Ver solicitud", "Відкрити заявку")
        case "room_invite": text("View invitation", "Открыть приглашение", "Ver invitación", "Відкрити запрошення")
        default: text("Open", "Открыть", "Abrir", "Відкрити")
        }
    }

    func emptyTitle(_ scope: NotificationInboxScope) -> String {
        scope == .personal
            ? text("No invitations yet", "Приглашений пока нет", "Aún no hay invitaciones", "Запрошень поки немає")
            : text("You're all caught up", "Вы всё прочитали", "Estás al día", "Ви все прочитали")
    }

    func scopeAccessibility(_ scope: NotificationInboxScope, unread: Int) -> String {
        text(
            "\(scopeTitle(scope)), \(unread) unread",
            "\(scopeTitle(scope)), непрочитано: \(unread)",
            "\(scopeTitle(scope)), \(unread) sin leer",
            "\(scopeTitle(scope)), непрочитано: \(unread)"
        )
    }

    func emptyDetail(_ scope: NotificationInboxScope) -> String {
        switch scope {
        case .global:
            text("No command broadcasts yet.", "Новых общих сообщений пока нет.", "Todavía no hay mensajes globales.", "Нових загальних повідомлень поки немає.")
        case .personal:
            text("Friend requests and game invitations will appear here. Accept them with one tap.", "Здесь появятся заявки в друзья и приглашения в игру. Принимайте их одним нажатием.", "Aquí verás las solicitudes de amistad y las invitaciones. Acéptalas con un toque.", "Тут з’являться заявки в друзі та запрошення до гри. Приймайте їх одним натисканням.")
        }
    }

    func importanceTitle(_ importance: NotificationInboxImportance) -> String {
        switch importance {
        case .quiet: text("QUIET", "ТИХОЕ", "SILENCIOSA", "ТИХЕ")
        case .important: text("IMPORTANT", "ВАЖНОЕ", "IMPORTANTE", "ВАЖЛИВЕ")
        }
    }

    func itemAccessibility(_ item: NotificationInboxItem) -> String {
        let state = item.isUnread
            ? text("unread", "не прочитано", "sin leer", "не прочитано")
            : text("read", "прочитано", "leído", "прочитано")
        return "\(item.title), \(state). \(item.body)"
    }

    private func text(_ en: String, _ ru: String, _ es: String, _ uk: String) -> String {
        switch language {
        case .en: en
        case .ru: ru
        case .es: es
        case .uk: uk
        }
    }
}

private extension AppLanguage {
    var localeIdentifier: String {
        switch self {
        case .en: "en_US"
        case .ru: "ru_RU"
        case .es: "es_ES"
        case .uk: "uk_UA"
        }
    }
}
