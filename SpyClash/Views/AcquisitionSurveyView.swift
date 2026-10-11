import SwiftUI

private struct AcquisitionSurveyPresentation: Identifiable {
    let id: String
}

/// Mounted only on Home. Results, rooms, QR, tutorials and incoming routes
/// keep priority over this optional, once-per-account question.
struct AcquisitionSurveyPresentationModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    let isHomeRoot: Bool
    @State private var presentation: AcquisitionSurveyPresentation?

    private var isSafeToPresent: Bool {
        isHomeRoot && scenePhase == .active
            && appState.isAcquisitionSurveyHomeAvailable
    }

    private var presentationKey: String {
        "\(appState.user?.id ?? ""):\(isSafeToPresent):\(appState.canPresentAcquisitionSurvey):\(appState.acquisitionSurveyRevision)"
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $presentation) { item in
                AcquisitionSurveyView(userID: item.id)
                    .spyGlobalToastLayer()
                    .spyInterfaceScale()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
            }
            .task(id: presentationKey) {
                guard isSafeToPresent, let userID = appState.user?.id else { return }
                appState.queuePendingAcquisitionSurveySync()
                guard presentation == nil, appState.canPresentAcquisitionSurvey else { return }
                do {
                    try await Task.sleep(for: .milliseconds(800))
                } catch { return }
                guard !Task.isCancelled, isSafeToPresent,
                      appState.claimAcquisitionSurveyPresentation(for: userID) else { return }
                presentation = AcquisitionSurveyPresentation(id: userID)
            }
            .onChange(of: isSafeToPresent) { _, isSafe in
                if !isSafe { presentation = nil }
            }
            .onChange(of: appState.user?.id) { _, _ in
                presentation = nil
            }
    }
}

private struct AcquisitionSurveyView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let userID: String
    @State private var selectedSource: OnboardingAcquisitionSource?

    private let sources: [OnboardingAcquisitionSource] = [
        .friendsOrFamily, .socialMedia, .appStoreSearch, .webSearch, .chatGPT, .other
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(SpyTheme.red)
                    .accessibilityHidden(true)

                Text(localized(
                    en: "Where did you first hear about SpyClash?",
                    es: "¿Dónde conociste SpyClash por primera vez?",
                    ru: "Где вы впервые узнали о SpyClash?",
                    uk: "Де ви вперше дізналися про SpyClash?"
                ))
                .font(.system(.title2, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    ForEach(sources) { source in
                        Button {
                            selectedSource = source
                            HapticManager.shared.fire(.tabSelection)
                        } label: {
                            HStack(spacing: 12) {
                                Text(label(for: source))
                                    .font(.system(.body, design: .rounded, weight: .medium))
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Image(systemName: selectedSource == source ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedSource == source ? SpyTheme.red : SpyTheme.dim)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Color.white.opacity(selectedSource == source ? 0.10 : 0.045),
                                        in: RoundedRectangle(cornerRadius: 16))
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(SpyWebPressStyle())
                        .accessibilityIdentifier("spyclash.acquisition.source.\(source.rawValue)")
                        .accessibilityAddTraits(selectedSource == source ? .isSelected : [])
                    }
                }

                VStack(spacing: 12) {
                    Button {
                        guard let selectedSource else { return }
                        appState.answerAcquisitionSurvey(selectedSource, userID: userID)
                        dismiss()
                    } label: {
                        Text(localized(en: "Done", es: "Listo", ru: "Готово", uk: "Готово"))
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .font(.system(.headline, design: .rounded))
                            .background(SpyTheme.red, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .disabled(selectedSource == nil)
                    .opacity(selectedSource == nil ? 0.4 : 1)
                    .accessibilityIdentifier("spyclash.acquisition.submit")

                    Button {
                        dismiss()
                    } label: {
                        Text(localized(en: "Skip", es: "Omitir", ru: "Пропустить", uk: "Пропустити"))
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(SpyTheme.bodyText)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .accessibilityIdentifier("spyclash.acquisition.skip")
                }
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 28 : 36)
            .frame(maxWidth: .infinity)
        }
        .background(SpyTheme.black)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("spyclash.acquisition.survey")
    }

    private func label(for source: OnboardingAcquisitionSource) -> String {
        switch source {
        case .friendsOrFamily:
            localized(en: "Friends or family", es: "Amigos o familia", ru: "Друзья или близкие", uk: "Друзі або близькі")
        case .socialMedia:
            localized(en: "Social media", es: "Redes sociales", ru: "Социальные сети", uk: "Соціальні мережі")
        case .appStoreSearch:
            localized(en: "App Store", es: "App Store", ru: "App Store", uk: "App Store")
        case .webSearch:
            localized(en: "Web search", es: "Búsqueda en internet", ru: "Поиск в интернете", uk: "Пошук в інтернеті")
        case .chatGPT:
            "ChatGPT"
        case .other:
            localized(en: "Somewhere else", es: "En otro lugar", ru: "Другое", uk: "Інше")
        }
    }

    private func localized(en: String, es: String, ru: String, uk: String) -> String {
        switch appState.language {
        case .en: en
        case .es: es
        case .ru: ru
        case .uk: uk
        }
    }
}
