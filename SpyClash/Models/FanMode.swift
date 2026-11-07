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
}

/// FAN thresholds never depend on the secret assignment, so voting cannot expose it.
enum FanVotePolicy {
    static func appending(voter: Int, target: Int, active: [Int], votes: [LocalPrivateVote]) -> [LocalPrivateVote]? {
        guard active.contains(voter), !votes.contains(where: { $0.voterIndex == voter }),
              active.contains(target) && voter != target else { return nil }
        return votes + [LocalPrivateVote(voterIndex: voter, targetIndex: target)]
    }
    static func decision(active: [Int], votes: [LocalPrivateVote]) -> FanVoteDecision {
        let eligible = Set(active)
        guard eligible.count >= 2 else { return .cancelled }
        var seen = Set<Int>()
        let valid = votes.filter {
            eligible.contains($0.voterIndex) &&
            ($0.targetIndex != $0.voterIndex && eligible.contains($0.targetIndex)) &&
            seen.insert($0.voterIndex).inserted
        }
        let counts = Dictionary(grouping: valid, by: \.targetIndex).mapValues(\.count)
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
        text("Sometimes everyone is a spy — or nobody is. Keep playing and vote for a player. If a surprise round was drawn, the first ejection reveals it and everyone shares a draw. When time runs out, vote until someone is ejected. Word guessing and teammate reveal are disabled.",
             "Иногда шпионами становятся все — или никто. Играйте и голосуйте за игрока. Если выпал сюрприз, первое исключение раскроет его и завершит матч весёлой ничьей. Когда время выйдет, голосуйте до исключения. Угадывание слова и раскрытие союзников отключены.",
             "A veces todos son espías, o nadie lo es. Seguid jugando y votad por un jugador. Si salió una ronda sorpresa, la primera expulsión la revela y todos empatáis. Al acabarse el tiempo, votad hasta expulsar a alguien. No se puede adivinar la palabra ni ver aliados.",
             "Іноді шпигунами стають усі — або ніхто. Грайте й голосуйте за гравця. Якщо випав сюрприз, перше виключення розкриє його та завершить матч веселою нічиєю. Коли час вийде, голосуйте до виключення. Вгадування слова й розкриття союзників вимкнено.")
    }
    var scenarioHint: String {
        text("All spies: nobody knows the word. No spies: everyone knows it. The surprise stays secret until a player is ejected. No wins or losses in a surprise round.",
             "Все шпионы: никто не знает слово. Шпионов нет: слово знают все. Сюрприз остаётся тайной до исключения игрока. В таком раунде нет побед и поражений.",
             "Todos espías: nadie conoce la palabra. Sin espías: todos la conocen. La sorpresa se guarda hasta expulsar a alguien. En esa ronda no hay victorias ni derrotas.",
             "Усі шпигуни: ніхто не знає слово. Шпигунів немає: слово знають усі. Сюрприз залишається таємницею до виключення гравця. У такому раунді немає перемог і поразок.")
    }
    var ballotTitle: String { text("Choose a suspect", "Выберите подозреваемого", "Elige un sospechoso", "Оберіть підозрюваного") }
    var voteForPlayer: String { text("Vote for a player", "Голосовать за игрока", "Votar por un jugador", "Голосувати за гравця") }
    var choosePlayer: String { text("Choose a player", "Выберите игрока", "Elige un jugador", "Оберіть гравця") }
    var playerVoteHint: String { text("Tap a player to send your vote. You cannot change it afterwards.", "Нажмите на игрока, чтобы отправить голос. После этого изменить его нельзя.", "Toca a un jugador para enviar tu voto. Después no podrás cambiarlo.", "Натисніть на гравця, щоб надіслати голос. Після цього змінити його не можна.") }
    var close: String { text("Close", "Закрыть", "Cerrar", "Закрити") }
    func ballotRequirement(playerVotes: Int, total: Int) -> String {
        text("Ejection: \(playerVotes) of \(total) votes. Split votes continue the game.",
             "Для исключения: \(playerVotes) из \(total) голосов. Нет согласия — игра продолжается.",
             "Expulsión: \(playerVotes) de \(total) votos. Sin acuerdo, la partida continúa.",
             "Для виключення: \(playerVotes) з \(total) голосів. Немає згоди — гра триває.")
    }
    var drawTitle: String { text("A FUN DRAW", "ВЕСЁЛАЯ НИЧЬЯ", "UN EMPATE DIVERTIDO", "ВЕСЕЛА НІЧИЯ") }
    var drawSubtitle: String {
        text("No winners. No losers. Just a little surprise for everyone.",
             "Никто не выиграл. Никто не проиграл. Просто сюрприз для всей компании.",
             "Sin ganadores ni perdedores. Solo una sorpresa para todos.",
             "Ніхто не виграв. Ніхто не програв. Просто сюрприз для всієї компанії.")
    }
    var revealTitle: String { text("WAIT A SECOND…", "А ВОТ И СЮРПРИЗ…", "UN MOMENTO…", "А ОСЬ І СЮРПРИЗ…") }
    var revealSubtitle: String { text("Let's turn over the cards", "Переворачиваем карты", "Vamos a revelar las cartas", "Перевертаємо карти") }
    func revealedScenario(_ scenario: FanScenario) -> String {
        switch scenario {
        case .allSpies: text("EVERYONE WAS A SPY", "ВСЕ БЫЛИ ШПИОНАМИ", "TODOS ERAN ESPÍAS", "УСІ БУЛИ ШПИГУНАМИ")
        case .noSpies: text("THERE WERE NO SPIES", "ШПИОНОВ НЕ БЫЛО", "NO HABÍA ESPÍAS", "ШПИГУНІВ НЕ БУЛО")
        case .standard: scenario.title(language)
        }
    }
    // Older finished rooms can still be read before the server update is deployed.
    func result(won: Bool) -> String {
        won ? text("SYSTEM OUTSMARTED", "СИСТЕМА РАЗГАДАНА", "SISTEMA DESCIFRADO", "СИСТЕМУ РОЗГАДАНО")
            : text("SYSTEM WINS", "СИСТЕМА ПОБЕДИЛА", "GANA EL SISTEMA", "СИСТЕМА ПЕРЕМОГЛА")
    }
}
