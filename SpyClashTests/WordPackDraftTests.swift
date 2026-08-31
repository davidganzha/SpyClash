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
}
