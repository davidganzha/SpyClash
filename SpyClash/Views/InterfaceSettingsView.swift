import SwiftUI

struct InterfaceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Bindable var preferences: InterfacePreferences
    let language: AppLanguage
    @State private var showsResetConfirmation = false
    @AccessibilityFocusState private var resetIsFocused: Bool

    init(language: AppLanguage, preferences: InterfacePreferences = .shared) {
        self.language = language
        self.preferences = preferences
    }

    var body: some View {
        ZStack {
            SpyBackground()

            VStack(spacing: 0) {
                sheetHeader
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        livePreview
                        presetsPanel
                        motionPanel
                        readabilityPanel
                        hapticsPanel
                        resetControls
                    }
                    .frame(maxWidth: SpyLobbyVisualLanguage.maxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
                .accessibilityIdentifier("interface-settings.form")
            }
            .disabled(showsResetConfirmation)
            .accessibilityHidden(showsResetConfirmation)

            if showsResetConfirmation {
                resetConfirmation
                    .accessibilityAddTraits(.isModal)
                    .zIndex(10)
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(showsResetConfirmation)
        .onChange(of: preferences.settings.haptics) { _, mode in
            if mode == .off { HapticManager.shared.stopFeedback() }
        }
        .onChange(of: showsResetConfirmation) { _, isPresented in
            resetIsFocused = isPresented
        }
    }

    private var sheetHeader: some View {
        HStack(spacing: 12) {
            SpyWordmark(fontSize: 24)
                .fixedSize()
            Text("/ " + t("SETTINGS", "НАСТРОЙКИ", "AJUSTES", "НАЛАШТУВАННЯ"))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(SpyTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(SpyTheme.red)
                    .frame(width: 44, height: 44)
                    .background(SpyTheme.black, in: CutCornerShape(cut: 8))
                    .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.strokeStrong, lineWidth: 1))
                    .contentShape(CutCornerShape(cut: 8))
            }
            .buttonStyle(SpyWebPressStyle())
            .accessibilityLabel(t("Close settings", "Закрыть настройки", "Cerrar ajustes", "Закрити налаштування"))
            .accessibilityIdentifier("interface-settings.close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(SpyTheme.black)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SpyTheme.stroke).frame(height: 1)
        }
    }

    private var livePreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("// " + t("PERSONAL CONFIG", "ЛИЧНАЯ КОНФИГУРАЦИЯ", "CONFIGURACIÓN PERSONAL", "ОСОБИСТА КОНФІГУРАЦІЯ"))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Image(systemName: "slider.horizontal.3")
            }
            .foregroundStyle(SpyTheme.red)

            Text(t("INTERFACE", "ИНТЕРФЕЙС", "INTERFAZ", "ІНТЕРФЕЙС"))
                .font(SpyTheme.brandFont(size: 44))
                .tracking(3)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 7) {
                Rectangle().fill(SpyTheme.red).frame(width: 4, height: 4)
                Text(currentModeTitle.uppercased())
                    .foregroundStyle(SpyTheme.bodyText)
                Spacer(minLength: 0)
                Text(t("AUTO-SAVED", "АВТОСОХРАНЕНИЕ", "GUARDADO AUTO.", "АВТОЗБЕРЕЖЕННЯ"))
                    .foregroundStyle(SpyTheme.muted)
            }
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .tracking(0.6)
            .lineLimit(1)
            .minimumScaleFactor(0.65)

            Rectangle().fill(SpyTheme.red.opacity(0.25)).frame(height: 1)

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(t("LIVE PREVIEW", "ЖИВОЙ ПРИМЕР", "VISTA PREVIA", "ЖИВИЙ ПРИКЛАД"))
                        .font(.system(size: 9 * preferences.settings.labelSize.scale, weight: .bold, design: .monospaced))
                        .foregroundStyle(preferences.settings.enhancedContrast ? SpyTheme.bodyText : SpyTheme.muted)
                    Text(t("Changes apply instantly", "Изменения сразу в деле", "Cambios al instante", "Зміни одразу в дії"))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(SpyTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    previewNav("house", title: t("HOME", "ДОМОЙ", "INICIO", "ДОДОМУ"))
                    previewNav("shippingbox", title: t("PACKS", "КОЛОДЫ", "MAZOS", "КОЛОДИ"))
                    previewNav("person.crop.circle", title: t("PROFILE", "ПРОФИЛЬ", "PERFIL", "ПРОФІЛЬ"))
                }
                .frame(width: 128)
            }
            .frame(minHeight: 40)
        }
        .padding(20)
        .background {
            ZStack {
                SpyTheme.black
                if preferences.settings.backgroundEffects {
                    LinearGradient(colors: [SpyTheme.red.opacity(0.13), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                    SpyLaserScanLayer(reduceMotion: preferences.settings.effectiveReduceMotion(system: systemReduceMotion))
                }
            }
            .clipShape(CutCornerShape(cut: 14))
        }
        .overlay(CutCornerShape(cut: 14).stroke(
            LinearGradient(colors: [SpyTheme.red.opacity(0.8), SpyTheme.strokeStrong, SpyTheme.red.opacity(0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .overlay(alignment: .topLeading) { CornerStroke(color: SpyTheme.red).padding(1) }
        .overlay(alignment: .bottomTrailing) { CornerStroke(color: SpyTheme.red).rotationEffect(.degrees(180)).padding(1) }
        .accessibilityIdentifier("interface-settings.preview")
    }

    private var presetsPanel: some View {
        settingsPanel("01", title: t("INTERFACE MODE", "РЕЖИМ ИНТЕРФЕЙСА", "MODO DE INTERFAZ", "РЕЖИМ ІНТЕРФЕЙСУ")) {
            InterfaceChoiceStrip(
                values: InterfacePreset.allCases,
                selection: Binding(get: { preferences.settings.matchingPreset }, set: { if let value = $0 { preferences.apply(value) } }),
                title: { presetTitle($0) },
                symbol: { $0 == .original ? "scope" : ($0 == .calm ? "moon" : "textformat") },
                identifier: "interface-settings.preset"
            )
            note(t("Choose a mode or tune each setting below.",
                   "Выбери режим или настрой параметры вручную.",
                   "Elige un modo o ajusta las opciones a mano.",
                   "Обери режим або налаштуй параметри вручну."))
        }
    }

    private var motionPanel: some View {
        settingsPanel("02", title: t("MOTION & BACKGROUND", "ДВИЖЕНИЕ И ФОН", "MOVIMIENTO Y FONDO", "РУХ І ФОН")) {
            settingToggle(
                t("Reduce motion", "Меньше движения", "Reducir movimiento", "Менше руху"),
                detail: t("Simpler transitions. Game timers stay unchanged.",
                          "Спокойнее переходы. Игровые таймеры без изменений.",
                          "Transiciones sencillas. No cambia los temporizadores.",
                          "Спокійніші переходи. Ігрові таймери без змін."),
                value: $preferences.settings.reduceMotion, id: "reduce-motion"
            )
            rule
            settingToggle(
                t("Background effects", "Фоновые эффекты", "Efectos de fondo", "Фонові ефекти"),
                detail: t("Shared grid, glow and laser lines.",
                          "Фоновая сетка, свечение и лазерные линии.",
                          "Cuadrícula, brillo y líneas láser de fondo.",
                          "Фонова сітка, світіння та лазерні лінії."),
                value: $preferences.settings.backgroundEffects, id: "background-effects"
            )
            if systemReduceMotion {
                note(t("iOS Reduce Motion is active and takes priority.",
                       "В iOS включено «Уменьшение движения». Оно имеет приоритет.",
                       "Reducir movimiento está activo en iOS y tiene prioridad.",
                       "В iOS увімкнено «Зменшення руху». Воно має пріоритет."))
                    .foregroundStyle(SpyTheme.amber)
                    .accessibilityIdentifier("interface-settings.system-motion")
            }
        }
    }

    private var readabilityPanel: some View {
        settingsPanel("03", title: t("READABILITY", "ЧИТАЕМОСТЬ", "LEGIBILIDAD", "ЧИТАБЕЛЬНІСТЬ")) {
            settingToggle(
                t("Stronger contrast", "Усиленный контраст", "Más contraste", "Посилений контраст"),
                detail: t("Brighter shared secondary text and borders.",
                          "Ярче общие второстепенные тексты и границы.",
                          "Textos secundarios y bordes compartidos más claros.",
                          "Яскравіші спільні другорядні тексти й межі."),
                value: $preferences.settings.enhancedContrast, id: "contrast"
            )
            rule
            VStack(alignment: .leading, spacing: 10) {
                controlTitle(t("Small labels", "Служебные подписи", "Etiquetas pequeñas", "Службові підписи"))
                InterfaceChoiceStrip(
                    values: InterfaceLabelSize.allCases,
                    selection: optionalBinding($preferences.settings.labelSize),
                    title: { labelSizeTitle($0) },
                    identifier: "interface-settings.label-size"
                )
                note(t("Shared captions and menu text — not all game text.",
                       "Общие мелкие подписи и текст меню — не весь текст игры.",
                       "Etiquetas y menús compartidos, no todo el texto del juego.",
                       "Спільні дрібні підписи й текст меню — не весь текст гри."))
            }
            .padding(.vertical, 4)
            rule
            settingToggle(
                t("Navigation labels", "Подписи навигации", "Nombres de navegación", "Підписи навігації"),
                detail: t("Show names beneath bottom-bar icons.",
                          "Названия под значками нижней панели.",
                          "Nombres bajo los iconos de la barra inferior.",
                          "Назви під значками нижньої панелі."),
                value: $preferences.settings.dockLabels, id: "dock-labels"
            )
        }
    }

    private var hapticsPanel: some View {
        settingsPanel("04", title: t("HAPTIC FEEDBACK", "ТАКТИЛЬНЫЙ ОТКЛИК", "RESPUESTA HÁPTICA", "ТАКТИЛЬНИЙ ВІДГУК")) {
            InterfaceChoiceStrip(
                values: InterfaceHaptics.allCases,
                selection: optionalBinding($preferences.settings.haptics),
                title: { hapticTitle($0) },
                identifier: "interface-settings.haptics"
            )
            Button { HapticManager.shared.fire(.reveal) } label: {
                SpyActionLabel(title: t("TEST FEEDBACK", "ПРОВЕРИТЬ ОТКЛИК", "PROBAR RESPUESTA", "ПЕРЕВІРИТИ ВІДГУК"), systemImage: "waveform")
            }
            .buttonStyle(SpyButtonStyle(variant: .outline))
            .disabled(preferences.settings.haptics == .off)
            .opacity(preferences.settings.haptics == .off ? 0.35 : 1)
            .accessibilityIdentifier("interface-settings.test-haptic")
            note(t("App-generated feedback, including LIMITLESS. Feel it on a supported iPhone; the Simulator cannot vibrate.",
                   "Отклик приложения, включая LIMITLESS. Ощутить можно на поддерживаемом iPhone; симулятор не вибрирует.",
                   "Respuesta de la app, incluido LIMITLESS. Requiere un iPhone compatible; el simulador no vibra.",
                   "Відгук застосунку, включно з LIMITLESS. Відчути можна на підтримуваному iPhone; симулятор не вібрує."))
        }
    }

    private var resetControls: some View {
        VStack(spacing: 14) {
            Button { showsResetConfirmation = true } label: {
                SpyActionLabel(title: t("RESTORE ORIGINAL", "ВЕРНУТЬ ИСХОДНЫЕ", "RESTAURAR ORIGINAL", "ПОВЕРНУТИ ПОЧАТКОВІ"), systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(SpyButtonStyle(variant: .ghost))
            .accessibilityIdentifier("interface-settings.reset")
            note(t("LOCAL SETTINGS // Available to everyone. Profile, purchases and game data are unchanged.",
                   "ЛОКАЛЬНО // Доступно всем. Профиль, покупки и игровые данные не меняются.",
                   "AJUSTES LOCALES // Para todos. No cambia el perfil, las compras ni los datos de juego.",
                   "ЛОКАЛЬНО // Доступно всім. Профіль, покупки й ігрові дані не змінюються."))
        }
    }

    private var resetConfirmation: some View {
        SpyModal(
            title: t("Reset interface?", "Сбросить интерфейс?", "¿Restablecer interfaz?", "Скинути інтерфейс?"),
            message: t("Only the settings on this page will return to their original values.",
                       "Только параметры на этой странице вернутся к исходным значениям.",
                       "Solo las opciones de esta página volverán a sus valores originales.",
                       "Лише параметри на цій сторінці повернуться до початкових значень."),
            systemImage: "arrow.counterclockwise"
        ) {
            VStack(spacing: 10) {
                Button {
                    preferences.reset()
                    showsResetConfirmation = false
                } label: {
                    SpyActionLabel(title: t("RESET", "СБРОСИТЬ", "RESTABLECER", "СКИНУТИ"), systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .accessibilityIdentifier("interface-settings.reset-confirm")
                .accessibilityFocused($resetIsFocused)

                Button { showsResetConfirmation = false } label: {
                    SpyActionLabel(title: t("CANCEL", "ОТМЕНА", "CANCELAR", "СКАСУВАТИ"), systemImage: "xmark")
                }
                .buttonStyle(SpyButtonStyle(variant: .ghost))
                .accessibilityIdentifier("interface-settings.reset-cancel")
            }
        }
        .accessibilityAction(.escape) { showsResetConfirmation = false }
    }

    private func settingsPanel<Content: View>(_ number: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        SpyPanel(animatesEntrance: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(number).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(SpyTheme.red)
                    Text(title).font(SpyTheme.brandFont(size: 21)).tracking(0.5).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    Text("//").font(SpyTheme.micro).foregroundStyle(SpyTheme.faint).accessibilityHidden(true)
                }
                content()
            }
        }
    }

    private func settingToggle(_ title: String, detail: String, value: Binding<Bool>, id: String) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 5) {
                controlTitle(title)
                note(detail)
            }
        }
        .toggleStyle(InterfaceSwitchStyle(
            onTitle: t("ON", "ВКЛ", "SÍ", "УВІМК"),
            offTitle: t("OFF", "ВЫКЛ", "NO", "ВИМК")
        ))
        .accessibilityIdentifier("interface-settings.\(id)")
    }

    private func previewNav(_ symbol: String, title: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
            if preferences.settings.dockLabels {
                Text(title).font(.system(size: 6.5 * preferences.settings.labelSize.scale, weight: .bold, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.65)
            }
        }
        .foregroundStyle(SpyTheme.muted)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private var rule: some View { Rectangle().fill(SpyTheme.stroke).frame(height: 1) }

    private func controlTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(SpyTheme.brandFont(size: 19))
            .tracking(0.3)
            .foregroundStyle(SpyTheme.bodyText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(SpyTheme.muted)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var currentModeTitle: String {
        preferences.settings.matchingPreset.map(presetTitle) ?? t("Custom", "Свои настройки", "Personalizado", "Власні налаштування")
    }

    private func optionalBinding<Value>(_ binding: Binding<Value>) -> Binding<Value?> {
        Binding(get: { binding.wrappedValue }, set: { if let value = $0 { binding.wrappedValue = value } })
    }

    private func presetTitle(_ preset: InterfacePreset) -> String {
        switch preset {
        case .original: t("Original", "Оригинал", "Original", "Оригінал")
        case .calm: t("Calm", "Спокойный", "Calma", "Спокійний")
        case .readable: t("Readable", "Читаемый", "Legible", "Читабельний")
        }
    }

    private func labelSizeTitle(_ size: InterfaceLabelSize) -> String {
        switch size {
        case .compact: t("Compact", "Мелкие", "Pequeñas", "Дрібні")
        case .standard: t("Standard", "Обычные", "Normales", "Звичайні")
        case .large: t("Large", "Крупные", "Grandes", "Великі")
        }
    }

    private func hapticTitle(_ mode: InterfaceHaptics) -> String {
        switch mode {
        case .off: t("Off", "Выкл", "No", "Вимк")
        case .soft: t("Soft", "Мягкий", "Suave", "М’який")
        case .standard: t("Standard", "Обычный", "Normal", "Звичайний")
        }
    }

    private func t(_ en: String, _ ru: String, _ es: String, _ uk: String) -> String {
        switch language { case .en: en; case .ru: ru; case .es: es; case .uk: uk }
    }
}

#Preview("Original") {
    InterfaceSettingsView(language: .ru, preferences: InterfacePreferences())
}

#Preview("Readable") {
    let preferences = InterfacePreferences()
    preferences.apply(.readable)
    return InterfaceSettingsView(language: .ru, preferences: preferences)
}
