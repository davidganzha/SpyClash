import SwiftUI

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
                    header
                    scopeSelector
                    scopeActions
                    inboxContent
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
            }
            .refreshable {
                async let summary: Void = store.refreshSummary()
                async let page: Void = store.refresh(scope: store.selectedScope)
                _ = await (summary, page)
            }
            .task(id: store.accountID) {
                guard store.accountID != nil else { return }
                await store.loadInitial()
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
        withAnimation(.easeOut(duration: 0.24)) {
            proxy.scrollTo(focusItemID, anchor: .center)
        }
        _ = await store.markRead(item)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    AnimatedTitle(
                        text: copy.title,
                        redPrefixCount: 1,
                        delay: 0.12,
                        fontSize: 32,
                        letterSpacing: 1.6
                    )

                    Text(copy.subtitle)
                        .font(SpyTheme.micro)
                        .tracking(0.10)
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

            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(SpyTheme.green)
                Text(copy.serverSource)
                    .foregroundStyle(SpyTheme.dim)
            }
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .tracking(0.10)
        }
    }

    private var scopeSelector: some View {
        HStack(spacing: 8) {
            ForEach(NotificationInboxScope.allCases) { scope in
                scopeButton(scope)
            }
        }
        .padding(5)
        .background(SpyTheme.control, in: CutCornerShape(cut: 10))
        .overlay(CutCornerShape(cut: 10).stroke(SpyTheme.stroke, lineWidth: 1))
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
                Image(systemName: scope == .global ? "globe.europe.africa.fill" : "person.crop.circle.fill")
                    .font(.system(size: 13, weight: .black))

                Text(copy.scopeTitle(scope))
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.08)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)

                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(SpyTheme.red, in: Capsule())
                }
            }
            .foregroundStyle(isSelected ? Color.white : SpyTheme.muted)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(isSelected ? SpyTheme.panel : Color.clear, in: CutCornerShape(cut: 7))
            .overlay(
                CutCornerShape(cut: 7)
                    .stroke(isSelected ? SpyTheme.red.opacity(0.64) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.96))
        .accessibilityLabel(copy.scopeAccessibility(scope, unread: count))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("notifications.scope.\(scope.rawValue)")
    }

    private var scopeActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                scopeActionKicker
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 4)

                markAllReadButton
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 6) {
                scopeActionKicker

                markAllReadButton
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var scopeActionKicker: some View {
        SpySceneKicker(
            title: copy.channel,
            status: copy.scopeTitle(store.selectedScope),
            accent: store.selectedScope == .global ? SpyTheme.red : SpyTheme.green
        )
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
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.06)
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
            if feed.items.isEmpty {
                emptyPanel(scope: scope)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(feed.items) { item in
                        notificationRow(item)
                    }

                    if feed.isLoadingMore {
                        HStack(spacing: 10) {
                            SpySpinner(size: 16, accent: SpyTheme.red)
                            Text(copy.loadingMore)
                                .font(SpyTheme.micro)
                                .tracking(0.10)
                                .foregroundStyle(SpyTheme.muted)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                    } else if feed.canLoadMore {
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
        }
    }

    private var loadingPanel: some View {
        SpyPanel(accent: SpyTheme.red, motionDelay: 0.06) {
            HStack(spacing: 13) {
                SpySpinner(size: 22, accent: SpyTheme.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.loading)
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .tracking(0.08)
                        .foregroundStyle(.white)
                    Text(copy.loadingDetail)
                        .font(SpyTheme.micro)
                        .foregroundStyle(SpyTheme.dim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        SpyPanel(accent: SpyTheme.green, motionDelay: 0.06) {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(SpyTheme.green)

                Text(copy.emptyTitle)
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .tracking(0.08)
                    .foregroundStyle(.white)

                Text(copy.emptyDetail(scope))
                    .font(SpyTheme.micro)
                    .foregroundStyle(SpyTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
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
                    CutCornerShape(cut: 7)
                        .fill(item.isImportant ? SpyTheme.red.opacity(0.13) : SpyTheme.control)
                    Image(systemName: item.isImportant ? "exclamationmark.triangle.fill" : "envelope.fill")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(item.isImportant ? SpyTheme.red : SpyTheme.muted)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        if item.isUnread {
                            Circle()
                                .fill(SpyTheme.red)
                                .frame(width: 7, height: 7)
                                .shadow(color: SpyTheme.red.opacity(0.65), radius: 5)
                        }

                        Text(item.title.uppercased())
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .tracking(0.06)
                            .foregroundStyle(item.isUnread ? Color.white : SpyTheme.bodyText)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 2)
                    }

                    Text(item.body)
                        .font(.system(size: 12, weight: .medium, design: .default))
                        .foregroundStyle(item.isUnread ? SpyTheme.bodyText : SpyTheme.muted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        if item.isImportant {
                            Text(copy.important)
                                .foregroundStyle(SpyTheme.red)
                        }
                        Text(formattedTimestamp(item.publishedAt))
                            .foregroundStyle(SpyTheme.dim)
                        if item.actionableDeepLink != nil {
                            Spacer(minLength: 4)
                            Text(copy.open)
                                .foregroundStyle(SpyTheme.green)
                            Image(systemName: "arrow.up.right")
                                .foregroundStyle(SpyTheme.green)
                        }
                    }
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .tracking(0.08)
                }

                if store.pendingItemIDs.contains(item.id) {
                    SpySpinner(size: 16, accent: SpyTheme.green)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                item.isUnread ? SpyTheme.panel : SpyTheme.panel.opacity(0.72),
                in: CutCornerShape(cut: 11)
            )
            .overlay(
                CutCornerShape(cut: 11)
                    .stroke(
                        item.isImportant && item.isUnread
                            ? SpyTheme.red.opacity(0.66)
                            : SpyTheme.strokeStrong,
                        lineWidth: 1
                    )
            )
            .contentShape(CutCornerShape(cut: 11))
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.985))
        .disabled(store.isMutating(scope: item.scope) && !store.pendingItemIDs.contains(item.id))
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
    var title: String { text("INBOX", "ВХОДЯЩИЕ", "BANDEJA", "ВХІДНІ") }
    var subtitle: String { text("NETWORK SIGNALS AND PERSONAL OPERATIONS", "СИГНАЛЫ СЕТИ И ЛИЧНЫЕ ОПЕРАЦИИ", "SEÑALES DE RED Y OPERACIONES PERSONALES", "СИГНАЛИ МЕРЕЖІ ТА ОСОБИСТІ ОПЕРАЦІЇ") }
    var serverSource: String { text("SYNCED THROUGH SPYCLASH COMMAND", "СИНХРОНИЗИРОВАНО ЧЕРЕЗ SPYCLASH COMMAND", "SINCRONIZADO POR SPYCLASH COMMAND", "СИНХРОНІЗОВАНО ЧЕРЕЗ SPYCLASH COMMAND") }
    var channel: String { text("CHANNEL", "КАНАЛ", "CANAL", "КАНАЛ") }
    var markAll: String { text("READ ALL", "ПРОЧИТАТЬ ВСЕ", "LEER TODO", "ПРОЧИТАТИ ВСЕ") }
    var loading: String { text("SCANNING INBOX", "СКАНИРОВАНИЕ ВХОДЯЩИХ", "ESCANEANDO BANDEJA", "СКАНУВАННЯ ВХІДНИХ") }
    var loadingDetail: String { text("Verifying the latest server state", "Проверяем последнее состояние сервера", "Verificando el estado del servidor", "Перевіряємо останній стан сервера") }
    var loadingMore: String { text("LOADING MORE", "ЗАГРУЗКА", "CARGANDO", "ЗАВАНТАЖЕННЯ") }
    var loadMore: String { text("LOAD MORE", "ЗАГРУЗИТЬ ЕЩЕ", "CARGAR MÁS", "ЗАВАНТАЖИТИ ЩЕ") }
    var unavailable: String { text("CHANNEL UNAVAILABLE", "КАНАЛ НЕДОСТУПЕН", "CANAL NO DISPONIBLE", "КАНАЛ НЕДОСТУПНИЙ") }
    var retry: String { text("RETRY", "ПОВТОРИТЬ", "REINTENTAR", "ПОВТОРИТИ") }
    var emptyTitle: String { text("ALL CLEAR", "ВСЕ ЧИСТО", "TODO DESPEJADO", "УСЕ ЧИСТО") }
    var important: String { text("IMPORTANT", "ВАЖНО", "IMPORTANTE", "ВАЖЛИВО") }
    var open: String { text("OPEN", "ОТКРЫТЬ", "ABRIR", "ВІДКРИТИ") }
    var compose: String { text("Publish global notification", "Опубликовать общее уведомление", "Publicar notificación global", "Опублікувати загальне сповіщення") }
    var close: String { text("Close", "Закрыть", "Cerrar", "Закрити") }
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
        case .global: text("GLOBAL", "ОБЩИЕ", "GLOBAL", "ЗАГАЛЬНІ")
        case .personal: text("PERSONAL", "ЛИЧНЫЕ", "PERSONAL", "ОСОБИСТІ")
        }
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
            text("No personal operations are waiting.", "Новых личных операций пока нет.", "No hay operaciones personales pendientes.", "Нових особистих операцій поки немає.")
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
