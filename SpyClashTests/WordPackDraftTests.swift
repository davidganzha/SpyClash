import XCTest
@testable import SpyClash

final class WordPackDraftTests: XCTestCase {
    func testNormalizerMatchesServerWhitespaceSeparatorsAndOrderedDedupe() {
        let analysis = WordPackDraftNormalizer.analyzeWords(
            "  New   York,Signal; signal\nКиїв\tцентр\n  "
        )

        XCTAssertEqual(analysis.words, ["New York", "Signal", "Київ центр"])
        XCTAssertEqual(analysis.duplicateCount, 1)
        XCTAssertEqual(analysis.shortenedCount, 0)
    }

    func testNormalizerShortensBeforeDeduplicationLikeBackend() {
        let sharedPrefix = String(repeating: "a", count: WordPackDraftNormalizer.fieldLimit)
        let analysis = WordPackDraftNormalizer.analyzeWords(
            "\(sharedPrefix)first,\(sharedPrefix)second"
        )

        XCTAssertEqual(analysis.words, [sharedPrefix])
        XCTAssertEqual(analysis.duplicateCount, 1)
        XCTAssertEqual(analysis.shortenedCount, 2)
    }

    func testFieldInputDoesNotLoseMeaningfulTextAfterExtraWhitespace() {
        let input = "Theme" + String(repeating: " ", count: 100) + "End"

        XCTAssertEqual(WordPackDraftNormalizer.limitedFieldInput(input), input)
        XCTAssertEqual(WordPackDraftNormalizer.normalizedField(input), "Theme End")
    }

    func testDraftRequiresNameAndTwoUniqueWordsButNotCategory() {
        var draft = WordPackDraft(
            name: "  European   capitals ",
            category: "",
            wordsText: "Paris\nparis\nMadrid"
        )

        XCTAssertEqual(draft.normalizedName, "European capitals")
        XCTAssertEqual(draft.wordAnalysis.words, ["Paris", "Madrid"])
        XCTAssertTrue(draft.isValid)

        draft.name = ""
        XCTAssertFalse(draft.isValid)
    }

    func testGeneratedResultBecomesAnEditableUnsavedDraft() {
        var draft = WordPackDraft(
            name: "Manual",
            category: "Custom",
            wordsText: "One\nTwo"
        )
        let generated = GeneratedWordPack(
            name: "Space",
            category: "Space",
            words: ["Orbit", "Comet"],
            aiLimit: nil,
            aiGenerationsToday: nil,
            aiRemaining: nil
        )

        draft.applyGenerated(generated, fallbackName: "Fallback")

        XCTAssertEqual(draft.normalizedName, "Space")
        XCTAssertEqual(draft.normalizedCategory, "Space")
        XCTAssertEqual(draft.wordAnalysis.words, ["Orbit", "Comet"])
        XCTAssertTrue(draft.isValid)
    }

    func testRecommendedWordCountUsesThirtyForOrdinaryThemes() {
        XCTAssertEqual(WordPackRecommendedCountPolicy.requestCount(for: "Landmarks"), 30)
        XCTAssertEqual(
            WordPackRecommendedCountPolicy.selectedCount(
                for: "Landmarks",
                availableCount: 80
            ),
            30
        )
        XCTAssertEqual(
            WordPackRecommendedCountPolicy.selectedCount(
                for: "Landmarks",
                availableCount: 18
            ),
            18
        )
    }

    func testCountriesThemesUseTheAvailablePoolUpToGenerationLimit() {
        let localizedThemes = [
            "Countries",
            "European countries",
            "СТРАНЫ",
            "Страны   Европы",
            "Країни",
            "Країни Європи",
            "Países",
            "Paises de Europa",
            "  PAÍSES\n",
            "Pai\u{301}ses"
        ]

        for theme in localizedThemes {
            XCTAssertEqual(
                WordPackRecommendedCountPolicy.requestCount(for: theme),
                100,
                theme
            )
            XCTAssertEqual(
                WordPackRecommendedCountPolicy.selectedCount(
                    for: theme,
                    availableCount: 47
                ),
                47,
                theme
            )
        }

        XCTAssertEqual(WordPackRecommendedCountPolicy.requestCount(for: "Country music"), 30)
        XCTAssertEqual(
            WordPackRecommendedCountPolicy.selectedCount(
                for: "Countries",
                availableCount: -4
            ),
            0
        )
        XCTAssertEqual(
            WordPackRecommendedCountPolicy.selectedCount(
                for: "Countries",
                availableCount: 140
            ),
            100
        )
    }

    func testLegacyRecommendedLobbyCountIsNormalizedAndRequiresOneServerSync() {
        XCTAssertTrue(LobbyRecommendedCountMigrationPolicy.applies(to: .ai))
        XCTAssertTrue(LobbyRecommendedCountMigrationPolicy.applies(to: .manual))
        XCTAssertFalse(LobbyRecommendedCountMigrationPolicy.applies(to: .saved))
        XCTAssertFalse(LobbyRecommendedCountMigrationPolicy.applies(to: .none))

        let ordinaryCount = LobbyRecommendedCountMigrationPolicy.normalizedCount(
            for: "Hero archetypes",
            authoritativeCount: 100,
            availableCount: 100
        )
        XCTAssertEqual(ordinaryCount, 30)
        XCTAssertTrue(
            LobbyRecommendedCountMigrationPolicy.requiresServerSync(
                authoritativeCount: 100,
                normalizedCount: ordinaryCount
            )
        )

        let countriesCount = LobbyRecommendedCountMigrationPolicy.normalizedCount(
            for: "Countries",
            authoritativeCount: 180,
            availableCount: 180
        )
        XCTAssertEqual(countriesCount, 100)
        XCTAssertTrue(
            LobbyRecommendedCountMigrationPolicy.requiresServerSync(
                authoritativeCount: 180,
                normalizedCount: countriesCount
            )
        )
        XCTAssertFalse(
            LobbyRecommendedCountMigrationPolicy.requiresServerSync(
                authoritativeCount: 30,
                normalizedCount: 30
            )
        )
    }
}
