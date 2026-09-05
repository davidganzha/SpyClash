import SwiftUI

struct LimitlessSheet: Identifiable { let id = "limitless" }

/// Restored page composition; purchases still use the current verified IAP services.
struct PricingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var access: MembershipStore { appState.membership }
    private var store: StoreKitManager { appState.storeKit }
    private var copy: LimitlessCopy { LimitlessCopy(language: appState.language) }

    var body: some View {
        PageChrome(
            eyebrow: copy.pricingEyebrow,
            status: "LIMITLESS",
            showsPageTopEdge: false,
            topReserve: 0
        ) {
            LimitlessClearancePanel(
                copy: copy,
                hasAccess: access.hasAccess,
                membershipCategoryLabel: accessStatus,
                membershipCategoryAccent: access.hasAccess ? SpyTheme.green : accessIsUnknown ? SpyTheme.amber : SpyTheme.muted,
                displayPrice: store.product?.displayPrice,
                subscriptionPeriodLabel: copy.week.uppercased()
            ) {
                purchaseControls
            } legal: {
                legalDetails
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 36)
        }
        .accessibilityIdentifier("limitless.screen")
        .overlay {
            GeometryReader { proxy in
                sheetCloseButton
                    .position(x: proxy.size.width - 44, y: max(66, proxy.safeAreaInsets.top - 6))
            }
        }
        .task(id: access.scope) {
            _ = await access.refresh()
            if !access.isPreview, !Task.isCancelled { await store.loadProduct() }
        }
        .spyLimitlessUnlockLayer()
    }

    private var sheetCloseButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(SpyTheme.muted)
                .frame(width: 44, height: 44)
                .background(SpyTheme.black.opacity(0.88), in: CutCornerShape(cut: 8))
                .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.strokeStrong, lineWidth: 1))
                .contentShape(CutCornerShape(cut: 8))
        }
        .buttonStyle(SpyWebPressStyle())
        .accessibilityLabel(copy.close)
        .accessibilityIdentifier("limitless.close")
    }

    private var purchaseControls: some View {
        VStack(spacing: 10) {
            Button { Task { await performPrimaryAction() } } label: {
                HStack(spacing: 12) {
                    Image(systemName: isBusy ? "antenna.radiowaves.left.and.right" : "bolt.fill")
                        .font(.system(size: 17, weight: .black))
                        .symbolEffect(.pulse, options: isBusy ? .repeating : .default, value: isBusy)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(primaryActionTitle)
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .tracking(0.08)
                            .spyFitted(lines: 2, scale: 0.60)

                        Text(primaryActionDetail)
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .tracking(0.06)
                            .foregroundStyle(.white.opacity(0.68))
                            .spyFitted(lines: 2, scale: 0.62)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: access.hasAccess || accessIsUnknown ? "arrow.clockwise" : "arrow.up.right")
                        .font(.system(size: 14, weight: .black))
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 62)
            }
            .buttonStyle(LimitlessCommandButtonStyle())
            .disabled(primaryAction == .unavailable || primaryAction == .waiting)
            .accessibilityIdentifier(primaryAction == .purchase ? "limitless.purchase" : "limitless.primary-action")
            .accessibilityHint(access.isPreview ? copy.previewNotice : primaryActionDetail)

            if access.snapshot?.isUniversal != true {
                HStack(spacing: 8) {
                    Button { Task { await store.restore() } } label: {
                        secondaryActionLabel(copy.restore.uppercased(), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .disabled(isBusy || access.isPreview)
                    .accessibilityIdentifier("limitless.restore")

                    if access.snapshot?.providers.contains("apple") == true {
                        Button {
                            Task {
                                do { try await store.manageSubscriptions() }
                                catch { appState.showToast(copy.unavailable, kind: .error) }
                            }
                        } label: {
                            secondaryActionLabel(copy.manageShort, systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(SpyWebPressStyle())
                        .disabled(isBusy || access.isPreview)
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                Text(copy.appStorePurchase)
                Circle().frame(width: 3, height: 3)
                Text(copy.cancelAnytime)
            }
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .tracking(0.06)
            .foregroundStyle(SpyTheme.faint)
            .spyFitted(scale: 0.64, alignment: .center)

            if let message = stateMessage {
                Text(message)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(store.state == .failed ? SpyTheme.red : SpyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("limitless.status")
            }
        }
    }

    private func secondaryActionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
            Text(title).spyFitted(lines: 2, scale: 0.58)
        }
        .font(.system(size: 8, weight: .black, design: .monospaced))
        .tracking(0.06)
        .foregroundStyle(SpyTheme.muted)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 42)
        .background(SpyTheme.black.opacity(0.48), in: CutCornerShape(cut: 7))
        .overlay(CutCornerShape(cut: 7).stroke(SpyTheme.strokeStrong, lineWidth: 1))
        .contentShape(CutCornerShape(cut: 7))
    }

    private var legalDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(copy.subscriptionProtocol)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.14).foregroundStyle(SpyTheme.dim)
                Spacer()
                Text(copy.autoRenews)
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .tracking(0.08).foregroundStyle(SpyTheme.red.opacity(0.72))
            }

            Text(access.snapshot?.isUniversal == true ? copy.included : copy.renewal)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineSpacing(3).foregroundStyle(SpyTheme.dim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                legalLink(copy.terms.uppercased(), url: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
                legalLink(copy.privacy.uppercased(), url: "https://spyclash.com/PrivacyPolicy")
            }

            if access.isPreview {
                Text(copy.previewNotice)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(SpyTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("limitless.preview-notice")
            }
        }
        .padding(14)
        .background(SpyTheme.dark.opacity(0.78), in: CutCornerShape(cut: 10))
        .overlay(CutCornerShape(cut: 10).stroke(SpyTheme.stroke.opacity(0.90), lineWidth: 1))
    }

    private func legalLink(_ title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 6) {
                Text(title).spyFitted(scale: 0.62)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
            }
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .tracking(0.08).foregroundStyle(SpyTheme.muted)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(SpyTheme.black.opacity(0.55), in: CutCornerShape(cut: 7))
            .overlay(CutCornerShape(cut: 7).stroke(SpyTheme.strokeStrong, lineWidth: 1))
            .contentShape(CutCornerShape(cut: 7))
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private var isBusy: Bool { access.isLoading || store.state.isBusy || store.isLoadingProduct }
    private var accessIsUnknown: Bool { access.snapshot == nil || access.errorMessage != nil }

    private var primaryAction: LimitlessPrimaryAction {
        .resolve(
            isPreview: access.isPreview, hasAccess: access.hasAccess,
            isBusy: isBusy, isPending: store.state == .pending,
            accessIsUnknown: accessIsUnknown, canPurchase: access.canPurchase,
            hasProduct: store.product != nil, storeCanPurchase: store.canPurchase
        )
    }

    private var primaryActionTitle: String {
        if store.state == .pending { return copy.pendingTitle }
        if isBusy { return copy.checking.uppercased() }
        if access.hasAccess { return copy.refreshAccess }
        switch primaryAction {
        case .preview, .purchase: return copy.historicalSubscribe
        case .refresh: return copy.verifyMembership
        case .loadProduct: return copy.retry.uppercased()
        case .unavailable, .waiting: return copy.purchaseUnavailable
        }
    }

    private var primaryActionDetail: String {
        if access.isPreview { return copy.previewShort }
        if access.hasAccess { return copy.verifyClearance }
        if accessIsUnknown { return copy.unavailable }
        if let price = store.product?.displayPrice {
            return "\(price) / \(copy.week.uppercased()) // APP STORE"
        }
        return copy.appStorePrice
    }

    private func performPrimaryAction() async {
        switch primaryAction {
        case .preview: appState.showToast(copy.previewNotice, kind: .info)
        case .refresh:
            _ = await access.refresh()
            if access.canPurchase { await store.loadProduct() }
        case .loadProduct: await store.loadProduct()
        case .purchase: await store.purchase(membership: access)
        case .unavailable, .waiting: break
        }
    }

    private var accessStatus: String {
        if access.hasAccess { return "LIMITLESS" }
        if access.isLoading { return copy.syncing }
        if accessIsUnknown { return copy.unverified }
        return "FREE"
    }

    private var stateMessage: String? {
        switch store.state {
        case .preparing, .purchasing, .synchronizing, .restoring: copy.processing
        case .pending: copy.pending
        case .purchased, .restored: copy.synchronized
        case .noPurchases: copy.noPurchases
        case .failed: copy.failed
        default: nil
        }
    }
}

