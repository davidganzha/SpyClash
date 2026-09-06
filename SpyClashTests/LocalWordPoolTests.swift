import XCTest
@testable import SpyClash

final class LocalWordPoolTests: XCTestCase {
    func testPreviewAndDealPrefixCountsUniqueNonemptyWordsInOriginalOrder() {
        let source = ["  Harbor\n", "", "HARBOR", "Museum", "  ", "Airport", "Vault"]
        XCTAssertEqual(LocalWordPool.playableWords(source, selectedCount: 3), ["Harbor", "Museum", "Airport"])
        XCTAssertEqual(LocalWordPool.playableWords(source, selectedCount: 20), ["Harbor", "Museum", "Airport", "Vault"])
    }

    func testSavedLocalPackRetainsItsEntireSelectedPoolAfterRelaunch() {
        let source = (1...251).map { "Place \($0)" }
        let initiallySelectedCount = source.count
        let restoredCount = LocalWordPool.restoredCount(Double(initiallySelectedCount), hasCustomTheme: false)
        XCTAssertEqual(restoredCount, 251)
        XCTAssertEqual(
            LocalWordPool.playableWords(source, selectedCount: Int(restoredCount)),
            LocalWordPool.playableWords(source, selectedCount: initiallySelectedCount)
        )
        XCTAssertEqual(LocalWordPool.playableWords(source, selectedCount: Int(restoredCount)).last, "Place 251")
    }

    func testSavedPartialSelectionAlsoSurvivesRelaunchWithoutApplyingOnlineLimit() {
        let source = (1...300).map { "Place \($0)" }
        let restoredCount = LocalWordPool.restoredCount(225, hasCustomTheme: false)
        let pool = LocalWordPool.playableWords(source, selectedCount: Int(restoredCount))
        XCTAssertEqual(pool.count, 225)
        XCTAssertEqual(pool.last, "Place 225")
        XCTAssertFalse(pool.contains("Place 226"))
        XCTAssertEqual(source.count, 300)
    }

    func testGeneratedSelectionStillHonorsGenerationLimitAndMinimum() {
        XCTAssertEqual(LocalWordPool.restoredCount(251, hasCustomTheme: true), 200)
        XCTAssertEqual(LocalWordPool.restoredCount(22, hasCustomTheme: true), 22)
        XCTAssertEqual(LocalWordPool.restoredCount(-3, hasCustomTheme: true), 2)
        XCTAssertEqual(LocalWordPool.restoredCount(0, hasCustomTheme: false), 2)
    }

    func testChangingGeneratedCountChangesOnlyThePlayablePrefix() {
        let source = (1...25).map { "Word \($0)" }
        let smallerPool = LocalWordPool.playableWords(source, selectedCount: 22)
        let largerPool = LocalWordPool.playableWords(source, selectedCount: 25)
        XCTAssertEqual(smallerPool, Array(largerPool.prefix(22)))
        XCTAssertEqual(largerPool, source)
    }
}
