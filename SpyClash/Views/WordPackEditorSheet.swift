import SwiftUI
import UIKit

struct WordPackEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let route: WordPackEditorRoute
    let onSaved: (WordPack) -> Void

    @State private var draft: WordPackDraft
    @State private var step: Step
    @State private var method: WordPackCreationMethod?
    @State private var aiTheme = ""
    @State private var aiWordCount = 12
    @State private var isGenerating = false
    @State private var isSaving = false
    @State private var validationAttempted = false
    @State private var message: EditorMessage?
    @State private var showDiscardConfirmation = false
    @State private var showReplaceConfirmation = false
    @State private var pendingAIRequest: WordPackAIGenerationRequest?
    @State private var lastSuccessfulAISignature: WordPackAIGenerationSignature?
    @State private var activeGenerationID: UUID?
    @State private var activeSaveID: UUID?
    @State private var operationTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private let initialDraft: WordPackDraft

    private enum Step: Equatable {
        case chooseMethod
        case aiSetup
        case editor
    }

    private enum Field: Hashable {
        case aiTheme
        case name
        case category
        case words
    }

    private struct EditorMessage: Equatable {
        enum Kind: Equatable {
            case success
            case error
        }

        let text: String
        let kind: Kind
    }

    private var copy: WordPackEditorCopy {
        appState.language.wordPacks.editor
    }

    private var flowCopy: WordPackEditorFlowCopy {
        appState.language.wordPackEditorFlow
    }

    init(route: WordPackEditorRoute, onSaved: @escaping (WordPack) -> Void) {
        self.route = route
        self.onSaved = onSaved

        let initialDraft = route.pack.map(WordPackDraft.init(pack:)) ?? WordPackDraft()
        self.initialDraft = initialDraft
        _draft = State(initialValue: initialDraft)
        _step = State(initialValue: route.pack == nil ? .chooseMethod : .editor)
        _method = State(initialValue: route.pack == nil ? nil : .manual)
        _aiWordCount = State(
            initialValue: max(12, min(100, route.pack?.words?.count ?? 12))
        )
    }

    var body: some View {
        ZStack {
            SpyBackground()

            VStack(spacing: 0) {
                sheetHeader

                ScrollView(showsIndicators: false) {
                    screenContent
                        .padding(.horizontal, 18)
                        .padding(.top, 18)
                        .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)

                footer
            }
            .disabled(showDiscardConfirmation || showReplaceConfirmation)
            .accessibilityHidden(showDiscardConfirmation || showReplaceConfirmation)

            if showDiscardConfirmation {
                SpyConfirmDialog(
                    title: flowCopy.discardTitle,
                    message: flowCopy.discardMessage,
                    confirmTitle: flowCopy.discardAction,
                    cancelTitle: flowCopy.keepEditing,
                    isBusy: false
                ) {
                    showDiscardConfirmation = false
                    dismiss()
                } onCancel: {
                    showDiscardConfirmation = false
                }
                .zIndex(20)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
            }

            if showReplaceConfirmation {
                SpyConfirmDialog(
                    title: flowCopy.replaceDraftTitle,
                    message: flowCopy.replaceDraftMessage,
                    confirmTitle: flowCopy.replaceDraftAction,
                    cancelTitle: flowCopy.keepEditing,
                    isBusy: false
                ) {
                    showReplaceConfirmation = false
                    startGeneration()
                } onCancel: {
                    showReplaceConfirmation = false
                }
                .zIndex(20)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
            }
        }
        .interactiveDismissDisabled(isBusy || hasUnsavedChanges)
        .animation(.smooth(duration: 0.2), value: step)
        .animation(.smooth(duration: 0.2), value: showDiscardConfirmation)
        .animation(.smooth(duration: 0.2), value: showReplaceConfirmation)
        .onDisappear {
            operationTask?.cancel()
            operationTask = nil
            activeGenerationID = nil
            activeSaveID = nil
        }
    }

    private var sheetHeader: some View {
        HStack(spacing: 10) {
            if showsBackButton {
                headerButton(
                    systemName: "chevron.left",
                    accessibilityLabel: flowCopy.back,
                    identifier: "wordPacks.editor.back"
                ) {
                    goBack()
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(headerEyebrow)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.10)
                    .foregroundStyle(SpyTheme.red)
                    .lineLimit(1)

                Text(headerTitle)
                    .font(.system(size: 22, weight: .black))
                    .tracking(0.03)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.68)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            headerButton(
                systemName: "xmark",
                accessibilityLabel: flowCopy.close,
                identifier: "wordPacks.editor.close"
            ) {
                attemptClose()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(SpyTheme.black)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SpyTheme.stroke)
                .frame(height: 1)
        }
    }

    private func headerButton(
        systemName: String,
        accessibilityLabel: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(SpyTheme.red)
                .frame(width: 44, height: 44)
                .background(SpyTheme.panel)
                .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.stroke, lineWidth: 1))
                .clipShape(CutCornerShape(cut: 8))
                .accessibilityHidden(true)
        }
        .buttonStyle(SpyWebPressStyle())
        .disabled(isBusy)
        .opacity(isBusy ? 0.42 : 1)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var screenContent: some View {
        switch step {
        case .chooseMethod:
            methodChoiceContent
        case .aiSetup:
            aiSetupContent
        case .editor:
            editorContent
        }
    }

    private var methodChoiceContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            introBlock(title: flowCopy.chooseTitle, body: flowCopy.chooseBody)

            creationMethodCard(
                method: .ai,
                title: flowCopy.aiMethodTitle,
                body: flowCopy.aiMethodBody,
                systemImage: "sparkles",
                accent: SpyTheme.red
            )

            creationMethodCard(
                method: .manual,
                title: flowCopy.manualMethodTitle,
                body: flowCopy.manualMethodBody,
                systemImage: "text.badge.plus",
                accent: SpyTheme.green
            )
        }
    }

    private func creationMethodCard(
        method: WordPackCreationMethod,
        title: String,
        body: String,
        systemImage: String,
        accent: Color
    ) -> some View {
        Button {
            choose(method)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .black))
                    .foregroundStyle(accent)
                    .frame(width: 48, height: 48)
                    .background(accent.opacity(0.09))
                    .overlay(Rectangle().stroke(accent.opacity(0.45)))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 16, weight: .black))
                        .tracking(0.04)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)

                    Text(body)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SpyTheme.muted)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
            .background(SpyTheme.panel)
            .overlay(CutCornerShape(cut: 12).stroke(accent.opacity(0.5), lineWidth: 1))
            .clipShape(CutCornerShape(cut: 12))
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.98))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wordPacks.editor.method.\(method.rawValue)")
    }

    private var aiSetupContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            introBlock(title: flowCopy.aiSetupTitle, body: flowCopy.aiSetupBody)

            SpyPanel {
                VStack(alignment: .leading, spacing: 18) {
                    editorTextField(
                        label: flowCopy.aiThemeLabel,
                        placeholder: copy.themePlaceholder,
                        text: aiThemeBinding,
                        icon: "sparkles",
                        field: .aiTheme,
                        identifier: "wordPacks.editor.theme"
                    )

                    AIThemeSuggestionStrip(
                        language: appState.language,
                        selectedTheme: aiTheme,
                        accessibilityIdentifier: "wordPacks.aiThemeSuggestions",
                        layout: .grid,
                        suggestionLimit: 4
                    ) { suggestion in
                        aiTheme = WordPackDraftNormalizer.limitedFieldInput(suggestion)
                        generationInputChanged()
                    }
                    .disabled(isGenerating)

                    wordCountSelector

                    if let message {
                        statusBanner(message)
                    }
                }
            }
        }
    }

    private var wordCountSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(copy.wordsToGenerate)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.08)
                    .foregroundStyle(SpyTheme.muted)

                Spacer()

                Text("\(aiWordCount)")
                    .font(SpyTheme.brandFont(size: 28))
                    .foregroundStyle(SpyTheme.red)
            }

            HStack(spacing: 10) {
                countButton(
                    systemName: "minus",
                    accessibilityLabel: flowCopy.decreaseCount,
                    isEnabled: aiWordCount > 5
                ) {
                    aiWordCount = max(5, aiWordCount - 1)
                    generationInputChanged()
                }

                Text("\(aiWordCount)")
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(SpyTheme.panelDeep)
                    .overlay(Rectangle().stroke(SpyTheme.stroke))
                    .accessibilityLabel("\(copy.wordsToGenerate): \(aiWordCount)")

                countButton(
                    systemName: "plus",
                    accessibilityLabel: flowCopy.increaseCount,
                    isEnabled: aiWordCount < 100
                ) {
                    aiWordCount = min(100, aiWordCount + 1)
                    generationInputChanged()
                }
            }

            HStack(spacing: 8) {
                ForEach([12, 24, 40], id: \.self) { preset in
                    Button {
                        aiWordCount = preset
                        generationInputChanged()
                    } label: {
                        Text("\(preset)")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundStyle(aiWordCount == preset ? .white : SpyTheme.muted)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(aiWordCount == preset ? SpyTheme.red.opacity(0.16) : SpyTheme.panelDeep)
                            .overlay(
                                Rectangle().stroke(
                                    aiWordCount == preset ? SpyTheme.red : SpyTheme.stroke,
                                    lineWidth: 1
                                )
                            )
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .disabled(isGenerating)
                    .accessibilityLabel("\(preset) \(copy.wordsUnit)")
                    .accessibilityAddTraits(aiWordCount == preset ? .isSelected : [])
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func countButton(
        systemName: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(SpyTheme.red)
                .frame(width: 48, height: 44)
                .background(SpyTheme.panelDeep)
                .overlay(Rectangle().stroke(SpyTheme.red.opacity(0.5)))
                .accessibilityHidden(true)
        }
        .buttonStyle(SpyWebPressStyle())
        .disabled(isGenerating || !isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            introBlock(title: editorIntroTitle, body: editorIntroBody)

            if let message {
                statusBanner(message)
            }

            if method == .ai, route.pack == nil {
                Button {
                    focusedField = nil
                    message = nil
                    step = .aiSetup
                } label: {
                    Label(flowCopy.generateAgain, systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(SpyButtonStyle(variant: .outline))
                .disabled(isBusy)
                .accessibilityIdentifier("wordPacks.editor.generateAgain")
            }

            SpyPanel {
                VStack(alignment: .leading, spacing: 18) {
                    editorTextField(
                        label: copy.packNameLabel,
                        placeholder: copy.packNamePlaceholder,
                        text: draftBinding(\.name),
                        icon: "tag.fill",
                        field: .name,
                        identifier: "wordPacks.editor.name"
                    )

                    if validationAttempted && draft.normalizedName.isEmpty {
                        validationMessage(flowCopy.nameRequired)
                    }

                    editorTextField(
                        label: copy.categoryLabel,
                        placeholder: copy.categoryPlaceholder,
                        text: draftBinding(\.category),
                        icon: "folder.fill",
                        field: .category,
                        identifier: "wordPacks.editor.category"
                    )

                    wordsSection
                }
            }
        }
    }

    private func introBlock(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 18, weight: .black))
                .tracking(0.04)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Text(body)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SpyTheme.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func editorTextField(
        label: String,
        placeholder: String,
        text: Binding<String>,
        icon: String,
        field: Field,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(0.08)
                .foregroundStyle(SpyTheme.muted)

            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(focusedField == field ? SpyTheme.red : SpyTheme.dim)
                    .accessibilityHidden(true)

                TextField("", text: text, prompt: Text(placeholder).foregroundStyle(SpyTheme.dim))
                    .font(SpyTheme.mono)
                    .foregroundStyle(.white)
                    .focused($focusedField, equals: field)
                    .textInputAutocapitalization(field == .aiTheme ? .sentences : .words)
                    .autocorrectionDisabled(false)
                    .submitLabel(field == .name ? .next : .done)
                    .onSubmit {
                        switch field {
                        case .name:
                            focusedField = .category
                        case .category:
                            focusedField = .words
                        default:
                            focusedField = nil
                        }
                    }
                    .accessibilityLabel(accessibleLabel(label))
                    .accessibilityIdentifier(identifier)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(SpyTheme.panelDeep, in: CutCornerShape(cut: 9))
            .overlay(
                CutCornerShape(cut: 9)
                    .stroke(focusedField == field ? SpyTheme.red : SpyTheme.inputBorder, lineWidth: 1)
            )
        }
        .disabled(isBusy)
    }

    private var wordsSection: some View {
        let analysis = draft.wordAnalysis

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(copy.wordsLabel)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.08)
                    .foregroundStyle(SpyTheme.muted)

                Spacer()

                Text("\(analysis.words.count) \(flowCopy.uniqueWords)")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(analysis.words.count >= 2 ? SpyTheme.green : SpyTheme.red)
            }

            TextEditor(text: $draft.wordsText)
                .focused($focusedField, equals: .words)
                .font(SpyTheme.mono)
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 190)
                .padding(10)
                .background(SpyTheme.panelDeep)
                .overlay(
                    Rectangle().stroke(
                        focusedField == .words ? SpyTheme.red.opacity(0.75) : SpyTheme.stroke
                    )
                )
                .accessibilityLabel(accessibleLabel(copy.wordsLabel))
                .accessibilityHint(copy.wordsInputHint)
                .accessibilityIdentifier("wordPacks.editor.words")
                .disabled(isBusy)

            Text(copy.wordsInputHint)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(SpyTheme.muted)

            if validationAttempted && analysis.words.count < 2 {
                validationMessage(flowCopy.twoWordsRequired)
            } else if analysis.words.isEmpty {
                Text(copy.emptyWordsHint)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SpyTheme.muted)
            }

            if analysis.duplicateCount > 0 {
                analysisMessage(
                    flowCopy.duplicatesRemoved(analysis.duplicateCount),
                    systemName: "checkmark.circle.fill",
                    accent: SpyTheme.green
                )
            }

            if analysis.shortenedCount > 0 {
                analysisMessage(
                    flowCopy.shortenedEntries(analysis.shortenedCount),
                    systemName: "scissors",
                    accent: SpyTheme.amber
                )
            }

            if analysis.words.count > WordPackDraftNormalizer.gameplayWordLimit {
                analysisMessage(
                    flowCopy.gameLimitHint,
                    systemName: "info.circle.fill",
                    accent: SpyTheme.amber
                )
            }
        }
    }

    private func validationMessage(_ text: String) -> some View {
        analysisMessage(text, systemName: "exclamationmark.triangle.fill", accent: SpyTheme.red)
    }

    private func analysisMessage(_ text: String, systemName: String, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(accent)
                .accessibilityHidden(true)

            Text(text)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(SpyTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func statusBanner(_ message: EditorMessage) -> some View {
        let accent = message.kind == .success ? SpyTheme.green : SpyTheme.red
        let icon = message.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(accent)
                .accessibilityHidden(true)

            Text(message.text)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.09))
        .overlay(Rectangle().stroke(accent.opacity(0.5)))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var footer: some View {
        switch step {
        case .chooseMethod:
            EmptyView()
        case .aiSetup:
            actionFooter(
                title: generationActionTitle,
                systemImage: "sparkles",
                isLoading: isGenerating,
                identifier: "wordPacks.editor.generate"
            ) {
                generationTapped()
            }
        case .editor:
            actionFooter(
                title: copy.saveAction(isEditing: route.pack != nil),
                systemImage: "checkmark.seal.fill",
                isLoading: isSaving,
                identifier: "wordPacks.editor.save"
            ) {
                saveTapped()
            }
        }
    }

    private func actionFooter(
        title: String,
        systemImage: String,
        isLoading: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                if isLoading {
                    SpyLoadingLabel(title: title, accent: .white)
                } else {
                    Label(title, systemImage: systemImage)
                }
            }
            .buttonStyle(SpyButtonStyle(variant: .red))
            .disabled(isBusy)
            .opacity(isBusy && !isLoading ? 0.42 : 1)
            .accessibilityIdentifier(identifier)

            if step == .aiSetup {
                Text(copy.aiDraftHint)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SpyTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(SpyTheme.black)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(SpyTheme.stroke)
                .frame(height: 1)
        }
    }

    private var headerTitle: String {
        if route.pack != nil {
            return copy.editTitle
        }

        return switch step {
        case .chooseMethod:
            flowCopy.addTitle
        case .aiSetup:
            flowCopy.aiSetupTitle
        case .editor:
            method == .ai ? flowCopy.aiReviewTitle : copy.newTitle
        }
    }

    private var headerEyebrow: String {
        if route.pack != nil {
            return copy.updateMode
        }

        return switch step {
        case .chooseMethod:
            copy.createMode
        case .aiSetup:
            flowCopy.stepOneOfTwo
        case .editor:
            method == .ai ? flowCopy.stepTwoOfTwo : copy.createMode
        }
    }

    private var editorIntroTitle: String {
        if route.pack != nil {
            return copy.editTitle
        }
        return method == .ai ? flowCopy.aiReviewTitle : copy.newTitle
    }

    private var editorIntroBody: String {
        if route.pack != nil {
            return flowCopy.editBody
        }
        return method == .ai ? flowCopy.aiReviewBody : flowCopy.manualCreateBody
    }

    private var showsBackButton: Bool {
        route.pack == nil && step != .chooseMethod
    }

    private var cleanAITheme: String {
        WordPackDraftNormalizer.normalizedField(aiTheme)
    }

    private var currentAISignature: WordPackAIGenerationSignature {
        WordPackAIGenerationSignature(theme: cleanAITheme, count: aiWordCount)
    }

    private var generationActionTitle: String {
        if isGenerating {
            return flowCopy.generating
        }
        if pendingAIRequest?.signature == currentAISignature,
           message?.kind == .error {
            return flowCopy.retryGeneration
        }
        return copy.generateWords
    }

    private var isBusy: Bool {
        isGenerating || isSaving
    }

    private var hasUnsavedChanges: Bool {
        if route.pack != nil {
            return draft != initialDraft
        }
        return draft.hasContent || !cleanAITheme.isEmpty
    }

    private var aiThemeBinding: Binding<String> {
        Binding(
            get: { aiTheme },
            set: { value in
                aiTheme = WordPackDraftNormalizer.limitedFieldInput(value)
                generationInputChanged()
            }
        )
    }

    private func draftBinding(_ keyPath: WritableKeyPath<WordPackDraft, String>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { value in
                draft[keyPath: keyPath] = WordPackDraftNormalizer.limitedFieldInput(value)
                message = nil
            }
        )
    }

    private func accessibleLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "//", with: "")
            .replacingOccurrences(of: "·", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func choose(_ selectedMethod: WordPackCreationMethod) {
        method = selectedMethod
        message = nil
        validationAttempted = false

        switch selectedMethod {
        case .ai:
            step = .aiSetup
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                focusedField = .aiTheme
            }
        case .manual:
            step = .editor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                focusedField = draft.normalizedName.isEmpty ? .name : .words
            }
        }
        HapticManager.shared.fire(.tabSelection)
    }

    private func goBack() {
        guard !isBusy else { return }
        focusedField = nil
        message = nil

        switch step {
        case .chooseMethod:
            break
        case .aiSetup:
            step = .chooseMethod
        case .editor:
            step = method == .ai ? .aiSetup : .chooseMethod
        }
    }

    private func attemptClose() {
        guard !isBusy else { return }
        focusedField = nil
        if hasUnsavedChanges {
            showDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func generationInputChanged() {
        guard !isGenerating else { return }
        if pendingAIRequest?.signature != currentAISignature {
            message = nil
        }
    }

    private func generationTapped() {
        focusedField = nil
        guard !cleanAITheme.isEmpty else {
            message = EditorMessage(text: copy.enterThemeFirst, kind: .error)
            focusedField = .aiTheme
            HapticManager.shared.fire(.notification(.warning))
            announce(copy.enterThemeFirst)
            return
        }

        if draft.hasContent {
            showReplaceConfirmation = true
        } else {
            startGeneration()
        }
    }

    private func startGeneration() {
        guard !isBusy, !cleanAITheme.isEmpty else { return }

        let signature = currentAISignature
        let request: WordPackAIGenerationRequest
        if let pendingAIRequest, pendingAIRequest.signature == signature {
            request = pendingAIRequest
        } else {
            request = WordPackAIGenerationRequest(id: UUID(), signature: signature)
            pendingAIRequest = request
        }

        activeGenerationID = request.id
        isGenerating = true
        message = nil
        operationTask?.cancel()
        operationTask = Task {
            await performGeneration(request)
        }
    }

    private func performGeneration(_ request: WordPackAIGenerationRequest) async {
        defer {
            if activeGenerationID == request.id {
                isGenerating = false
                activeGenerationID = nil
                operationTask = nil
            }
        }

        do {
            let generated: GeneratedWordPack
            if appState.shouldUsePreviewData {
                try await Task.sleep(for: .milliseconds(350))
                generated = previewGeneratedWordPack(
                    theme: request.signature.theme,
                    count: request.signature.count
                )
            } else {
                generated = try await appState.client.generateWordPack(
                    theme: request.signature.theme,
                    count: request.signature.count,
                    requestID: request.id,
                    preferFresh: lastSuccessfulAISignature == request.signature
                )
            }

            guard !Task.isCancelled,
                  activeGenerationID == request.id,
                  currentAISignature == request.signature else {
                return
            }

            draft.applyGenerated(generated, fallbackName: request.signature.theme)
            pendingAIRequest = nil
            lastSuccessfulAISignature = request.signature
            validationAttempted = false
            message = EditorMessage(
                text: copy.aiReadyMessage(
                    words: generated.words.count,
                    used: generated.aiGenerationsToday,
                    limit: generated.aiLimit
                ),
                kind: .success
            )
            announce(message?.text)
            step = .editor
            focusedField = nil
            HapticManager.shared.fire(.milestone)
        } catch is CancellationError {
            return
        } catch {
            guard activeGenerationID == request.id else { return }
            message = EditorMessage(
                text: error.localizedDescription.uppercased(),
                kind: .error
            )
            HapticManager.shared.fire(.notification(.error))
            announce(message?.text)
        }
    }

    private func saveTapped() {
        validationAttempted = true
        message = nil

        guard draft.isValid else {
            let validationAnnouncement: String
            if draft.normalizedName.isEmpty {
                focusedField = .name
                validationAnnouncement = flowCopy.nameRequired
            } else {
                focusedField = .words
                validationAnnouncement = flowCopy.twoWordsRequired
            }
            HapticManager.shared.fire(.notification(.warning))
            announce(validationAnnouncement)
            return
        }

        guard !isBusy else { return }
        focusedField = nil

        let saveID = UUID()
        let draftToSave = draft
        activeSaveID = saveID
        isSaving = true
        operationTask?.cancel()
        operationTask = Task {
            await performSave(saveID: saveID, draft: draftToSave)
        }
    }

    private func performSave(saveID: UUID, draft draftToSave: WordPackDraft) async {
        defer {
            if activeSaveID == saveID {
                isSaving = false
                activeSaveID = nil
                operationTask = nil
            }
        }

        do {
            let savedPack: WordPack
            if appState.shouldUsePreviewData {
                try await Task.sleep(for: .milliseconds(250))
                savedPack = WordPack(
                    id: route.pack?.id ?? "preview-\(UUID().uuidString)",
                    name: draftToSave.normalizedName,
                    category: draftToSave.normalizedCategory.nilIfBlank ?? draftToSave.normalizedName,
                    words: draftToSave.wordAnalysis.words,
                    ownerEmail: appState.user?.email,
                    isPublic: false
                )
            } else {
                guard let email = appState.user?.email else {
                    throw Base44Error(message: copy.signInRequired, statusCode: 401)
                }

                if let pack = route.pack {
                    savedPack = try await appState.client.updateWordPack(
                        pack: pack,
                        name: draftToSave.normalizedName,
                        category: draftToSave.normalizedCategory,
                        words: draftToSave.wordAnalysis.words
                    )
                } else {
                    savedPack = try await appState.client.createWordPack(
                        name: draftToSave.normalizedName,
                        category: draftToSave.normalizedCategory,
                        words: draftToSave.wordAnalysis.words,
                        ownerEmail: email
                    )
                }
            }

            guard !Task.isCancelled, activeSaveID == saveID else { return }
            announce(flowCopy.savedMessage)
            onSaved(savedPack)
            appState.markWordPacksChanged()
            HapticManager.shared.fire(.milestone)
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            guard activeSaveID == saveID else { return }
            message = EditorMessage(
                text: error.localizedDescription.uppercased(),
                kind: .error
            )
            HapticManager.shared.fire(.notification(.error))
            announce(message?.text)
        }
    }

    private func announce(_ text: String?) {
        guard let text = text?.nilIfBlank else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func previewGeneratedWordPack(theme: String, count: Int) -> GeneratedWordPack {
        let seeds = previewWordSeeds
        let words = (0..<count).map { index in
            let seed = seeds[index % seeds.count]
            let cycle = index / seeds.count
            return cycle == 0 ? seed : "\(seed) \(cycle + 1)"
        }

        return GeneratedWordPack(
            name: theme,
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
            ["Clave", "Embajada", "Correo", "Bóveda", "Puerto", "Señal", "Azotea", "Señuelo", "Pasaporte", "Informe", "Disfraz", "Control"]
        case .ru:
            ["Шифр", "Посольство", "Курьер", "Сейф", "Порт", "Сигнал", "Крыша", "Приманка", "Паспорт", "Брифинг", "Маскировка", "Пост"]
        case .uk:
            ["Шифр", "Посольство", "Курʼєр", "Сховище", "Порт", "Сигнал", "Дах", "Приманка", "Паспорт", "Брифінг", "Маскування", "Пост"]
        }
    }
}
