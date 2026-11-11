import Foundation

struct FanModeSettings: Codable, Equatable, Hashable {
    var isEnabled = false
    var allSpiesChance = 15
    var noSpiesChance = 15
    var splitWordsChance = 0
    var uniqueWordsChance = 0
    var loneCivilianChance = 0

    init(isEnabled: Bool = false, allSpiesChance: Int = 15, noSpiesChance: Int = 15,
         splitWordsChance: Int = 0, uniqueWordsChance: Int = 0, loneCivilianChance: Int = 0) {
        self.isEnabled = isEnabled
        self.allSpiesChance = allSpiesChance
        self.noSpiesChance = noSpiesChance
        self.splitWordsChance = splitWordsChance
        self.uniqueWordsChance = uniqueWordsChance
        self.loneCivilianChance = loneCivilianChance
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        allSpiesChance = try values.decodeIfPresent(Int.self, forKey: .allSpiesChance) ?? 15
        noSpiesChance = try values.decodeIfPresent(Int.self, forKey: .noSpiesChance) ?? 15
        splitWordsChance = try values.decodeIfPresent(Int.self, forKey: .splitWordsChance) ?? 0
        uniqueWordsChance = try values.decodeIfPresent(Int.self, forKey: .uniqueWordsChance) ?? 0
        loneCivilianChance = try values.decodeIfPresent(Int.self, forKey: .loneCivilianChance) ?? 0
    }

    var normalized: Self {
        var result = self
        var remaining = 100
        for scenario in FanScenario.surprises {
            let value = min(max(chance(for: scenario), 0), min(99, remaining))
            result.assignChance(value, for: scenario)
            remaining -= value
        }
        return result
    }

    var standardChance: Int {
        let settings = normalized
        return 100 - FanScenario.surprises.reduce(0) { $0 + settings.chance(for: $1) }
    }

    func chance(for scenario: FanScenario) -> Int {
        switch scenario {
        case .standard: standardChance
        case .allSpies: allSpiesChance
        case .noSpies: noSpiesChance
        case .splitWords: splitWordsChance
        case .uniqueWords: uniqueWordsChance
        case .loneCivilian: loneCivilianChance
        }
    }

    /// The moved slider keeps its value; other chances fit into the remaining budget.
    mutating func setChance(_ value: Int, for scenario: FanScenario) {
        guard scenario != .standard else { return }
        self = normalized
        let selected = min(max(value, 0), 99)
        assignChance(selected, for: scenario)
        var remaining = 100 - selected
        for other in FanScenario.surprises where other != scenario {
            let next = min(chance(for: other), remaining)
            assignChance(next, for: other)
            remaining -= next
        }
    }

    private mutating func assignChance(_ value: Int, for scenario: FanScenario) {
        switch scenario {
        case .standard: break
        case .allSpies: allSpiesChance = value
        case .noSpies: noSpiesChance = value
        case .splitWords: splitWordsChance = value
        case .uniqueWords: uniqueWordsChance = value
        case .loneCivilian: loneCivilianChance = value
        }
    }

    func scenario(roll: Int) -> FanScenario {
        let settings = normalized
        guard settings.isEnabled else { return .standard }
        let value = min(max(roll, 0), 99)
        var threshold = 0
        for scenario in FanScenario.surprises {
            threshold += settings.chance(for: scenario)
            if value < threshold { return scenario }
        }
        return .standard
    }
}

enum FanScenario: String, Codable, CaseIterable {
    case standard
    case allSpies = "all_spies"
    case noSpies = "no_spies"
    case splitWords = "split_words"
    case uniqueWords = "unique_words"
    case loneCivilian = "lone_civilian"

    static let surprises: [Self] = [.allSpies, .noSpies, .splitWords, .uniqueWords, .loneCivilian]
    var hasPersonalWords: Bool { self == .splitWords || self == .uniqueWords }

    func title(_ language: AppLanguage) -> String {
        let copy = FanModeCopy(language: language)
        switch self {
        case .standard: return copy.text("ONE SPY", "ОДИН ШПИОН", "UN ESPÍA", "ОДИН ШПИГУН")
        case .allSpies: return copy.text("EVERYONE IS A SPY", "ВСЕ — ШПИОНЫ", "TODOS SON ESPÍAS", "УСІ — ШПИГУНИ")
        case .noSpies: return copy.text("NO SPIES", "ШПИОНОВ НЕТ", "NO HAY ESPÍAS", "ШПИГУНІВ НЕМАЄ")
        case .splitWords: return copy.text("TWO WORDS, TWO HALVES", "ДВА СЛОВА НА ДВЕ ПОЛОВИНЫ", "DOS PALABRAS, DOS MITADES", "ДВА СЛОВА НА ДВІ ПОЛОВИНИ")
        case .uniqueWords: return copy.text("A DIFFERENT WORD FOR EVERYONE", "У ВСЕХ РАЗНЫЕ СЛОВА", "UNA PALABRA DISTINTA PARA CADA UNO", "В УСІХ РІЗНІ СЛОВА")
        case .loneCivilian: return copy.text("ALL SPIES EXCEPT ONE", "ВСЕ ШПИОНЫ, КРОМЕ ОДНОГО", "TODOS ESPÍAS SALVO UNO", "УСІ ШПИГУНИ, КРІМ ОДНОГО")
        }
    }
}

struct FanDeal: Equatable {
    let spyIndices: [Int]
    let playerWords: [Int: String]
}

enum FanDealPolicy {
    static func distinctWords(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.compactMap { raw in
            let word = raw.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { return nil }
            return word
        }
    }

