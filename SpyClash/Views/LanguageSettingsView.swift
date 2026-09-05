import SwiftUI

/// Uses the same account/local language operation previously exposed in Profile.
struct LanguageSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(AppLanguage.allCases) { language in
                    languageChip(language)
                }
            }
            if isSaving {
                SpySpinner(size: 16, accent: SpyTheme.red)
            }
        }
    }

    private func languageChip(_ language: AppLanguage) -> some View {
        let selected = appState.language == language
        return Button { selectLanguage(language) } label: {
            VStack(spacing: 4) {
                Text(language.shortCode)
                    .font(.system(size: 13, weight: .black))
                Text(language.title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .spyFitted(lines: 2, scale: 0.66, alignment: .center)
            }
            .foregroundStyle(selected ? .white : SpyTheme.muted)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(selected ? SpyTheme.red : SpyTheme.dark)
            .overlay(Rectangle().stroke(selected ? Color.clear : SpyTheme.strokeStrong))
        }
        .buttonStyle(SpyWebPressStyle())
        .disabled(isSaving)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.language.\(language.rawValue)")
    }

    private func selectLanguage(_ language: AppLanguage) {
        guard !isSaving, appState.language != language else { return }
        HapticManager.shared.fire(.tabSelection)
#if DEBUG
        // UI fixtures must never update a real account or normal language storage.
        if appState.isUIPreviewMode {
            appState.language = language
            return
        }
#endif
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await appState.setLanguage(language)
                appState.showToast(language.languageSavedMessage, kind: .success)
            } catch {
                appState.showToast(language.languageFailedMessage, kind: .error)
                HapticManager.shared.fire(.notification(.warning))
            }
        }
    }
}
