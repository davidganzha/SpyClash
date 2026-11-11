import Foundation

/// Generation access is independent of cosmetic/history membership. CASADA
/// must not accidentally turn a metered generator into unlimited access.
struct GenerationRewardStatus: Decodable, Equatable {
    let enabled: Bool
    let unlimited: Bool
    let dailyLimit: Int
    let freeRemaining: Int?
    let bonusCredits: Int
    let resetsAt: Date?
    let adAvailable: Bool
    let testAdAvailable: Bool

    var canGenerate: Bool { !enabled || unlimited || (freeRemaining ?? 0) > 0 || bonusCredits > 0 }
    var needsReward: Bool { enabled && !unlimited && !canGenerate }

    enum CodingKeys: String, CodingKey {
        case enabled, unlimited
        case dailyLimit = "daily_limit", freeRemaining = "free_remaining"
        case bonusCredits = "bonus_credits", resetsAt = "resets_at", adAvailable = "ad_available"
        case testAdAvailable = "test_ad_available"
    }

    init(enabled: Bool, unlimited: Bool, dailyLimit: Int = 3, freeRemaining: Int?, bonusCredits: Int = 0, resetsAt: Date? = nil, adAvailable: Bool, testAdAvailable: Bool = false) {
        self.enabled = enabled; self.unlimited = unlimited; self.dailyLimit = dailyLimit
        self.freeRemaining = freeRemaining; self.bonusCredits = bonusCredits
        self.resetsAt = resetsAt; self.adAvailable = adAvailable
        self.testAdAvailable = testAdAvailable
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        unlimited = try values.decodeIfPresent(Bool.self, forKey: .unlimited) ?? false
        dailyLimit = max(0, try values.decodeIfPresent(Int.self, forKey: .dailyLimit) ?? 3)
        freeRemaining = try values.decodeIfPresent(Int.self, forKey: .freeRemaining).map { max(0, $0) }
        bonusCredits = max(0, try values.decodeIfPresent(Int.self, forKey: .bonusCredits) ?? 0)
        adAvailable = try values.decodeIfPresent(Bool.self, forKey: .adAvailable) ?? false
        testAdAvailable = try values.decodeIfPresent(Bool.self, forKey: .testAdAvailable) ?? false
        if let raw = try values.decodeIfPresent(String.self, forKey: .resetsAt) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetsAt = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        } else { resetsAt = nil }
    }
}

enum GenerationRewardProvider: String, Decodable {
    case admob, unity
}

struct GenerationRewardAttempt: Decodable {
    let attemptID: UUID
    let customData: String
    let adUnitID: String
    let userID: String
    let provider: GenerationRewardProvider
    let unityGameID: String?
    let serverID: String?
    enum CodingKeys: String, CodingKey {
        case attemptID = "attempt_id", customData = "custom_data", adUnitID = "ad_unit_id", userID = "user_id"
        case provider, unityGameID = "unity_game_id", serverID = "server_id"
    }

    init(attemptID: UUID, customData: String, adUnitID: String, userID: String, provider: GenerationRewardProvider = .admob, unityGameID: String? = nil, serverID: String? = nil) {
        self.attemptID = attemptID; self.customData = customData
        self.adUnitID = adUnitID; self.userID = userID; self.provider = provider
        self.unityGameID = unityGameID; self.serverID = serverID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        attemptID = try values.decode(UUID.self, forKey: .attemptID)
        customData = try values.decode(String.self, forKey: .customData)
        adUnitID = try values.decode(String.self, forKey: .adUnitID)
        userID = try values.decode(String.self, forKey: .userID)
        // Existing AdMob servers predate the provider field. Unknown explicit
        // providers fail decoding instead of silently routing an ad elsewhere.
        provider = try values.decodeIfPresent(GenerationRewardProvider.self, forKey: .provider) ?? .admob
        unityGameID = try values.decodeIfPresent(String.self, forKey: .unityGameID)
        serverID = try values.decodeIfPresent(String.self, forKey: .serverID)
    }
}

struct GenerationRewardClaim: Decodable {
    let state: String
    let status: GenerationRewardStatus
    enum CodingKeys: String, CodingKey { case state, status }
    init(state: String, status: GenerationRewardStatus) { self.state = state; self.status = status }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = try values.decode(String.self, forKey: .state)
        status = try values.decodeIfPresent(GenerationRewardStatus.self, forKey: .status) ?? GenerationRewardStatus(from: decoder)
    }
}

enum GenerationRewardNotice: Equatable {
    case unavailable, incomplete, confirming, earned, limitReached
}