    /// Returns nil rather than repeating words when the requested deal is impossible.
    static func deal(scenario: FanScenario, playerCount: Int, word: String, pool: [String],
                     standardSpyCount: Int = 1) -> FanDeal? {
        guard playerCount >= 2 else { return nil }
        let words = distinctWords([word] + pool)
        guard let mainWord = words.first, !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let indices = Array(0..<playerCount).shuffled()
        let spyIndices: [Int]
        var assignedWords: [Int: String] = [:]
        switch scenario {
        case .allSpies:
            spyIndices = Array(0..<playerCount)
        case .noSpies:
            spyIndices = []
        case .loneCivilian:
            spyIndices = Array(indices.dropFirst()).sorted()
        case .standard:
            spyIndices = Array(indices.prefix(min(max(standardSpyCount, 1), playerCount - 1))).sorted()
        case .splitWords:
            guard words.count >= 2, let otherWord = words.dropFirst().randomElement() else { return nil }
            let pair = [mainWord, otherWord].shuffled()
            for (offset, player) in indices.enumerated() {
                assignedWords[player] = pair[offset < playerCount / 2 ? 0 : 1]
            }
            return FanDeal(spyIndices: [], playerWords: assignedWords)
        case .uniqueWords:
            guard words.count >= playerCount else { return nil }
            let selected = ([mainWord] + Array(words.dropFirst().shuffled().prefix(playerCount - 1))).shuffled()
            for (player, assignedWord) in zip(indices, selected) { assignedWords[player] = assignedWord }
            return FanDeal(spyIndices: [], playerWords: assignedWords)
        }
        let spies = Set(spyIndices)
        for player in 0..<playerCount where !spies.contains(player) { assignedWords[player] = mainWord }
        return FanDeal(spyIndices: spyIndices, playerWords: assignedWords)
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
                        noSpiesChance: fanNoSpiesChance ?? 15,
                        splitWordsChance: fanSplitWordsChance ?? 0,
                        uniqueWordsChance: fanUniqueWordsChance ?? 0,
                        loneCivilianChance: fanLoneCivilianChance ?? 0).normalized
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
        text("Roles and words may hide a surprise. Play normally and vote for a player. The first ejection reveals a surprise round and ends it in a draw. When time runs out, keep voting until someone is ejected. Word guessing and teammate reveal are disabled.",
             "В ролях и словах может скрываться сюрприз. Играйте и голосуйте за игрока. Первое исключение раскрывает необычную раздачу и завершает её ничьей. Когда время выйдет, голосуйте до исключения. Угадывание слова и раскрытие союзников отключены.",
             "Los roles y las palabras pueden esconder una sorpresa. Jugad y votad por un jugador. La primera expulsión revela una ronda sorpresa y la termina en empate. Al agotarse el tiempo, seguid votando hasta expulsar a alguien. No se puede adivinar la palabra ni ver aliados.",
             "У ролях і словах може ховатися сюрприз. Грайте й голосуйте за гравця. Перше виключення розкриває незвичну роздачу та завершує її нічиєю. Коли час вийде, голосуйте до виключення. Вгадування слова й розкриття союзників вимкнено.")
    }
    var scenarioHint: String {
        text("Two words: no spies, two groups as equal as possible. Different words: no spies, at least one distinct active word per player is needed. All spies except one: only one player knows the word. New chances start at 0%; raise them to include these deals.",
             "Два слова: шпионов нет, группы делятся максимально поровну. Разные слова: шпионов нет, в колоде нужно хотя бы по одному уникальному активному слову на игрока. Все шпионы, кроме одного: слово знает только один игрок. Новые шансы равны 0%; увеличьте их, чтобы включить эти раздачи.",
             "Dos palabras: sin espías, dos grupos lo más iguales posible. Palabras distintas: sin espías, se necesita una palabra activa única por jugador. Todos espías salvo uno: solo uno conoce la palabra. Las nuevas opciones empiezan en 0%; aumentadlas para incluirlas.",
             "Два слова: шпигунів немає, групи діляться якомога порівну. Різні слова: шпигунів немає, у колоді потрібно хоча б по одному унікальному активному слову на гравця. Усі шпигуни, крім одного: слово знає лише один гравець. Нові шанси дорівнюють 0%; збільште їх, щоб увімкнути ці роздачі.")
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
        case .splitWords: text("YOU HAD TWO DIFFERENT WORDS", "У ВАС БЫЛО ДВА РАЗНЫХ СЛОВА", "TENÍAIS DOS PALABRAS DISTINTAS", "У ВАС БУЛО ДВА РІЗНИХ СЛОВА")
        case .uniqueWords: text("EVERYONE HAD A DIFFERENT WORD", "У КАЖДОГО БЫЛО СВОЁ СЛОВО", "CADA UNO TENÍA UNA PALABRA DISTINTA", "У КОЖНОГО БУЛО СВОЄ СЛОВО")
        case .loneCivilian: text("ONLY ONE PLAYER WAS NOT A SPY", "ТОЛЬКО ОДИН ИГРОК НЕ БЫЛ ШПИОНОМ", "SOLO UNO NO ERA ESPÍA", "ЛИШЕ ОДИН ГРАВЕЦЬ НЕ БУВ ШПИГУНОМ")
        case .standard: scenario.title(language)
        }
    }
    // Older finished rooms can still be read before the server update is deployed.
    func result(won: Bool) -> String {
        won ? text("SYSTEM OUTSMARTED", "СИСТЕМА РАЗГАДАНА", "SISTEMA DESCIFRADO", "СИСТЕМУ РОЗГАДАНО")
            : text("SYSTEM WINS", "СИСТЕМА ПОБЕДИЛА", "GANA EL SISTEMA", "СИСТЕМА ПЕРЕМОГЛА")
    }
}
