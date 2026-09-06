import XCTest
@testable import SpyClash

final class GenerationRecoveryMessageTests: XCTestCase {
    func testUnknownOutcomeIsLocalizedAndNeverAuthorizesAutomaticReplay() {
        let error = Base44Error(message: "raw provider failure", statusCode: 503,
                                code: "generation_outcome_unknown", retryable: false)
        for language in [AppLanguage.en, .ru, .uk, .es] {
            XCTAssertNotEqual(error.localizedMessage(for: language), "raw provider failure")
            XCTAssertNil(WordGenerationRetryPolicy.delayMilliseconds(for: error, completedRetries: 0))
        }
        XCTAssertTrue(error.localizedMessage(for: .ru).contains("не повторяется"))
    }

    func testJournalUnavailableCannotBeMistakenForSafePreEffectRetry() {
        let error = Base44Error(message: "storage internal error", statusCode: 503,
                                code: "generation_journal_unavailable", retryable: true,
                                retryPhase: "effects_may_have_started", effectsStarted: true)
        XCTAssertNil(WordGenerationRetryPolicy.delayMilliseconds(for: error, completedRetries: 0))
        for language in [AppLanguage.en, .ru, .uk, .es] {
            XCTAssertNotEqual(error.localizedMessage(for: language), "storage internal error")
        }
    }
}