enum LimitlessPrimaryAction: Equatable {
    case preview, refresh, loadProduct, purchase, unavailable, waiting

    static func resolve(
        isPreview: Bool, hasAccess: Bool, isBusy: Bool, isPending: Bool,
        accessIsUnknown: Bool, canPurchase: Bool, hasProduct: Bool, storeCanPurchase: Bool
    ) -> Self {
        if isBusy || isPending { return .waiting }
        if isPreview { return .preview }
        if hasAccess || accessIsUnknown { return .refresh }
        guard canPurchase else { return .unavailable }
        guard hasProduct else { return .loadProduct }
        return storeCanPurchase ? .purchase : .unavailable
    }
}

struct LimitlessFeature: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
}

struct LimitlessEntry: View {
    @Environment(AppState.self) private var appState
    var body: some View {
        let copy = LimitlessCopy(language: appState.language)
        Button { appState.presentedSheet = .limitless } label: {
            HStack {
                Image(systemName: "infinity").foregroundStyle(SpyTheme.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("LIMITLESS").font(.system(size: 15, weight: .black, design: .monospaced))
                    Text(appState.membership.hasAccess ? copy.active : copy.subtitle)
                        .font(.caption).foregroundStyle(SpyTheme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(SpyTheme.muted)
            }
            .padding(18)
            .background(SpyTheme.panelDeep)
            .overlay(Rectangle().stroke(SpyTheme.red.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(SpyWebPressStyle())
        .accessibilityIdentifier("limitless.open")
    }
}

struct LimitlessCopy {
    let language: AppLanguage
    func text(_ en: String, _ ru: String, _ es: String, _ uk: String) -> String {
        switch language { case .en: en; case .ru: ru; case .es: es; case .uk: uk }
    }
    var close: String { text("Close", "Закрыть", "Cerrar", "Закрити") }
    var pricingEyebrow: String { text("// PRICING", "// ПОДПИСКА", "// PRICING", "// ПІДПИСКА") }
    var historicalSubscribe: String { text("SUBSCRIBE NOW", "ОФОРМИТЬ ПОДПИСКУ", "SUSCRIBIRSE AHORA", "ОФОРМИТИ ПІДПИСКУ") }
    var refreshAccess: String { text("REFRESH ACCESS", "ПРОВЕРИТЬ ДОСТУП", "ACTUALIZAR ACCESO", "ПЕРЕВІРИТИ ДОСТУП") }
    var verifyMembership: String { text("VERIFY MEMBERSHIP", "ПРОВЕРИТЬ ПОДПИСКУ", "VERIFICAR MEMBRESIA", "ПЕРЕВІРИТИ ПІДПИСКУ") }
    var verifyClearance: String { text("VERIFY PREMIUM CLEARANCE", "ПРОВЕРИТЬ ПРЕМИУМ ДОПУСК", "VERIFICAR ACCESO PREMIUM", "ПЕРЕВІРИТИ ПРЕМІУМ ДОПУСК") }
    var pendingTitle: String { text("AWAITING APPROVAL", "ОЖИДАЕМ ПОДТВЕРЖДЕНИЯ", "ESPERANDO APROBACIÓN", "ОЧІКУЄМО ПІДТВЕРДЖЕННЯ") }
    var purchaseUnavailable: String { text("PURCHASE UNAVAILABLE", "ПОКУПКА НЕДОСТУПНА", "COMPRA NO DISPONIBLE", "КУПІВЛЯ НЕДОСТУПНА") }
    var previewShort: String { text("UI PREVIEW // NO PAYMENT", "ПРЕДПРОСМОТР // БЕЗ ОПЛАТЫ", "VISTA PREVIA // SIN PAGO", "ПЕРЕГЛЯД // БЕЗ ОПЛАТИ") }
    var manageShort: String { text("MANAGE", "УПРАВЛЯТЬ", "GESTIONAR", "КЕРУВАТИ") }
    var appStorePurchase: String { text("APP STORE PURCHASE", "ПОКУПКА В APP STORE", "COMPRA EN APP STORE", "КУПІВЛЯ В APP STORE") }
    var cancelAnytime: String { text("CANCEL ANYTIME", "ОТМЕНА В ЛЮБОЙ МОМЕНТ", "CANCELA CUANDO QUIERAS", "СКАСУВАННЯ БУДЬ-КОЛИ") }
    var subscriptionProtocol: String { text("SUBSCRIPTION PROTOCOL", "ПРОТОКОЛ ПОДПИСКИ", "PROTOCOLO DE SUSCRIPCION", "ПРОТОКОЛ ПІДПИСКИ") }
    var autoRenews: String { text("AUTO-RENEWS", "АВТОПРОДЛЕНИЕ", "AUTORENOVACION", "АВТОПОДОВЖЕННЯ") }
    var syncing: String { text("SYNCING", "СИНХРОНИЗАЦИЯ", "SINCRONIZANDO", "СИНХРОНІЗАЦІЯ") }
    var features: [LimitlessFeature] {
        [
            LimitlessFeature(
                id: "unlimited",
                title: text("Limitless", "Безлимит", "Sin limites", "Безліміт"),
                detail: text("Unlimited AI themes and word generation for every new mission.", "Неограниченная AI-генерация тем и слов для каждой новой миссии.", "Temas y palabras generados con IA sin limite para cada nueva mision.", "Необмежена ШІ-генерація тем і слів для кожної нової місії."),
                systemImage: "infinity"
            ),
            LimitlessFeature(
                id: "profile_customization",
                title: text("Profile Customization", "Кастомизация профиля", "Personalizacion del perfil", "Кастомізація профілю"),
                detail: text("Exclusive avatars, operative identity styles, and future cosmetic drops.", "Эксклюзивные аватары, стили ID оперативника и будущие косметические обновления.", "Avatares exclusivos, estilos de identidad y futuras recompensas cosmeticas.", "Ексклюзивні аватари, стилі ID оперативника й майбутні косметичні оновлення."),
                systemImage: "paintbrush.pointed.fill"
            ),
            LimitlessFeature(
                id: "game_statistics",
                title: text("Game Statistics", "Статистика игр", "Estadisticas de juego", "Статистика ігор"),
                detail: text("Complete match history, win rate, roles, and advanced analytics.", "Полная история матчей, процент побед, роли и расширенная аналитика.", "Historial completo, porcentaje de victorias, roles y analitica avanzada.", "Повна історія матчів, відсоток перемог, ролі й розширена аналітика."),
                systemImage: "chart.bar.xaxis"
            )
        ]
    }
    var previewNotice: String { text("UI preview — no payment or account change.", "Предпросмотр интерфейса — без оплаты и изменения аккаунта.", "Vista previa — sin pagos ni cambios en la cuenta.", "Попередній перегляд — без оплати й змін акаунта.") }
    var unverified: String { text("UNVERIFIED", "НЕ ПРОВЕРЕН", "SIN VERIFICAR", "НЕ ПЕРЕВІРЕНО") }
    var clearance: String { text("PREMIUM CLEARANCE", "ПРЕМИУМ ДОПУСК", "ACCESO PREMIUM", "ПРЕМІУМ ДОПУСК") }
    var fieldKit: String { text("FIELD KIT // LEVEL 01", "ПОЛЕВОЙ НАБОР // УРОВЕНЬ 01", "EQUIPO DE CAMPO // NIVEL 01", "ПОЛЬОВИЙ НАБІР // РІВЕНЬ 01") }
    var mission: String { text("REMOVE LIMITS FROM EVERY MISSION.", "СНИМИ ОГРАНИЧЕНИЯ С КАЖДОЙ МИССИИ.", "ELIMINA LOS LÍMITES DE CADA MISIÓN.", "ЗНІМИ ОБМЕЖЕННЯ З КОЖНОЇ МІСІЇ.") }
    var appStorePrice: String { text("PRICE FROM APP STORE", "ЦЕНА ИЗ APP STORE", "PRECIO DE APP STORE", "ЦІНА З APP STORE") }
    var capabilities: String { text("CAPABILITIES", "ВОЗМОЖНОСТИ", "CAPACIDADES", "МОЖЛИВОСТІ") }
    var preview: String { text("PREVIEW", "ПРЕДПРОСМОТР", "VISTA PREVIA", "ПОПЕРЕДНІЙ ПЕРЕГЛЯД") }
    var enabled: String { text("ACTIVE", "АКТИВНО", "ACTIVO", "АКТИВНО") }
    var locked: String { text("Requires LIMITLESS", "Нужен LIMITLESS", "Requiere LIMITLESS", "Потрібен LIMITLESS") }
    var scanning: String { text("ESTABLISHING SECURE LINK", "УСТАНОВКА ЗАЩИЩЁННОГО КАНАЛА", "ESTABLECIENDO CANAL SEGURO", "ВСТАНОВЛЕННЯ ЗАХИЩЕНОГО КАНАЛУ") }
    var unlimitedTitle: String { text("UNLIMITED", "БЕЗЛИМИТ", "SIN LÍMITES", "БЕЗЛІМІТ") }
    var customizationTitle: String { text("PROFILE CUSTOMIZATION", "КАСТОМИЗАЦИЯ ПРОФИЛЯ", "PERSONALIZA TU PERFIL", "КАСТОМІЗАЦІЯ ПРОФІЛЮ") }
    var statisticsTitle: String { text("GAME STATISTICS", "СТАТИСТИКА ИГР", "ESTADÍSTICAS DE JUEGO", "СТАТИСТИКА ІГОР") }
    var statisticsDetail: String { text("Full match history, win rates, roles and advanced analytics.", "Полная история матчей, процент побед, роли и расширенная аналитика.", "Historial completo, porcentaje de victorias, roles y análisis avanzado.", "Повна історія матчів, відсоток перемог, ролі й розширена аналітика.") }
    var subtitle: String { text("More ways to play. One SpyClash account.", "Больше возможностей для игры. Один аккаунт SpyClash.", "Más formas de jugar. Una cuenta SpyClash.", "Більше можливостей для гри. Один акаунт SpyClash.") }
    var ai: String { text("Unlimited AI word-pack generations", "Генерация наборов ИИ без дневного лимита", "Generaciones de paquetes con IA sin límite diario", "Генерація наборів ШІ без денного ліміту") }
    var customization: String { text("Premium avatars and Spycard styles", "Премиальные аватары и оформление Spycard", "Avatares y estilos Spycard premium", "Преміальні аватари й оформлення Spycard") }
    var history: String { text("Full match history", "Полная история матчей", "Historial completo de partidas", "Повна історія матчів") }
    var statistics: String { text("Advanced game statistics", "Расширенная статистика игр", "Estadísticas avanzadas", "Розширена статистика ігор") }
    var active: String { text("LIMITLESS is active", "LIMITLESS активен", "LIMITLESS activo", "LIMITLESS активний") }
    var included: String { text("Full access is already included — no purchase needed.", "Полный доступ уже включён — покупка не нужна.", "El acceso completo ya está incluido. No necesitas comprar.", "Повний доступ уже включено — купівля не потрібна.") }
    var until: String { text("Access until", "Доступ до", "Acceso hasta", "Доступ до") }
    var checking: String { text("Checking access…", "Проверяем доступ…", "Verificando acceso…", "Перевіряємо доступ…") }
    var unavailable: String { text("Access could not be checked. Please retry before purchasing.", "Не удалось проверить доступ. Повтори проверку перед покупкой.", "No se pudo verificar el acceso. Reintenta antes de comprar.", "Не вдалося перевірити доступ. Повтори перевірку перед купівлею.") }
    var retry: String { text("Retry", "Повторить", "Reintentar", "Повторити") }
    var freeAllowance: String { text("FREE: 10 AI generations per day and your 5 latest matches.", "FREE: 10 генераций ИИ в день и 5 последних матчей.", "FREE: 10 generaciones de IA al día y tus 5 últimas partidas.", "FREE: 10 генерацій ШІ на день і 5 останніх матчів.") }
    var remaining: String { text("AI generations remaining today", "Осталось генераций ИИ сегодня", "Generaciones de IA restantes hoy", "Залишилось генерацій ШІ сьогодні") }
    var week: String { text("week", "неделю", "semana", "тиждень") }
    var subscribe: String { text("Subscribe with Apple", "Оформить через Apple", "Suscribirse con Apple", "Оформити через Apple") }
    var restore: String { text("Restore purchases", "Восстановить покупки", "Restaurar compras", "Відновити покупки") }
    var manage: String { text("Manage Apple subscription", "Управлять подпиской Apple", "Gestionar suscripción de Apple", "Керувати підпискою Apple") }
    var notAvailableYet: String { text("New subscriptions are currently unavailable.", "Оформление новых подписок пока недоступно.", "Las nuevas suscripciones no están disponibles.", "Оформлення нових підписок поки недоступне.") }
    var renewal: String { text("Weekly auto-renewable subscription. Apple charges your account after confirmation. It renews unless cancelled at least 24 hours before the current period ends. Manage or cancel in your Apple account settings.", "Еженедельная подписка с автопродлением. Apple спишет оплату после подтверждения. Подписка продлевается, если не отменить её минимум за 24 часа до конца периода. Управление и отмена — в настройках аккаунта Apple.", "Suscripción semanal con renovación automática. Apple cobra tras confirmar. Se renueva salvo que la canceles al menos 24 horas antes del fin del período. Gestiona o cancela en tu cuenta de Apple.", "Щотижнева підписка з автоподовженням. Apple спише оплату після підтвердження. Підписка подовжується, якщо не скасувати її щонайменше за 24 години до кінця періоду. Керування й скасування — у налаштуваннях акаунта Apple.") }
    var privacy: String { text("Privacy", "Конфиденциальность", "Privacidad", "Конфіденційність") }
    var terms: String { text("Terms", "Условия", "Condiciones", "Умови") }
    var deletionNotice: String { text("Deleting your SpyClash account does not cancel an Apple subscription. Cancel it in your Apple account settings.", "Удаление аккаунта SpyClash не отменяет подписку Apple. Отмени её в настройках аккаунта Apple.", "Eliminar tu cuenta SpyClash no cancela la suscripción de Apple. Cancélala en los ajustes de tu cuenta Apple.", "Видалення акаунта SpyClash не скасовує підписку Apple. Скасуй її в налаштуваннях акаунта Apple.") }
    var processing: String { text("Processing with Apple and verifying access…", "Обрабатываем покупку Apple и проверяем доступ…", "Procesando con Apple y verificando acceso…", "Обробляємо купівлю Apple й перевіряємо доступ…") }
    var pending: String { text("Awaiting Apple's purchase approval. Access will update after confirmation.", "Ожидаем одобрения покупки Apple. Доступ обновится после подтверждения.", "Esperando aprobación de Apple. El acceso se actualizará tras confirmar.", "Очікуємо схвалення купівлі Apple. Доступ оновиться після підтвердження.") }
    var synchronized: String { text("Purchase verified. Access synchronized.", "Покупка проверена. Доступ синхронизирован.", "Compra verificada. Acceso sincronizado.", "Купівлю перевірено. Доступ синхронізовано.") }
    var noPurchases: String { text("No active Apple purchase was found for this account.", "Активная покупка Apple для этого аккаунта не найдена.", "No se encontró una compra activa de Apple para esta cuenta.", "Активну купівлю Apple для цього акаунта не знайдено.") }
    var failed: String { text("The operation could not be verified. Retry or restore purchases. You will not be charged again by Restore.", "Не удалось подтвердить операцию. Повтори попытку или восстанови покупки. Восстановление не списывает оплату повторно.", "No se pudo verificar la operación. Reintenta o restaura las compras. Restaurar no vuelve a cobrar.", "Не вдалося підтвердити операцію. Повтори спробу або віднови покупки. Відновлення не списує оплату повторно.") }
}

private struct LimitlessCommandButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(SpyTheme.red, in: CutCornerShape(cut: 10))
            .overlay {
                CutCornerShape(cut: 10)
                    .stroke(Color.white.opacity(configuration.isPressed ? 0.16 : 0), lineWidth: 1)
            }
            .contentShape(CutCornerShape(cut: 10))
            .shadow(color: SpyTheme.red.opacity(configuration.isPressed ? 0.16 : 0.30), radius: configuration.isPressed ? 8 : 18, y: 8)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(isEnabled ? 1 : 0.55)
            .animation(.smooth(duration: 0.18), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.18), value: isEnabled)
    }
}