struct GenerationRewardCopy {
    let language: AppLanguage
    func text(_ en: String, _ ru: String, _ es: String, _ uk: String) -> String {
        switch language { case .en: en; case .ru: ru; case .es: es; case .uk: uk }
    }
    var title: String { text("YOUR OWN THEMES", "ТВОИ ТЕМЫ", "TUS PROPIOS TEMAS", "ТВОЇ ТЕМИ") }
    var watch: String { text("Watch an ad → +1 generation", "Посмотреть рекламу → +1 генерация", "Ver anuncio → +1 generación", "Переглянути рекламу → +1 генерація") }
    var preparing: String { text("Preparing the ad…", "Подготавливаем рекламу…", "Preparando el anuncio…", "Готуємо рекламу…") }
    var testWatch: String { text("Test an ad → +1 generation", "Проверить рекламу → +1 генерация", "Probar anuncio → +1 generación", "Перевірити рекламу → +1 генерація") }
    var testTitle: String { text("AD TEST", "ПРОВЕРКА РЕКЛАМЫ", "PRUEBA DE ANUNCIO", "ПЕРЕВІРКА РЕКЛАМИ") }
    var testDisclosure: String { text("Ad test for this account. Free generations and LIMITLESS access stay unchanged. The bonus appears after server confirmation.", "Тест рекламы для этого аккаунта. Бесплатные генерации и LIMITLESS не меняются. Бонус появится после подтверждения сервера.", "Prueba de anuncio para esta cuenta. Las generaciones gratis y LIMITLESS no cambian. El bono aparece tras la confirmación del servidor.", "Тест реклами для цього акаунта. Безкоштовні генерації та LIMITLESS не змінюються. Бонус з’явиться після підтвердження сервера.") }
    var unlimited: String { text("LIMITLESS · Unlimited generations", "LIMITLESS · Генерации без лимита", "LIMITLESS · Generaciones ilimitadas", "LIMITLESS · Генерації без ліміту") }
    var alternative: String { text("Saved packs and manual word entry remain free.", "Готовые наборы и ручной ввод слов остаются бесплатными.", "Los paquetes guardados y las palabras manuales siguen siendo gratis.", "Готові набори й ручне введення слів залишаються безкоштовними.") }
    var disclosure: String { text("Complete one rewarded ad to get one additional generation. The bonus stays until you use it.", "Заверши просмотр одной рекламы, чтобы получить одну дополнительную генерацию. Бонус сохранится до использования.", "Completa un anuncio con recompensa para obtener una generación adicional. El bono se conserva hasta usarlo.", "Заверши перегляд однієї реклами, щоб отримати одну додаткову генерацію. Бонус збережеться до використання.") }
    var privacy: String { text("Advertising privacy choices", "Настройки конфиденциальности рекламы", "Privacidad de los anuncios", "Налаштування конфіденційності реклами") }
    func free(_ remaining: Int, limit: Int) -> String {
        text("Free today: \(remaining) of \(limit)", "Бесплатно сегодня: \(remaining) из \(limit)", "Gratis hoy: \(remaining) de \(limit)", "Безкоштовно сьогодні: \(remaining) з \(limit)")
    }
    func bonus(_ count: Int) -> String { text("Additional generations: \(count)", "Дополнительных генераций: \(count)", "Generaciones adicionales: \(count)", "Додаткових генерацій: \(count)") }
    func reset(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return text("Free generations renew at \(time).", "Бесплатные генерации обновятся в \(time).", "Las generaciones gratis se renuevan a las \(time).", "Безкоштовні генерації оновляться о \(time).")
    }
    func notice(_ notice: GenerationRewardNotice) -> String {
        switch notice {
        case .unavailable: text("An ad isn't available right now. You can keep playing with saved words.", "Сейчас реклама недоступна. Можно продолжить игру с готовыми словами.", "Ahora no hay anuncios disponibles. Puedes seguir jugando con palabras guardadas.", "Зараз реклама недоступна. Можна продовжити гру з готовими словами.")
        case .incomplete: text("The ad wasn't completed. No generation was added or spent.", "Просмотр не завершён. Генерации не начислены и не списаны.", "El anuncio no se completó. No se añadió ni gastó ninguna generación.", "Перегляд не завершено. Генерації не нараховані й не списані.")
        case .confirming: text("Confirming your bonus. It will appear automatically; you don't need to watch again.", "Подтверждаем бонус. Он появится автоматически — повторно смотреть рекламу не нужно.", "Confirmando tu bono. Aparecerá automáticamente; no necesitas ver otro anuncio.", "Підтверджуємо бонус. Він з’явиться автоматично — повторно дивитися рекламу не потрібно.")
        case .earned: text("+1 generation is ready.", "+1 генерация доступна.", "+1 generación disponible.", "+1 генерація доступна.")
        case .limitReached: text("Your free generations for today are used. Watch an ad for one more, or use a saved pack.", "Бесплатные генерации на сегодня закончились. Посмотри рекламу для ещё одной или выбери готовый набор.", "Has usado las generaciones gratis de hoy. Mira un anuncio para obtener otra o usa un paquete guardado.", "Безкоштовні генерації на сьогодні закінчилися. Переглянь рекламу для ще однієї або обери готовий набір.")
        }
    }
}
