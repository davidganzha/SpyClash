import SwiftUI

struct InterfaceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Bindable var preferences: InterfacePreferences
    let language: AppLanguage
    @State private var showsResetConfirmation = false

    init(language: AppLanguage, preferences: InterfacePreferences = .shared) {
        self.language = language
        self.preferences = preferences
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    livePreview
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section {
                    HStack(spacing: 8) {
                        ForEach(InterfacePreset.allCases) { preset in
                            presetButton(preset)
                        }
                    }
                    .listRowBackground(SpyTheme.panel)
                } header: {
                    sectionTitle(t("READY-MADE MODES", "ГОТОВЫЕ РЕЖИМЫ", "MODOS PREDEFINIDOS", "ГОТОВІ РЕЖИМИ"))
                } footer: {
                    Text(t("Choose a starting point, then adjust any setting.",
                           "Выбери основу, затем настрой каждый параметр под себя.",
                           "Elige una base y ajusta cada opción a tu gusto.",
                           "Обери основу, а потім налаштуй кожен параметр під себе."))
                }

                Section {
                    Toggle(isOn: $preferences.settings.reduceMotion) {
                        settingLabel(t("Reduce motion", "Меньше движения", "Reducir movimiento", "Менше руху"), icon: "circle.dotted")
                    }
                    .accessibilityIdentifier("interface-settings.reduce-motion")

                    Toggle(isOn: $preferences.settings.backgroundEffects) {
                        settingLabel(t("Background effects", "Фоновые эффекты", "Efectos de fondo", "Фонові ефекти"), icon: "sparkles")
                    }
                    .accessibilityIdentifier("interface-settings.background-effects")
                } header: {
                    sectionTitle(t("MOTION & BACKGROUND", "ДВИЖЕНИЕ И ФОН", "MOVIMIENTO Y FONDO", "РУХ І ФОН"))
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(t("Simplifies supported transitions and cinematic effects without changing game timers. Background effects control the shared grid, glow and laser lines.",
                               "Упрощает поддерживаемые переходы и киноэффекты, не меняя игровые таймеры. Фоновые эффекты — общая сетка, свечение и лазерные линии.",
                               "Simplifica transiciones y efectos compatibles sin cambiar los temporizadores. Los efectos de fondo incluyen la cuadrícula, el brillo y las líneas láser.",
                               "Спрощує підтримувані переходи й кіноефекти, не змінюючи ігрові таймери. Фонові ефекти — спільна сітка, світіння та лазерні лінії."))
                        if systemReduceMotion {
                            Text(t("iOS Reduce Motion is on and takes priority.",
                                   "В iOS включено «Уменьшение движения» — оно действует независимо от переключателя.",
                                   "Reducir movimiento está activo en iOS y tiene prioridad.",
                                   "В iOS увімкнено «Зменшення руху» — воно має пріоритет."))
                                .foregroundStyle(SpyTheme.amber)
                                .accessibilityIdentifier("interface-settings.system-motion")
                        }
                    }
                }
                .listRowBackground(SpyTheme.panel)

                Section {
                    Toggle(isOn: $preferences.settings.enhancedContrast) {
                        settingLabel(t("Stronger contrast", "Усиленный контраст", "Más contraste", "Посилений контраст"), icon: "circle.lefthalf.filled")
                    }
                    .accessibilityIdentifier("interface-settings.contrast")

                    Picker(selection: $preferences.settings.labelSize) {
                        ForEach(InterfaceLabelSize.allCases) { size in
                            Text(labelSizeTitle(size)).tag(size)
                        }
                    } label: {
                        settingLabel(t("Small labels", "Служебные подписи", "Etiquetas pequeñas", "Службові підписи"), icon: "textformat.size")
                    }
                    .accessibilityIdentifier("interface-settings.label-size")

                    Toggle(isOn: $preferences.settings.dockLabels) {
                        settingLabel(t("Navigation labels", "Подписи навигации", "Nombres de navegación", "Підписи навігації"), icon: "rectangle.bottomthird.inset.filled")
                    }
                    .accessibilityIdentifier("interface-settings.dock-labels")
                } header: {
                    sectionTitle(t("READABILITY", "ЧИТАЕМОСТЬ", "LEGIBILIDAD", "ЧИТАБЕЛЬНІСТЬ"))
                } footer: {
                    Text(t("Contrast brightens shared secondary text and borders. Label size affects shared captions and menu text, not every text in the game. Navigation labels appear below the bottom-bar icons.",
                           "Контраст делает общие второстепенные тексты и границы ярче. Размер меняет общие мелкие подписи и текст меню, но не весь текст игры. Подписи навигации появятся под значками нижней панели.",
                           "El contraste aclara textos secundarios y bordes compartidos. El tamaño cambia etiquetas comunes y menús, no todo el texto. Los nombres aparecen bajo los iconos de la barra inferior.",
                           "Контраст робить спільні другорядні тексти й межі яскравішими. Розмір змінює спільні дрібні підписи й текст меню, але не весь текст гри. Підписи з’являться під значками нижньої панелі."))
                }
                .listRowBackground(SpyTheme.panel)

                Section {
                    Picker(selection: $preferences.settings.haptics) {
                        ForEach(InterfaceHaptics.allCases) { mode in
                            Text(hapticTitle(mode)).tag(mode)
                        }
                    } label: {
                        settingLabel(t("Haptic feedback", "Тактильный отклик", "Respuesta háptica", "Тактильний відгук"), icon: "waveform")
                    }
                    .accessibilityIdentifier("interface-settings.haptics")

                    Button {
                        HapticManager.shared.fire(.reveal)
                    } label: {
                        Label(t("Try feedback", "Проверить отклик", "Probar respuesta", "Перевірити відгук"), systemImage: "hand.tap")
                            .frame(minHeight: 28)
                    }
                    .disabled(preferences.settings.haptics == .off)
                    .opacity(preferences.settings.haptics == .off ? 0.4 : 1)
                    .accessibilityIdentifier("interface-settings.test-haptic")
                } header: {
                    sectionTitle(t("TOUCH", "ОТКЛИК", "TACTO", "ВІДГУК"))
                } footer: {
                    Text(t("Controls app-generated feedback, including LIMITLESS. Requires a supported iPhone; the Simulator cannot reproduce the physical feel.",
                           "Управляет откликом приложения, включая LIMITLESS. Ощутить его можно на поддерживаемом iPhone; симулятор не передаёт вибрацию.",
                           "Controla la respuesta de la app, incluido LIMITLESS. Requiere un iPhone compatible; el simulador no reproduce la sensación física.",
                           "Керує відгуком застосунку, включно з LIMITLESS. Відчути його можна на підтримуваному iPhone; симулятор не передає вібрацію."))
                }
                .listRowBackground(SpyTheme.panel)

                Section {
                    Button(role: .destructive) { showsResetConfirmation = true } label: {
                        Label(t("Restore original interface", "Вернуть исходный интерфейс", "Restaurar interfaz original", "Повернути початковий інтерфейс"), systemImage: "arrow.counterclockwise")
                            .frame(minHeight: 28)
                    }
                    .accessibilityIdentifier("interface-settings.reset")
                } footer: {
                    Text(t("Saved automatically on this device. Available to everyone. Profile, purchases and game data are not changed.",
                           "Сохраняется автоматически на этом устройстве. Доступно всем. Профиль, покупки и игровые данные не меняются.",
                           "Se guarda automáticamente en este dispositivo. Disponible para todos. No cambia el perfil, las compras ni los datos de juego.",
                           "Зберігається автоматично на цьому пристрої. Доступно всім. Профіль, покупки й ігрові дані не змінюються."))
                }
                .listRowBackground(SpyTheme.panel)
            }
            .scrollContentBackground(.hidden)
            .background { SpyBackground() }
            .accessibilityIdentifier("interface-settings.form")
            .navigationTitle(t("Interface", "Интерфейс", "Interfaz", "Інтерфейс"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(t("Close settings", "Закрыть настройки", "Cerrar ajustes", "Закрити налаштування"))
                    .accessibilityIdentifier("interface-settings.close")
                }
            }
            .alert(t("Reset interface?", "Сбросить интерфейс?", "¿Restablecer interfaz?", "Скинути інтерфейс?"), isPresented: $showsResetConfirmation) {
                Button(t("Cancel", "Отмена", "Cancelar", "Скасувати"), role: .cancel) {}
                Button(t("Reset", "Сбросить", "Restablecer", "Скинути"), role: .destructive) {
                    preferences.reset()
                }
            } message: {
                Text(t("Only the settings on this page will return to their original values.",
                       "Только параметры на этой странице вернутся к исходным значениям.",
                       "Solo las opciones de esta página volverán a sus valores originales.",
                       "Лише параметри на цій сторінці повернуться до початкових значень."))
            }
        }
        .tint(SpyTheme.red)
        .preferredColorScheme(.dark)
        .onChange(of: preferences.settings.haptics) { _, mode in
            if mode == .off { HapticManager.shared.stopFeedback() }
        }
    }

    private var livePreview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("SPYCLASH / UI").font(SpyTheme.micro).tracking(2)
                Spacer()
                Image(systemName: "slider.horizontal.3")
            }
            .foregroundStyle(SpyTheme.red)

            Text(t("MAKE IT YOURS", "ПОД ТВОЙ РИТМ", "A TU MEDIDA", "ПІД ТВІЙ РИТМ"))
                .font(SpyTheme.brandFont(size: 30))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.75)
                .lineLimit(1)

            Text(t("Live preview · changes apply immediately", "Живой пример · изменения сразу в деле", "Vista previa · cambios al instante", "Живий приклад · зміни одразу в дії"))
                .font(SpyTheme.mono)
                .foregroundStyle(SpyTheme.muted)

            HStack {
                previewNav("house", title: t("Home", "Главная", "Inicio", "Головна"))
                Spacer()
                previewNav("square.grid.2x2", title: t("Packs", "Наборы", "Paquetes", "Набори"))
                Spacer()
                previewNav("person.crop.circle", title: t("Profile", "Профиль", "Perfil", "Профіль"))
            }
            .padding(14)
            .background(SpyTheme.control)
            .overlay(Rectangle().stroke(SpyTheme.inputBorder, lineWidth: 1))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            SpyBackground()
                .overlay {
                    SpyLaserScanLayer(reduceMotion: preferences.settings.effectiveReduceMotion(system: systemReduceMotion))
                }
                .clipped()
        }
        .overlay(Rectangle().stroke(SpyTheme.red.opacity(0.55), lineWidth: 1))
        .accessibilityIdentifier("interface-settings.preview")
    }

    private func previewNav(_ symbol: String, title: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 20))
            if preferences.settings.dockLabels {
                Text(title).font(SpyTheme.micro).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(SpyTheme.muted)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func presetButton(_ preset: InterfacePreset) -> some View {
        let selected = preferences.settings.matchingPreset == preset
        return Button { preferences.apply(preset) } label: {
            VStack(spacing: 6) {
                Image(systemName: preset == .original ? "scope" : (preset == .calm ? "moon" : "textformat"))
                Text(presetTitle(preset))
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(selected ? SpyTheme.red : SpyTheme.bodyText)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(selected ? SpyTheme.red.opacity(0.08) : .clear)
            .overlay(Rectangle().stroke(selected ? SpyTheme.red : SpyTheme.stroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("interface-settings.preset.\(preset.rawValue)")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(SpyTheme.micro).tracking(1.5).foregroundStyle(SpyTheme.muted)
    }

    private func settingLabel(_ title: String, icon: String) -> some View {
        Label {
            Text(title).foregroundStyle(SpyTheme.text)
        } icon: {
            Image(systemName: icon).foregroundStyle(SpyTheme.red)
        }
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
        case .compact: t("Compact", "Компактные", "Compactas", "Компактні")
        case .standard: t("Standard", "Обычные", "Normales", "Звичайні")
        case .large: t("Large", "Крупные", "Grandes", "Великі")
        }
    }

    private func hapticTitle(_ mode: InterfaceHaptics) -> String {
        switch mode {
        case .off: t("Off", "Выключен", "Desactivada", "Вимкнено")
        case .soft: t("Soft", "Мягкий", "Suave", "М’який")
        case .standard: t("Standard", "Обычный", "Normal", "Звичайний")
        }
    }

    private func t(_ en: String, _ ru: String, _ es: String, _ uk: String) -> String {
        switch language { case .en: en; case .ru: ru; case .es: es; case .uk: uk }
    }
}

#Preview {
    InterfaceSettingsView(language: .ru, preferences: InterfacePreferences())
}
