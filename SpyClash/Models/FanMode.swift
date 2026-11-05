import Foundation

struct FanModeSettings: Codable, Equatable, Hashable {
    var isEnabled = false
    var allSpiesChance = 15
    var noSpiesChance = 15

    var normalized: Self {
        let all = min(max(allSpiesChance, 0), 99)
        return Self(isEnabled: isEnabled, allSpiesChance: all,
                    noSpiesChance: min(max(noSpiesChance, 0), min(99, 100 - all)))
    }
    var standardChance: Int { 100 - normalized.allSpiesChance - normalized.noSpiesChance }

    func scenario(roll: Int) -> FanScenario {
        let settings = normalized
        guard settings.isEnabled else { return .standard }
        let value = min(max(roll, 0), 99)
        if value < settings.allSpiesChance { return .allSpies }
        if value < settings.allSpiesChance + settings.noSpiesChance { return .noSpies }
        return .standard
    }
}

enum FanScenario: String, Codable, CaseIterable {
    case standard
    case allSpies = "all_spies"
    case noSpies = "no_spies"

    static let concepts: [Self] = [.allSpies, .noSpies]
    var voteTarget: String {
        switch self {
        case .standard: ""
        case .allSpies: "__fan_all_spies__"
        case .noSpies: "__fan_no_spies__"
        }
    }
    var localTarget: Int { self == .allSpies ? -1 : -2 }
    init?(voteTarget: String) {
        guard let value = Self.concepts.first(where: { $0.voteTarget == voteTarget }) else { return nil }
        self = value
    }
    init?(localTarget: Int) {
        guard let value = Self.concepts.first(where: { $0.localTarget == localTarget }) else { return nil }
        self = value
    }
    func title(_ language: AppLanguage) -> String {
        let copy = FanModeCopy(language: language)
        switch self {
        case .standard: return copy.text("ONE SPY", "ОДИН ШПИОН", "UN ESPÍA", "ОДИН ШПИГУН")
        case .allSpies: return copy.text("EVERYONE IS A SPY", "ВСЕ — ШПИОНЫ", "TODOS SON ESPÍAS", "УСІ — ШПИГУНИ")
        case .noSpies: return copy.text("NO SPIES", "ШПИОНОВ НЕТ", "NO HAY ESPÍAS", "ШПИГУНІВ НЕМАЄ")
        }
    }
}

enum FanVoteDecision: Equatable {
    case pending
    case cancelled
    case player(Int)
    case concept(FanScenario)
}

/// FAN thresholds never depend on the secret assignment, so voting cannot expose it.
enum FanVotePolicy {
    static func appending(voter: Int, target: Int, active: [Int], votes: [LocalPrivateVote]) -> [LocalPrivateVote]? {
        guard active.contains(voter), !votes.contains(where: { $0.voterIndex == voter }),
              (active.contains(target) && voter != target) || FanScenario(localTarget: target) != nil else { return nil }
        return votes + [LocalPrivateVote(voterIndex: voter, targetIndex: target)]
    }
    static func decision(active: [Int], votes: [LocalPrivateVote]) -> FanVoteDecision {
        let eligible = Set(active)
        guard eligible.count >= 2 else { return .cancelled }
        var seen = Set<Int>()
        let valid = votes.filter {
            eligible.contains($0.voterIndex) &&
            (($0.targetIndex != $0.voterIndex && eligible.contains($0.targetIndex)) || FanScenario(localTarget: $0.targetIndex) != nil) &&
            seen.insert($0.voterIndex).inserted
        }
        let counts = Dictionary(grouping: valid, by: \.targetIndex).mapValues(\.count)
        for concept in FanScenario.concepts where counts[concept.localTarget] == eligible.count {
            return .concept(concept)
        }
        for player in active where (counts[player] ?? 0) >= eligible.count - 1 {
            return .player(player)
        }
        return valid.count == eligible.count ? .cancelled : .pending
    }
}

extension GameRoom {
    var fanSettings: FanModeSettings {
        FanModeSettings(isEnabled: fanModeEnabled ?? false, allSpiesChance: fanAllSpiesChance ?? 15,
                        noSpiesChance: fanNoSpiesChance ?? 15).normalized
    }
}

struct FanModeCopy {
    let language: AppLanguage
    func text(_ en: String, _ ru: String, _ es: String, _ uk: String) -> String {
        switch language {
        case .en: en
        case .ru: ru
        case .es: es
        case .uk: uk
        }
    }
    var rules: String {
        text("The system may change the roles. Accuse one player, or unanimously choose a concept. A correct concept wins for everyone; a wrong one loses to the system. Split votes continue the round. Word guessing and teammate reveal are disabled.",
             "Система может подменить роли. Обвините игрока или единогласно выберите версию. Верная версия — победа всех, неверная — победа системы. При разногласии раунд продолжается. Угадывание слова и раскрытие союзников отключены.",
             "El sistema puede cambiar los roles. Acusad a alguien o elegid un concepto por unanimidad. Un concepto correcto da la victoria a todos; uno incorrecto, al sistema. Sin acuerdo, continúa la ronda. No se puede adivinar la palabra ni ver aliados.",
             "Система може підмінити ролі. Звинуватьте гравця або одностайно оберіть версію. Правильна версія — перемога всіх, хибна — системи. Без згоди раунд триває. Вгадування слова й розкриття союзників вимкнено.")
    }
    var unanimity: String { text("CONCEPTS REQUIRE EVERY VOTE", "ДЛЯ ВЕРСИИ НУЖНЫ ВСЕ ГОЛОСА", "LOS CONCEPTOS REQUIEREN UNANIMIDAD", "ДЛЯ ВЕРСІЇ ПОТРІБНІ ВСІ ГОЛОСИ") }
    func result(won: Bool) -> String {
        won ? text("SYSTEM OUTSMARTED", "СИСТЕМА РАЗГАДАНА", "SISTEMA DESCIFRADO", "СИСТЕМУ РОЗГАДАНО")
            : text("SYSTEM WINS", "СИСТЕМА ПОБЕДИЛА", "GANA EL SISTEMA", "СИСТЕМА ПЕРЕМОГЛА")
    }
}
