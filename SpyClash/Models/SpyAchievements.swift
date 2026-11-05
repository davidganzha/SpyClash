import Foundation

struct SpyAchievementProgress: Codable, Equatable, Identifiable {
    let id: String
    let progress: Int
    let target: Int

    var boundedProgress: Int { min(max(0, progress), max(1, target)) }
    var isUnlocked: Bool { target > 0 && progress >= target }
    var fraction: Double { Double(boundedProgress) / Double(max(1, target)) }
}

enum SpyAchievementID: String, CaseIterable, Identifiable {
    case firstMission = "first_mission"
    case fieldAgent = "field_agent"
    case veteran
    case firstVictory = "first_victory"
    case winningRecord = "winning_record"
    case ghost
    case masterOfDisguise = "master_of_disguise"
    case sharpEye = "sharp_eye"
    case caseClosed = "case_closed"
    case doubleAgent = "double_agent"
    case loyalty3 = "loyalty_3"
    case loyalty6 = "loyalty_6"
    case loyalty12 = "loyalty_12"

    var id: String { rawValue }

    var target: Int {
        switch self {
        case .firstMission, .firstVictory, .ghost, .sharpEye: 1
        case .fieldAgent, .winningRecord, .masterOfDisguise, .caseClosed: 10
        case .veteran: 50
        case .doubleAgent: 5
        case .loyalty3: 3
        case .loyalty6: 6
        case .loyalty12: 12
        }
    }

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .firstMission: text(language, "First mission", "Первый выход", "Primera misión", "Перша місія")
        case .fieldAgent: text(language, "Field agent", "Полевой агент", "Agente de campo", "Польовий агент")
        case .veteran: text(language, "Veteran", "Ветеран", "Veterano", "Ветеран")
        case .firstVictory: text(language, "Mission complete", "Миссия выполнена", "Misión cumplida", "Місію виконано")
        case .winningRecord: text(language, "On a mission", "На задании", "En una misión", "На завданні")
        case .ghost: text(language, "Ghost", "Призрак", "Fantasma", "Привид")
        case .masterOfDisguise: text(language, "Master of disguise", "Мастер маскировки", "Maestro del disfraz", "Майстер маскування")
        case .sharpEye: text(language, "Sharp eye", "Зоркий глаз", "Ojo avizor", "Пильне око")
        case .caseClosed: text(language, "Case closed", "Дело закрыто", "Caso cerrado", "Справу закрито")
        case .doubleAgent: text(language, "Double agent", "Двойной агент", "Agente doble", "Подвійний агент")
        case .loyalty3: "Loyalty I"
        case .loyalty6: "Loyalty II"
        case .loyalty12: "Loyalty III"
        }
    }

    func requirement(_ language: AppLanguage) -> String {
        switch self {
        case .firstMission, .fieldAgent, .veteran:
            text(language, "Complete \(target) online games", "Завершить онлайн-игры: \(target)", "Completa \(target) partidas en línea", "Завершити онлайн-ігри: \(target)")
        case .firstVictory, .winningRecord:
            text(language, "Win \(target) online games", "Победить в онлайн-играх: \(target)", "Gana \(target) partidas en línea", "Перемогти в онлайн-іграх: \(target)")
        case .ghost, .masterOfDisguise:
            text(language, "Win \(target) times as a spy", "Победы за шпиона: \(target)", "Gana \(target) veces como espía", "Перемоги за шпигуна: \(target)")
        case .sharpEye, .caseClosed:
            text(language, "Win \(target) times as a detective", "Победы за детектива: \(target)", "Gana \(target) veces como detective", "Перемоги за детектива: \(target)")
        case .doubleAgent:
            text(language, "Win 5 times in each role", "По 5 побед в каждой роли", "Gana 5 veces en cada rol", "По 5 перемог у кожній ролі")
        case .loyalty3, .loyalty6, .loyalty12:
            text(language,
                 "Make \(target) subscription payments. Includes the first paid purchase and paid renewals; excludes free trials and restores.",
                 "Оплатить подписку \(target) \(target == 3 ? "раза" : "раз"). Считаются первая покупка и платные продления; пробный период и восстановление не учитываются.",
                 "Realiza \(target) pagos de la suscripción. Incluye la primera compra y las renovaciones de pago; excluye pruebas gratuitas y restauraciones.",
                 "Оплатити підписку \(target) \(target == 3 ? "рази" : "разів"). Враховуються перша покупка й платні продовження; пробний період і відновлення не враховуються.")
        }
    }

    private func text(_ language: AppLanguage, _ en: String, _ ru: String, _ es: String, _ uk: String) -> String {
        switch language {
        case .ru: ru
        case .es: es
        case .uk: uk
        default: en
        }
    }
}

enum SpyAchievementCatalog {
    /// The fallback uses already-authoritative public statistics from older servers.
    /// New servers also include unranked multiplayer and FAN missions in their awards.
    static func progress(games: Int, wins: Int, spyWins: Int, detectiveWins: Int) -> [SpyAchievementProgress] {
        SpyAchievementID.allCases.map { achievement in
            let value: Int
            switch achievement {
            case .firstMission, .fieldAgent, .veteran: value = games
            case .firstVictory, .winningRecord: value = wins
            case .ghost, .masterOfDisguise: value = spyWins
            case .sharpEye, .caseClosed: value = detectiveWins
            case .doubleAgent: value = min(spyWins, detectiveWins)
            // Payment awards are supplied only by the verified server ledger.
            case .loyalty3, .loyalty6, .loyalty12: value = 0
            }
            return SpyAchievementProgress(id: achievement.id, progress: min(max(0, value), achievement.target), target: achievement.target)
        }
    }

    static func normalized(_ remote: [SpyAchievementProgress]) -> [SpyAchievementProgress] {
        SpyAchievementID.allCases.map { achievement in
            let value = remote.first { $0.id == achievement.id }?.progress ?? 0
            return SpyAchievementProgress(id: achievement.id, progress: min(max(0, value), achievement.target), target: achievement.target)
        }
    }
}

extension PublicSpyProfile {
    var achievementProgress: [SpyAchievementProgress] {
        if let achievements { return SpyAchievementCatalog.normalized(achievements) }
        return SpyAchievementCatalog.progress(games: gamesPlayed, wins: gamesWon, spyWins: spyGamesWon, detectiveWins: detectiveGamesWon)
    }
}
