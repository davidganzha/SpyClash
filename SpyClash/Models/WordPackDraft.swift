import Foundation

enum WordPackCreationMethod: String, Hashable {
    case ai
    case manual
}

struct WordPackDraft: Equatable {
    var name: String
    var category: String
    var wordsText: String
    private(set) var excludedWordKeys: Set<String> = []

    init(name: String = "", category: String = "", wordsText: String = "") {
        self.name = name
        self.category = category
        self.wordsText = wordsText
    }

    init(pack: WordPack) {
        name = pack.name
        category = pack.category ?? ""
        wordsText = (pack.words ?? []).joined(separator: "\n")
    }

    var normalizedName: String {
        WordPackDraftNormalizer.normalizedField(name)
    }

    var normalizedCategory: String {
        WordPackDraftNormalizer.normalizedField(category)
    }

    var wordAnalysis: WordPackWordAnalysis {
        WordPackDraftNormalizer.analyzeWords(wordsText)
    }

    var selectedWords: [String] {
        wordAnalysis.words.filter { !excludedWordKeys.contains(Self.wordKey($0)) }
    }

    var isValid: Bool {
        !normalizedName.isEmpty && selectedWords.count >= 2
    }

    var hasContent: Bool {
        !normalizedName.isEmpty || !normalizedCategory.isEmpty || !wordAnalysis.words.isEmpty
    }

    mutating func applyGenerated(_ generated: GeneratedWordPack, fallbackName: String) {
        let generatedName = generated.name?.nilIfBlank ?? fallbackName
        name = generatedName
        category = generated.category.nilIfBlank ?? generatedName
        wordsText = generated.words.joined(separator: "\n")
        excludedWordKeys.removeAll()
    }

    func isWordSelected(_ word: String) -> Bool {
        !excludedWordKeys.contains(Self.wordKey(word))
    }

    mutating func toggleWord(_ word: String) {
        let key = Self.wordKey(word)
        guard wordAnalysis.words.contains(where: { Self.wordKey($0) == key }) else { return }
        if !excludedWordKeys.insert(key).inserted {
            excludedWordKeys.remove(key)
        }
    }

    mutating func addWords(_ input: String) {
        let additions = WordPackDraftNormalizer.analyzeWords(input).words
        guard !additions.isEmpty else { return }
        wordsText = ([wordsText] + additions).joined(separator: "\n")
        excludedWordKeys.subtract(additions.map(Self.wordKey))
    }

    private static func wordKey(_ word: String) -> String {
        WordPackDraftNormalizer.normalizedField(word).lowercased()
    }
}

struct WordPackWordAnalysis: Equatable {
    let words: [String]
    let duplicateCount: Int
    let shortenedCount: Int
}

enum WordPackDraftNormalizer {
    static let fieldLimit = 80
    static let gameplayWordLimit = 200

    static func normalizedField(_ value: String) -> String {
        String(collapsedWhitespace(value).prefix(fieldLimit))
    }

    static func limitedFieldInput(_ value: String) -> String {
        let collapsed = collapsedWhitespace(value)
        guard collapsed.count > fieldLimit else { return value }
        return String(collapsed.prefix(fieldLimit))
    }

    static func analyzeWords(_ text: String) -> WordPackWordAnalysis {
        var words: [String] = []
        var seen = Set<String>()
        var duplicateCount = 0
        var shortenedCount = 0

        for rawEntry in text.components(separatedBy: CharacterSet(charactersIn: ",;\n")) {
            let collapsed = collapsedWhitespace(rawEntry)
            guard !collapsed.isEmpty else { continue }

            let normalized = String(collapsed.prefix(fieldLimit))
            if collapsed.count > fieldLimit {
                shortenedCount += 1
            }

            let key = normalized.lowercased()
            guard !seen.contains(key) else {
                duplicateCount += 1
                continue
            }
            seen.insert(key)
            words.append(normalized)
        }

        return WordPackWordAnalysis(
            words: words,
            duplicateCount: duplicateCount,
            shortenedCount: shortenedCount
        )
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        let sanitizedScalars = value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()

        return sanitizedScalars
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WordPackRecommendedCountPolicy {
    static let defaultCount = 30
    static let generationRequestLimit = 100

    static func requestCount(for theme: String) -> Int {
        isCountriesTheme(theme) ? generationRequestLimit : defaultCount
    }

    static func selectedCount(for theme: String, availableCount: Int) -> Int {
        min(max(availableCount, 0), requestCount(for: theme))
    }

    static func isCountriesTheme(_ theme: String) -> Bool {
        countriesThemes.contains(normalizedTheme(theme))
    }

    private static let countriesThemes: Set<String> = Set([
        "countries",
        "european countries",
        "страны",
        "страны европы",
        "країни",
        "країни європи",
        "paises",
        "paises de europa"
    ].map(normalizedTheme))

    private static func normalizedTheme(_ theme: String) -> String {
        theme
            .precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LobbyRecommendedCountMigrationPolicy {
    static func applies(to source: LobbyWordSource) -> Bool {
        source == .ai || source == .manual
    }

    static func normalizedCount(
        for theme: String,
        authoritativeCount: Int,
        availableCount: Int
    ) -> Int {
        WordPackRecommendedCountPolicy.selectedCount(
            for: theme,
            availableCount: availableCount > 0
                ? availableCount
                : max(authoritativeCount, 0)
        )
    }

    static func requiresServerSync(
        authoritativeCount: Int,
        normalizedCount: Int
    ) -> Bool {
        max(authoritativeCount, 0) != max(normalizedCount, 0)
    }
}

struct WordPackAIGenerationSignature: Equatable {
    let theme: String
    let count: Int
}

struct WordPackAIGenerationRequest: Equatable {
    let id: UUID
    let signature: WordPackAIGenerationSignature
}
