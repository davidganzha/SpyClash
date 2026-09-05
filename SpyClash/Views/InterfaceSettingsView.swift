import SwiftUI

struct InterfaceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Bindable var preferences: InterfacePreferences
    let language: AppLanguage
    @State private var showsResetConfirmation = false
    @State private var scaleDraft: Double
    @State private var isEditingScale = false
    @AccessibilityFocusState private var resetIsFocused: Bool

    init(language: AppLanguage, preferences: InterfacePreferences = .shared) {
        self.language = language
        self.preferences = preferences
        _scaleDraft = State(initialValue: preferences.settings.interfaceScale)
    }

    var body: some View {
        ZStack {
            SpyBackground()

            VStack(spacing: 0) {
                sheetHeader
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        settingsHero
                        presetsPanel
                        scalePanel
                        motionPanel
                        readabilityPanel
                        hapticsPanel
                        languagePanel
                        radarPanel
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
        .onChange(of: preferences.settings.interfaceScale) { _, value in
            if !isEditingScale { scaleDraft = value }
        }
        .onDisappear {
            if isEditingScale { preferences.settings.interfaceScale = scaleDraft }
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

    private var settingsHero: some View {
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
        .accessibilityIdentifier("interface-settings.hero")
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

    private var scalePanel: some View {
        settingsPanel("02", title: t("INTERFACE SCALE", "МАСШТАБ ИНТЕРФЕЙСА", "ESCALA DE INTERFAZ", "МАСШТАБ ІНТЕРФЕЙСУ")) {
            HStack(alignment: .firstTextBaseline) {
                controlTitle(t("Text, buttons, panels", "Текст, кнопки, панели", "Texto, botones, paneles", "Текст, кнопки, панелі"))
                Spacer(minLength: 8)
                Text("\(Int((scaleDraft * 100).rounded()))%")
                    .font(SpyTheme.brandFont(size: 26))
                    .monospacedDigit()
                    .foregroundStyle(SpyTheme.red)
                    .accessibilityIdentifier("interface-settings.scale-value")
            }

            Slider(
                value: scaleBinding,
                in: InterfaceScalePolicy.range,
                step: InterfaceScalePolicy.step,
                onEditingChanged: { editing in
                    isEditingScale = editing
                    if !editing { preferences.settings.interfaceScale = scaleDraft }
                }
            ) {
                Text(t("Interface scale", "Масштаб интерфейса", "Escala de interfaz", "Масштаб інтерфейсу"))
            }
            .tint(SpyTheme.red)
            .frame(minHeight: 44)
            .accessibilityValue("\(Int((scaleDraft * 100).rounded()))%")
            .accessibilityIdentifier("interface-settings.scale")

            HStack {
                Text("100%")
                Spacer()
                Text("120%")
            }
            .font(SpyTheme.micro)
            .foregroundStyle(SpyTheme.muted)
            .accessibilityHidden(true)

            note(t("Applies when you release the slider. System keyboard and Apple purchase dialogs keep their standard size.",
                   "Применяется после отпускания ползунка. Системная клавиатура и окна оплаты Apple сохраняют обычный размер.",
                   "Se aplica al soltar. El teclado del sistema y los diálogos de compra de Apple mantienen su tamaño normal.",
                   "Застосовується після відпускання повзунка. Системна клавіатура й вікна оплати Apple зберігають звичайний розмір."))
        }
    }

    private var scaleBinding: Binding<Double> {
        Binding(
            get: { scaleDraft },
            set: { value in
                scaleDraft = InterfaceScalePolicy.clamped(value)
                // Accessibility adjustments may not start a drag session.
                if !isEditingScale { preferences.settings.interfaceScale = scaleDraft }
            }
        )
    }

    private var motionPanel: some View {
        settingsPanel("03", title: t("MOTION & BACKGROUND", "ДВИЖЕНИЕ И ФОН", "MOVIMIENTO Y FONDO", "РУХ І ФОН")) {
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
        settingsPanel("04", title: t("READABILITY", "ЧИТАЕМОСТЬ", "LEGIBILIDAD", "ЧИТАБЕЛЬНІСТЬ")) {
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
        settingsPanel("05", title: t("HAPTIC FEEDBACK", "ТАКТИЛЬНЫЙ ОТКЛИК", "RESPUESTA HÁPTICA", "ТАКТИЛЬНИЙ ВІДГУК")) {
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

    private var languagePanel: some View {
        settingsPanel("06", title: t("LANGUAGE", "ЯЗЫК", "IDIOMA", "МОВА")) {
            LanguageSettingsView()
        }
    }

    private var radarPanel: some View {
        settingsPanel("07", title: t("RADAR ACCESS", "ДОСТУП ПО РАДАРУ", "ACCESO POR RADAR", "ДОСТУП ЧЕРЕЗ РАДАР")) {
            RadarPolicySettingsView()
        }
    }

    private var resetControls: some View {
        VStack(spacing: 14) {
            Button { showsResetConfirmation = true } label: {
                SpyActionLabel(title: t("RESET INTERFACE", "СБРОСИТЬ ИНТЕРФЕЙС", "RESTABLECER INTERFAZ", "СКИНУТИ ІНТЕРФЕЙС"), systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(SpyButtonStyle(variant: .ghost))
            .accessibilityIdentifier("interface-settings.reset")
            note(t("Reset affects appearance and haptics only. Language, radar invitations, profile and purchases stay unchanged.",
                   "Сброс только оформления и отклика. Язык, приглашения по радару, профиль и покупки не меняются.",
                   "Solo restablece el aspecto y la vibración. No cambia el idioma, las invitaciones del radar, el perfil ni las compras.",
                   "Скидає лише оформлення та відгук. Мова, запрошення через радар, профіль і покупки не змінюються."))
        }
    }

    private var resetConfirmation: some View {
        SpyModal(
            title: t("Reset interface?", "Сбросить интерфейс?", "¿Restablecer interfaz?", "Скинути інтерфейс?"),
            message: t("Restore appearance and haptics. Language and radar invitation settings will stay unchanged.",
                       "Вернуть исходное оформление и отклик. Язык и настройки приглашений по радару сохранятся.",
                       "Restablecer aspecto y vibración. Se mantienen el idioma y los ajustes de invitaciones del radar.",
                       "Повернути початкове оформлення та відгук. Мова й налаштування запрошень через радар збережуться."),
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
        .toggleStyle(.switch)
        .tint(SpyTheme.red)
        .frame(minHeight: 68)
        .accessibilityIdentifier("interface-settings.\(id)")
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
        .environment(AppState())
}

#Preview("Readable") {
    let preferences = InterfacePreferences()
    preferences.apply(.readable)
    return InterfaceSettingsView(language: .ru, preferences: preferences)
        .environment(AppState())
}
