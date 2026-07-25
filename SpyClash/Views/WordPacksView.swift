import SwiftUI

struct WordPacksView: View {
    @Environment(AppState.self) private var appState

    @State private var packs: [WordPack] = []
    @State private var isLoading = false
    @State private var status = ""
    @State private var editor: WordPackEditorRoute?
    @State private var deleteTarget: WordPack?
    @State private var showDeleteConfirmation = false
    @State private var deletingID: String?

    private var copy: WordPacksCopy {
        appState.language.wordPacks
    }

    var body: some View {
        PageChrome(eyebrow: copy.eyebrow, status: copy.status) {
            VStack(alignment: .leading, spacing: 18) {
                packsSceneHero

                if isLoading {
                    loadingPanel
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
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .spyWebEntrance(duration: 0.35, y: -16, scale: 0.98)
        }
        .task {
            if !appState.shouldUsePreviewData && appState.membership == nil {
                await appState.refreshSubscription()
            }
            await load()
        }
        .sheet(item: $editor, onDismiss: {
            Task { await load() }
        }) { route in
            WordPackEditorSheet(route: route)
                .spyGlobalToastLayer()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(0)
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
            }
        }
        .animation(.smooth(duration: 0.22), value: showDeleteConfirmation)
        .onChange(of: showDeleteConfirmation, initial: true) { _, isPresented in
            appState.isShellChromeSuppressed = isPresented
        }
        .onDisappear {
            if showDeleteConfirmation {
                appState.isShellChromeSuppressed = false
            }
        }
        .onChange(of: status) { _, message in
            publishWordPacksToast(message)
        }
    }

    private var packsSceneHero: some View {
        SpySceneStage(accent: SpyTheme.red, motionDelay: 0, minHeight: 198, isSubtle: true) {
            VStack(alignment: .leading, spacing: 12) {
                SpySceneKicker(
                    title: localized(en: "WORD PACKS", ru: "ПАКИ СЛОВ", es: "PACKS DE PALABRAS"),
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
                            en: "Build reusable intelligence for every mission.",
                            ru: "Собирай разведданные для каждой новой миссии.",
                            es: "Crea inteligencia reutilizable para cada mision."
                        ))
                        .font(.system(size: 11, weight: .semibold, design: .default))
                        .foregroundStyle(SpyTheme.muted)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 4)

                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(SpyTheme.muted)
                            .frame(width: 44, height: 44)
                            .overlay(Rectangle().stroke(SpyTheme.strokeStrong, lineWidth: 1))
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .disabled(isLoading)
                    .opacity(isLoading ? 0.45 : 1)
                }

                HStack(spacing: 18) {
                    packHeroMetric(String(format: "%02d", packs.count), label: localized(en: "PACKS", ru: "КОЛОДЫ", es: "PACKS"))
                    packHeroMetric(String(format: "%03d", totalWordCount), label: localized(en: "WORDS", ru: "СЛОВА", es: "PALABRAS"))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(featuredPackName.uppercased())
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .tracking(0.06)
                            .foregroundStyle(packs.isEmpty ? SpyTheme.dim : SpyTheme.red)
                            .lineLimit(1)
                            .minimumScaleFactor(0.58)
                        Text(localized(en: "LATEST INTEL", ru: "ПОСЛЕДНИЙ INTEL", es: "ULTIMO INTEL"))
                            .font(.system(size: 7, weight: .black, design: .monospaced))
                            .tracking(0.06)
                            .foregroundStyle(SpyTheme.faint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    editor = .create
                } label: {
                    SpyPrimaryCommandLabel(
                        title: localized(en: "CREATE WORD PACK", ru: "СОЗДАТЬ КОЛОДУ", es: "CREAR WORD PACK"),
                        detail: nil,
                        systemImage: "plus"
                    )
                }
                .buttonStyle(SpyPrimaryCommandStyle())
            }
        }
    }

    private var totalWordCount: Int {
        packs.reduce(0) { $0 + ($1.words?.count ?? 0) }
    }

    private var featuredPackName: String {
        packs.first?.name ?? localized(en: "NO PACKS", ru: "НЕТ КОЛОД", es: "SIN PACKS")
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
    }

    private var loadingPanel: some View {
        SpyPanel(motionDelay: 0.08) {
            HStack {
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
                VStack(spacing: 6) {
                    Text(copy.emptyTitle)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(.white.opacity(0.84))
                        .spyKicker(lines: 2, alignment: .center)
                    Text(copy.emptyBody)
                        .font(SpyTheme.micro)
                        .tracking(0.08)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(SpyTheme.dim)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 144)
        }
    }

    private func localized(en: String, ru: String, es: String) -> String {
        switch appState.language {
        case .ru: ru
        case .es: es
        default: en
        }
    }

    private func publishWordPacksToast(_ message: String) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        appState.showToast(message, kind: .error)
        status = ""
    }

    private func packPanel(_ pack: WordPack, index: Int) -> some View {
        SpyPanel(motionDelay: 0.12 + (Double(min(index, 6)) * 0.04)) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pack.name.uppercased())
                            .font(.system(size: 21, weight: .black, design: .default))
                            .tracking(0.04)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.56)

                        HStack(spacing: 8) {
                            metaPill(pack.category?.nilIfBlank ?? copy.customFallback, systemName: "tag.fill")
                            metaPill(copy.wordsLabel(pack.words?.count ?? 0), systemName: "text.word.spacing")
                        }
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        smallActionButton("pencil") {
                            editor = .edit(pack)
                        }

                        smallActionButton("trash.fill", accent: SpyTheme.red) {
                            deleteTarget = pack
                            showDeleteConfirmation = true
                        }
                        .disabled(deletingID == pack.id)
                    }
                }

                FlowWords(words: Array((pack.words ?? []).prefix(12)))
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

    private func metaPill(_ text: String, systemName: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
            Text(text.uppercased())
                .spyFitted(scale: 0.66)
        }
        .font(.system(size: 10, weight: .bold, design: .default))
        .tracking(0.02)
        .foregroundStyle(SpyTheme.dim)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(SpyTheme.panelDeep)
        .overlay(Rectangle().stroke(SpyTheme.stroke))
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(SpyTheme.red)
                .frame(width: 46, height: 46)
                .background(SpyTheme.panel)
                .overlay(CutCornerShape(cut: 9).stroke(SpyTheme.stroke, lineWidth: 1))
                .clipShape(CutCornerShape(cut: 9))
        }
        .buttonStyle(SpyWebPressStyle())
        .spyHitTarget()
    }

    private func smallActionButton(_ symbol: String, accent: Color = SpyTheme.muted, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(SpyTheme.panelDeep)
                .overlay(Rectangle().stroke(accent.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(SpyWebPressStyle())
        .spyHitTarget()
    }

    private func load() async {
        if appState.shouldUsePreviewData {
            packs = WordPack.previewPacks
            status = ""
            isLoading = false
            return
        }

        guard let email = appState.user?.email else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            packs = try await appState.client.wordPacks(ownerEmail: email)
            status = ""
        } catch {
            status = error.localizedDescription.uppercased()
        }
    }

    private func delete(_ pack: WordPack) async {
        deletingID = pack.id
        defer { deletingID = nil }
        do {
            try await appState.client.deleteWordPack(id: pack.id)
            withAnimation(SpyMotion.page) {
                packs.removeAll { $0.id == pack.id }
            }
            deleteTarget = nil
            showDeleteConfirmation = false
            status = ""
            HapticManager.shared.fire(.notification(.success))
        } catch {
            showDeleteConfirmation = false
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }
}

private enum WordPackEditorRoute: Identifiable, Hashable {
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

private struct WordPackEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let route: WordPackEditorRoute

    @State private var name: String
    @State private var category: String
    @State private var wordsText: String
    @State private var aiTheme: String
    @State private var aiWordCount: Double
    @State private var isGenerating = false
    @State private var isSaving = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case name
        case category
        case words
    }

    private enum EditorStatusKind {
        case success
        case error
    }

    private var copy: WordPackEditorCopy {
        appState.language.wordPacks.editor
    }

    init(route: WordPackEditorRoute) {
        self.route = route
        let pack = route.pack
        _name = State(initialValue: pack?.name ?? "")
        _category = State(initialValue: pack?.category ?? "")
        _wordsText = State(initialValue: (pack?.words ?? []).joined(separator: "\n"))
        _aiTheme = State(initialValue: pack?.category ?? pack?.name ?? "")
        _aiWordCount = State(initialValue: Double(max(12, min(100, pack?.words?.count ?? 12))))
    }

    var body: some View {
        ZStack {
            SpyBackground()
            VStack(spacing: 0) {
                sheetHeader
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        SpyPanel {
                            VStack(alignment: .leading, spacing: 18) {
                                summaryStrip
                                aiPanel
                                textFieldSection(
                                    label: copy.packNameLabel,
                                    placeholder: copy.packNamePlaceholder,
                                    text: $name,
                                    focus: .name
                                )
                                textFieldSection(
                                    label: copy.categoryLabel,
                                    placeholder: copy.categoryPlaceholder,
                                    text: $category,
                                    focus: .category
                                )
                                wordsSection
                                saveButton
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
        }
        .task {
            if !appState.shouldUsePreviewData && appState.membership == nil {
                await appState.refreshSubscription()
            }
        }
    }

    private var sheetHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(copy.eyebrow)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker()
                Text(copy.title(isEditing: route.pack != nil))
                    .font(.system(size: 26, weight: .black, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(.white)
                    .spyFitted(lines: 2, scale: 0.58)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(SpyTheme.red)
                    .frame(width: 42, height: 42)
                    .background(SpyTheme.panel)
                    .overlay(CutCornerShape(cut: 9).stroke(SpyTheme.stroke, lineWidth: 1))
                    .clipShape(CutCornerShape(cut: 9))
            }
            .buttonStyle(SpyWebPressStyle())
            .spyHitTarget()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(SpyTheme.black)
    }

    private var summaryStrip: some View {
        HStack(spacing: 10) {
            editorStat(copy.wordsMetric, "\(words.count)", accent: words.count >= 2 ? SpyTheme.green : SpyTheme.red)
            editorStat(copy.modeMetric, copy.mode(isEditing: route.pack != nil), accent: SpyTheme.red)
        }
    }

    private var aiPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(SpyTheme.red)
                Text(copy.aiGeneration)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker(lines: 2)
                Spacer()
                Text("\(aiCount)")
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .foregroundStyle(SpyTheme.red)
            }

            SpyInput(
                label: nil,
                placeholder: copy.themePlaceholder,
                text: $aiTheme,
                icon: "sparkles",
                isFocused: focusedField == .category,
                autocapitalization: .sentences
            )

            VStack(alignment: .leading, spacing: 8) {
                SpyWebSlider(value: $aiWordCount, range: 5...100, step: 1)
                HStack {
                    Text("5")
                    Spacer()
                    Text(copy.wordsToGenerate)
                    Spacer()
                    Text("100")
                }
                .font(SpyTheme.micro)
                .tracking(0.08)
                .foregroundStyle(SpyTheme.dim)
            }

            Button {
                Task { await generateWithAI() }
            } label: {
                if isGenerating {
                    SpyLoadingLabel(title: copy.generateWords, accent: .white)
                } else {
                    Label(copy.generateWords, systemImage: "sparkles")
                }
            }
            .buttonStyle(SpyButtonStyle(variant: .outline))
            .disabled(!canGenerate)
            .opacity(canGenerate ? 1 : 0.45)

            Text(copy.aiDraftHint)
                .font(SpyTheme.micro)
                .tracking(0.08)
                .foregroundStyle(SpyTheme.dim)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(SpyTheme.dark)
        .overlay(Rectangle().stroke(SpyTheme.stroke))
    }

    private var wordsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(copy.wordsLabel)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker()
                Spacer()
                Text(copy.wordsInputHint)
                    .font(SpyTheme.micro)
                    .tracking(0.10)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.58, alignment: .trailing)
            }

            TextEditor(text: $wordsText)
                .focused($focusedField, equals: .words)
                .font(SpyTheme.mono)
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 190)
                .padding(10)
                .background(SpyTheme.panelDeep)
                .overlay(Rectangle().stroke(focusedField == .words ? SpyTheme.red.opacity(0.55) : SpyTheme.stroke))

            if words.isEmpty {
                Text(copy.emptyWordsHint)
                    .font(SpyTheme.micro)
                    .tracking(0.22)
                    .foregroundStyle(SpyTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowWords(words: Array(words.prefix(18)))
            }
        }
    }

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            if isSaving {
                SpyLoadingLabel(title: copy.saveAction(isEditing: route.pack != nil), accent: .white)
            } else {
                Label(copy.saveAction(isEditing: route.pack != nil), systemImage: "checkmark.seal.fill")
            }
        }
        .buttonStyle(SpyButtonStyle(variant: .red))
        .disabled(!canSave)
        .opacity(canSave ? 1 : 0.42)
    }

    private var cleanName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanCategory: String {
        category.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var words: [String] {
        Self.parseWords(wordsText)
    }

    private var aiCount: Int {
        Int(aiWordCount.rounded())
    }

    private var cleanAITheme: String {
        aiTheme.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !isSaving && !isGenerating && !cleanName.isEmpty && words.count >= 2
    }

    private var canGenerate: Bool {
        !isSaving && !isGenerating && !cleanAITheme.isEmpty
    }

    private func textFieldSection(label: String, placeholder: String, text: Binding<String>, focus: Field) -> some View {
        SpyInput(
            label: label,
            placeholder: placeholder,
            text: text,
            icon: focus == .name ? "tag.fill" : "folder.fill",
            isFocused: focusedField == focus,
            autocapitalization: .words
        )
    }

    private func editorStat(_ title: String, _ value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(SpyTheme.micro)
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyKicker()
            Text(value)
                .font(.system(size: 18, weight: .black, design: .monospaced))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(SpyTheme.panelDeep)
        .overlay(Rectangle().stroke(SpyTheme.stroke))
    }

    private func save() async {
        guard canSave else {
            setStatus(copy.packNeedsNameAndWords, kind: .error)
            HapticManager.shared.fire(.notification(.warning))
            return
        }

        if appState.shouldUsePreviewData {
            setStatus(copy.previewSaved, kind: .success)
            HapticManager.shared.fire(.milestone)
            dismiss()
            return
        }

        guard let email = appState.user?.email else {
            setStatus(copy.signInRequired, kind: .error)
            HapticManager.shared.fire(.notification(.warning))
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            if let pack = route.pack {
                _ = try await appState.client.updateWordPack(
                    pack: pack,
                    name: cleanName,
                    category: cleanCategory,
                    words: words
                )
            } else {
                _ = try await appState.client.createWordPack(
                    name: cleanName,
                    category: cleanCategory,
                    words: words,
                    ownerEmail: email
                )
            }
            HapticManager.shared.fire(.milestone)
            dismiss()
        } catch {
            setStatus(error.localizedDescription.uppercased(), kind: .error)
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func generateWithAI() async {
        guard canGenerate else {
            setStatus(copy.enterThemeFirst, kind: .error)
            return
        }

        isGenerating = true
        clearStatus()
        defer { isGenerating = false }

        if appState.shouldUsePreviewData {
            let generated = previewGeneratedWordPack(theme: cleanAITheme, count: aiCount)
            captureAIAllowance(from: generated)
            apply(generated)
            setStatus(copy.aiReadyMessage(words: generated.words.count, used: nil, limit: nil), kind: .success)
            HapticManager.shared.fire(.milestone)
            return
        }

        do {
            let generated = try await appState.client.generateWordPack(theme: cleanAITheme, count: aiCount)
            captureAIAllowance(from: generated)
            apply(generated)
            setStatus(
                copy.aiReadyMessage(
                    words: generated.words.count,
                    used: nil,
                    limit: nil
                ),
                kind: .success
            )
            HapticManager.shared.fire(.milestone)
        } catch {
            setStatus(error.localizedDescription.uppercased(), kind: .error)
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func apply(_ generated: GeneratedWordPack) {
        let generatedName = generated.name?.nilIfBlank ?? cleanAITheme
        name = cleanName.isEmpty ? generatedName : name
        category = generated.category.nilIfBlank ?? generatedName
        wordsText = generated.words.joined(separator: "\n")
        focusedField = .words
    }

    private func captureAIAllowance(from generated: GeneratedWordPack) {
        appState.recordAIUsage(
            used: generated.aiGenerationsToday,
            remaining: generated.aiRemaining
        )
    }

    private func localized(en: String, ru: String, es: String) -> String {
        switch appState.language {
        case .ru: ru
        case .es: es
        default: en
        }
    }

    private func setStatus(_ message: String, kind: EditorStatusKind) {
        let toastKind: AppToastKind = switch kind {
        case .success: .success
        case .error: .error
        }
        appState.showToast(
            message,
            kind: toastKind
        )
    }

    private func clearStatus() {}

    private func previewGeneratedWordPack(theme: String, count: Int) -> GeneratedWordPack {
        let seeds = previewWordSeeds
        let words = (0..<count).map { index in
            seeds[index % seeds.count]
        }

        return GeneratedWordPack(
            name: "\(theme) Kit",
            category: theme,
            words: words,
            aiLimit: nil,
            aiGenerationsToday: nil,
            aiRemaining: nil
        )
    }

    private var previewWordSeeds: [String] {
        switch appState.language {
        case .en:
            ["Cipher", "Embassy", "Courier", "Vault", "Harbor", "Signal", "Rooftop", "Decoy", "Passport", "Briefing", "Disguise", "Checkpoint"]
        case .es:
            ["Clave", "Embajada", "Correo", "Boveda", "Puerto", "Senal", "Azotea", "Senuelo", "Pasaporte", "Informe", "Disfraz", "Control"]
        case .ru:
            ["Шифр", "Посольство", "Курьер", "Сейф", "Порт", "Сигнал", "Крыша", "Приманка", "Паспорт", "Брифинг", "Маскировка", "Пост"]
        }
    }

    private static func parseWords(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .compactMap { rawWord in
                let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty else { return nil }
                let key = word.lowercased()
                guard !seen.contains(key) else { return nil }
                seen.insert(key)
                return word
            }
    }
}

private struct FlowWords: View {
    let words: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(words, id: \.self) { word in
                Text(word.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .default))
                    .tracking(0.02)
                    .foregroundStyle(.white.opacity(0.76))
                    .spyFitted(scale: 0.66, alignment: .center)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(SpyTheme.panelDeep)
                    .overlay(Rectangle().stroke(SpyTheme.stroke))
            }
        }
    }
}
