import SwiftUI

struct LimitlessSheet: Identifiable { let id = "limitless" }

struct PricingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var access: MembershipStore { appState.membership }
    private var store: StoreKitManager { appState.storeKit }
    private var copy: LimitlessCopy { LimitlessCopy(language: appState.language) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("SPYCLASH / ACCESS").font(SpyTheme.micro).foregroundStyle(SpyTheme.muted)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(copy.close)
                    .accessibilityIdentifier("limitless.close")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "infinity")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(SpyTheme.red)
                    Text("LIMITLESS")
                        .font(.system(size: 42, weight: .black, design: .monospaced))
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text(copy.subtitle).font(.subheadline).foregroundStyle(SpyTheme.muted)
                }
                SpyPanel {
                    VStack(alignment: .leading, spacing: 18) {
                        benefit("sparkles", copy.ai)
                        benefit("person.crop.square", copy.customization)
                        benefit("clock.arrow.circlepath", copy.history)
                        benefit("chart.bar.xaxis", copy.statistics)
                    }
                }
                accessControls
                if let message = stateMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(store.state == .failed ? SpyTheme.red : SpyTheme.muted)
                        .accessibilityIdentifier("limitless.status")
                }
                if access.snapshot?.isUniversal != true {
                    Button(copy.restore) { Task { await store.restore() } }
                        .buttonStyle(SpyButtonStyle(variant: .outline))
                        .disabled(store.state.isBusy || access.isPreview)
                        .accessibilityIdentifier("limitless.restore")
                    if access.snapshot?.providers.contains("apple") == true {
                        Button(copy.manage) {
                            Task {
                                do { try await store.manageSubscriptions() }
                                catch { appState.showToast(copy.unavailable, kind: .error) }
                            }
                        }
                        .buttonStyle(SpyButtonStyle(variant: .ghost))
                    }
                    Text(copy.renewal).font(.caption).foregroundStyle(SpyTheme.muted)
                    HStack(spacing: 18) {
                        Link(copy.privacy, destination: URL(string: "https://spyclash.com/PrivacyPolicy")!)
                        Link(copy.terms, destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    }
                    .font(.caption)
                }
            }
            .padding(24)
        }
        .background(SpyBackground())
        .task {
            _ = await access.refresh()
            if access.canPurchase { await store.loadProduct() }
        }
        .onChange(of: access.canPurchase) { _, canPurchase in
            if canPurchase { Task { await store.loadProduct() } }
        }
        .accessibilityIdentifier("limitless.screen")
    }

    @ViewBuilder
    private var accessControls: some View {
        if access.snapshot?.isUniversal == true {
            Label(copy.included, systemImage: "checkmark.shield.fill")
                .foregroundStyle(SpyTheme.green)
        } else if access.hasAccess {
            Label(copy.active, systemImage: "checkmark.shield.fill")
                .foregroundStyle(SpyTheme.green)
            if let expiry = access.snapshot?.expiresAt {
                Text("\(copy.until) \(expiry.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote).foregroundStyle(SpyTheme.muted)
            }
        } else if access.isLoading {
            ProgressView(copy.checking).tint(SpyTheme.red)
        } else if access.snapshot == nil || access.errorMessage != nil {
            Text(copy.unavailable).font(.footnote).foregroundStyle(SpyTheme.muted)
            Button(copy.retry) { Task { _ = await access.refresh() } }
                .buttonStyle(SpyButtonStyle(variant: .outline))
        } else {
            Text(copy.freeAllowance).font(.footnote).foregroundStyle(SpyTheme.muted)
            if let remaining = access.snapshot?.aiRemaining {
                Text("\(copy.remaining): \(remaining)").font(.footnote).foregroundStyle(SpyTheme.muted)
            }
            if access.canPurchase, let product = store.product {
                Text("\(product.displayPrice) / \(copy.week)")
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                Button(copy.subscribe) { Task { await store.purchase(membership: access) } }
                    .buttonStyle(SpyButtonStyle(variant: .red))
                    .disabled(!store.canPurchase || store.state.isBusy)
                    .accessibilityIdentifier("limitless.purchase")
            } else if store.isLoadingProduct {
                ProgressView(copy.checking)
            } else {
                Text(copy.notAvailableYet).font(.footnote).foregroundStyle(SpyTheme.muted)
                if access.canPurchase {
                    Button(copy.retry) { Task { await store.loadProduct() } }
                        .buttonStyle(SpyButtonStyle(variant: .outline))
                }
            }
        }
    }

    private func benefit(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.subheadline).foregroundStyle(.white)
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
