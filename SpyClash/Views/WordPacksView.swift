import SwiftUI

struct WordPacksView: View {
    @Environment(AppState.self) private var appState

    @State private var packs: [WordPack] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var editor: WordPackEditorRoute?
    @State private var deleteTarget: WordPack?
    @State private var showDeleteConfirmation = false
    @State private var deletingID: String?
    @State private var loadRequestID: UUID?
    @State private var packMutationRevision = 0

    private var copy: WordPacksCopy {
        appState.language.wordPacks
    }

    private var flowCopy: WordPackEditorFlowCopy {
        appState.language.wordPackEditorFlow
    }

    var body: some View {
        ZStack {
            PageChrome(eyebrow: copy.eyebrow, status: copy.status) {
                VStack(alignment: .leading, spacing: 18) {
                    packsSceneHero
                    listContent
                }
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .spyWebEntrance(duration: 0.35, y: -16, scale: 0.98)
            }
            .disabled(editor != nil || showDeleteConfirmation)
            .accessibilityHidden(editor != nil || showDeleteConfirmation)
        }
        .task {
            await load()
        }
        .fullScreenCover(item: $editor) { route in
            WordPackEditorSheet(route: route) { savedPack in
                applySavedPack(savedPack)
            }
            .spyGlobalToastLayer()
            .spyInterfaceScale()
        }
        .overlay {
            if showDeleteConfirmation, let deleteTarget {
                SpyConfirmDialog(
                    title: copy.deleteDialogTitle,
                    message: copy.deleteMessage(for: deleteTarget),
                    confirmTitle: copy.deleteAction(for: deleteTarget),
                    cancelTitle: copy.cancel,
                    isBusy: deletingID == deleteTarget.id
                ) {
                    Task { await delete(deleteTarget) }
                } onCancel: {
                    showDeleteConfirmation = false
                    self.deleteTarget = nil
                }
                .zIndex(10)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
            }
        }
        .animation(.smooth(duration: 0.22), value: showDeleteConfirmation)
        .onChange(of: showDeleteConfirmation, initial: true) { _, _ in
            updateShellSuppression()
        }
        .onChange(of: editor, initial: true) { _, _ in
            updateShellSuppression()
        }
        .onDisappear {
            if showDeleteConfirmation || editor != nil {
                appState.isShellChromeSuppressed = false
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if isLoading && packs.isEmpty {
            loadingPanel
        } else if loadError != nil && packs.isEmpty {
            loadErrorPanel
        } else if packs.isEmpty {
            emptyPanel
        } else {
            LazyVStack(spacing: 12) {
                ForEach(Array(packs.enumerated()), id: \.element.id) { index, pack in
                    packPanel(pack, index: index)
                        .transition(.opacity)
                }
            }
        }
    }

    private var packsSceneHero: some View {
        SpySceneStage(accent: SpyTheme.red, motionDelay: 0, minHeight: 198, isSubtle: true) {
            VStack(alignment: .leading, spacing: 12) {
                SpySceneKicker(
                    title: localized(
                        en: "WORD PACK LIBRARY",
                        ru: "БИБЛИОТЕКА НАБОРОВ",
                        es: "BIBLIOTECA DE PACKS",
                        uk: "БІБЛІОТЕКА НАБОРІВ"
                    ),
                    status: nil,
                    accent: SpyTheme.red
                )

                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        AnimatedTitle(
                            text: copy.title.uppercased(),
                            delay: 0.18,
                            fontSize: 29,
                            letterSpacing: 3
                        )

                        Text(localized(
                            en: "Create once, then reuse the pack in local and online games.",
                            ru: "Создай набор один раз и используй его в локальных и онлайн-играх.",
                            es: "Crea un pack una vez y úsalo en partidas locales y online.",
                            uk: "Створи набір один раз і використовуй його в локальних та онлайн-іграх."
                        ))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SpyTheme.muted)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 4)

                    Button {
                        Task { await load() }
                    } label: {
                        Group {
                            if isLoading {
                                SpySpinner(size: 17, accent: SpyTheme.muted)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 15, weight: .black))
                            }
                        }
                        .foregroundStyle(SpyTheme.muted)
                        .frame(width: 44, height: 44)
                        .overlay(Rectangle().stroke(SpyTheme.strokeStrong, lineWidth: 1))
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .disabled(isLoading)
                    .accessibilityLabel(localized(
                        en: "Refresh word packs",
                        ru: "Обновить наборы слов",
                        es: "Actualizar packs de palabras",
                        uk: "Оновити набори слів"
                    ))
                }

                HStack(spacing: 18) {
                    packHeroMetric(
                        String(format: "%02d", packs.count),
                        label: localized(en: "PACKS", ru: "НАБОРЫ", es: "PACKS", uk: "НАБОРИ")
                    )
                    packHeroMetric(
                        String(format: "%03d", totalWordCount),
                        label: localized(en: "WORDS", ru: "СЛОВА", es: "PALABRAS", uk: "СЛОВА")
                    )
                    packHeroMetric(
                        String(format: "%02d", averageWordCount),
                        label: flowCopy.averagePerPack
                    )
                }

                Button {
                    editor = .create
                } label: {
                    SpyPrimaryCommandLabel(
                        title: flowCopy.addTitle,
                        detail: nil,
                        systemImage: "plus"
                    )
                }
                .buttonStyle(SpyPrimaryCommandStyle())
                .accessibilityIdentifier("wordPacks.add")
            }
        }
    }

    private var loadingPanel: some View {
        SpyPanel(motionDelay: 0.08) {
            HStack(spacing: 10) {
                SpySpinner(size: 20, accent: SpyTheme.red)
                Text(copy.loading)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker(lines: 2)
            }
            .frame(maxWidth: .infinity, minHeight: 90)
        }
    }

    private var emptyPanel: some View {
        SpyPanel(motionDelay: 0.12) {
            VStack(spacing: 16) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(SpyTheme.red)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text(copy.emptyTitle)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(.white.opacity(0.84))
                        .spyKicker(lines: 2, alignment: .center)

                    Text(copy.emptyBody)
                        .font(.system(size: 12, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(SpyTheme.muted)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    editor = .create
                } label: {
                    Label(copy.createFirstPack, systemImage: "plus")
                }
                .buttonStyle(SpyButtonStyle(variant: .outline))
            }
            .frame(maxWidth: .infinity, minHeight: 164)
        }
    }

    private var loadErrorPanel: some View {
        SpyPanel(motionDelay: 0.12) {
            VStack(spacing: 14) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(SpyTheme.red)
                    .accessibilityHidden(true)

                Text(flowCopy.loadFailedTitle)
                    .font(SpyTheme.micro)
                    .tracking(0.10)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(flowCopy.loadFailedBody)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SpyTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await load() }
                } label: {
                    Label(flowCopy.retry, systemImage: "arrow.clockwise")
                }
                .buttonStyle(SpyButtonStyle(variant: .outline))
                .disabled(isLoading)
            }
            .frame(maxWidth: .infinity, minHeight: 176)
        }
    }

    private func packPanel(_ pack: WordPack, index: Int) -> some View {
        SpyPanel(motionDelay: 0.12 + (Double(min(index, 6)) * 0.04)) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pack.name.uppercased())
                            .font(.system(size: 21, weight: .black))
                            .tracking(0.04)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.56)

                        HStack(spacing: 8) {
                            metaPill(
                                pack.category?.nilIfBlank ?? copy.customFallback,
                                systemName: "tag.fill"
                            )
                            metaPill(
                                copy.wordsLabel(pack.words?.count ?? 0),
                                systemName: "text.word.spacing"
                            )
                        }
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        smallActionButton(
                            "pencil",
                            accessibilityLabel: localized(
                                en: "Edit \(pack.name)",
                                ru: "Изменить \(pack.name)",
                                es: "Editar \(pack.name)",
                                uk: "Змінити \(pack.name)"
                            )
                        ) {
                            editor = .edit(pack)
                        }

                        smallActionButton(
                            "trash.fill",
                            accessibilityLabel: localized(
                                en: "Delete \(pack.name)",
                                ru: "Удалить \(pack.name)",
                                es: "Eliminar \(pack.name)",
                                uk: "Видалити \(pack.name)"
                            ),
                            accent: SpyTheme.red
                        ) {
                            deleteTarget = pack
                            showDeleteConfirmation = true
                        }
                        .disabled(deletingID == pack.id)
                    }
                }

                let wordCount = pack.words?.count ?? 0
                FlowWords(
                    words: Array((pack.words ?? []).prefix(12)),
                    overflowText: wordCount > 12 ? flowCopy.moreWords(wordCount - 12) : nil
                )
                .opacity(deletingID == pack.id ? 0.45 : 1)

                if deletingID == pack.id {
                    HStack(spacing: 8) {
                        SpySpinner(size: 18, accent: SpyTheme.red)
                        Text(copy.removingPack)
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                            .foregroundStyle(SpyTheme.dim)
                            .spyKicker(lines: 2)
                    }
                }
            }
        }
    }

    private func packHeroMetric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(SpyTheme.brandFont(size: 25))
                .foregroundStyle(.white)
            Text(label.uppercased())
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .tracking(0.07)
                .foregroundStyle(SpyTheme.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metaPill(_ text: String, systemName: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .accessibilityHidden(true)
            Text(text.uppercased())
                .spyFitted(scale: 0.66)
        }
        .font(.system(size: 10, weight: .bold))
        .tracking(0.02)
        .foregroundStyle(SpyTheme.dim)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(SpyTheme.panelDeep)
        .overlay(Rectangle().stroke(SpyTheme.stroke))
    }

    private func smallActionButton(
        _ symbol: String,
        accessibilityLabel: String,
        accent: Color = SpyTheme.muted,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(SpyTheme.panelDeep)
                .overlay(Rectangle().stroke(accent.opacity(0.35), lineWidth: 1))
                .accessibilityHidden(true)
        }
        .buttonStyle(SpyWebPressStyle())
        .spyHitTarget()
        .accessibilityLabel(accessibilityLabel)
    }

    private var totalWordCount: Int {
        packs.reduce(0) { $0 + ($1.words?.count ?? 0) }
    }

    private var averageWordCount: Int {
        guard !packs.isEmpty else { return 0 }
        return Int((Double(totalWordCount) / Double(packs.count)).rounded())
    }

    private func localized(en: String, ru: String, es: String, uk: String) -> String {
        switch appState.language {
        case .ru: ru
        case .es: es
        case .uk: uk
        default: en
        }
    }

    private func load() async {
        let requestID = UUID()
        let startingMutationRevision = packMutationRevision
        loadRequestID = requestID

        if appState.shouldUsePreviewData {
            packs = WordPack.localizedPreviewPacks(for: appState.language)
            loadError = nil
            isLoading = false
            loadRequestID = nil
            return
        }

        guard let email = appState.user?.email else {
            isLoading = false
            loadError = flowCopy.loadFailedBody
            loadRequestID = nil
            return
        }

        isLoading = true
        defer {
            if loadRequestID == requestID {
                isLoading = false
                loadRequestID = nil
            }
        }

        do {
            let loadedPacks = try await appState.client.wordPacks(ownerEmail: email)
            guard loadRequestID == requestID,
                  packMutationRevision == startingMutationRevision else {
                return
            }
            withAnimation(SpyMotion.page) {
                packs = loadedPacks
            }
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            guard loadRequestID == requestID,
                  packMutationRevision == startingMutationRevision else {
                return
            }
            let message = error.localizedDescription.uppercased()
            loadError = message
            if !packs.isEmpty {
                appState.showToast(message, kind: .error)
            }
        }
    }

    private func applySavedPack(_ savedPack: WordPack) {
        recordLocalMutation()
        withAnimation(SpyMotion.page) {
            if let index = packs.firstIndex(where: { $0.id == savedPack.id }) {
                packs[index] = savedPack
            } else {
                packs.append(savedPack)
            }
            packs.sort {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        loadError = nil
        appState.showToast(flowCopy.savedMessage, kind: .success)
    }

    private func delete(_ pack: WordPack) async {
        deletingID = pack.id
        defer { deletingID = nil }

        do {
            try await appState.client.deleteWordPack(id: pack.id)
            recordLocalMutation()
            withAnimation(SpyMotion.page) {
                packs.removeAll { $0.id == pack.id }
            }
            loadError = nil
            appState.markWordPacksChanged()
            deleteTarget = nil
            showDeleteConfirmation = false
            HapticManager.shared.fire(.notification(.success))
        } catch is CancellationError {
            return
        } catch {
            showDeleteConfirmation = false
            appState.showToast(error.localizedDescription.uppercased(), kind: .error)
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func recordLocalMutation() {
        packMutationRevision += 1
        loadRequestID = nil
        isLoading = false
    }

    private func updateShellSuppression() {
        appState.isShellChromeSuppressed = showDeleteConfirmation || editor != nil
    }
}

enum WordPackEditorRoute: Identifiable, Hashable {
    case create
    case edit(WordPack)

    var id: String {
        switch self {
        case .create:
            "create"
        case .edit(let pack):
            "edit-\(pack.id)"
        }
    }

    var pack: WordPack? {
        switch self {
        case .create:
            nil
        case .edit(let pack):
            pack
        }
    }
}

struct FlowWords: View {
    let words: [String]
    var overflowText: String? = nil

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 92), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(words, id: \.self) { word in
                wordChip(word, isOverflow: false)
            }

            if let overflowText {
                wordChip(overflowText, isOverflow: true)
                    .accessibilityLabel(overflowText)
            }
        }
    }

    private func wordChip(_ text: String, isOverflow: Bool) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.02)
            .foregroundStyle(isOverflow ? SpyTheme.red : .white.opacity(0.76))
            .spyFitted(scale: 0.66, alignment: .center)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(SpyTheme.panelDeep)
            .overlay(
                Rectangle().stroke(
                    isOverflow ? SpyTheme.red.opacity(0.45) : SpyTheme.stroke
                )
            )
    }
}
