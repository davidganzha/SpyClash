import Foundation
import AVFoundation
import XCTest
@testable import SpyClash

final class HomeHeroTypographyPolicyTests: XCTestCase {
    func testRussianAndUkrainianLandingTitlesUseCompactScale() {
        XCTAssertEqual(
            HomeHeroTypographyPolicy.fontSize(baseFontSize: 58, language: .ru, isModeHero: false),
            49.88,
            accuracy: 0.001
        )
        XCTAssertEqual(
            HomeHeroTypographyPolicy.fontSize(baseFontSize: 58, language: .uk, isModeHero: false),
            49.88,
            accuracy: 0.001
        )
    }

    func testEnglishSpanishAndModeTitlesKeepBaseScale() {
        XCTAssertEqual(
            HomeHeroTypographyPolicy.fontSize(baseFontSize: 58, language: .en, isModeHero: false),
            58
        )
        XCTAssertEqual(
            HomeHeroTypographyPolicy.fontSize(baseFontSize: 58, language: .es, isModeHero: false),
            58
        )
        XCTAssertEqual(
            HomeHeroTypographyPolicy.fontSize(baseFontSize: 58, language: .uk, isModeHero: true),
            58
        )
    }
}

final class SpyLoaderMotionPolicyTests: XCTestCase {
    func testRotationAdvancesLinearlyWithoutAutoreverseStop() {
        XCTAssertEqual(
            SpyLoaderMotionPolicy.state(at: 0, isAnimating: true, reduceMotion: false).rotationDegrees,
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SpyLoaderMotionPolicy.state(at: 0.275, isAnimating: true, reduceMotion: false).rotationDegrees,
            90,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SpyLoaderMotionPolicy.state(at: 0.55, isAnimating: true, reduceMotion: false).rotationDegrees,
            180,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SpyLoaderMotionPolicy.state(at: 0.825, isAnimating: true, reduceMotion: false).rotationDegrees,
            270,
            accuracy: 0.001
        )
    }

    func testStoppedAndReduceMotionStatesAreStatic() {
        XCTAssertEqual(
            SpyLoaderMotionPolicy.state(at: 0.55, isAnimating: false, reduceMotion: false),
            SpyLoaderMotionState(rotationDegrees: 0, pulse: 0)
        )
        XCTAssertEqual(
            SpyLoaderMotionPolicy.state(at: 0.55, isAnimating: true, reduceMotion: true),
            SpyLoaderMotionState(rotationDegrees: 0, pulse: 0)
        )
    }
}

final class OnlineRoundStateTests: XCTestCase {
    func testTutorialVoteCopyExplainsNMinusSAndAutomaticCancellationInEveryLanguageAndMode() throws {
        for language in AppLanguage.allCases {
            let expectedFragments: (suspect: String, cancellation: String) = switch language {
            case .en: ("same suspect", "server cancels automatically")
            case .es: ("mismo sospechoso", "servidor cancela automáticamente")
            case .ru: ("одного подозреваемого", "сервер автоматически отменит")
            case .uk: ("одного підозрюваного", "сервер автоматично скасує")
            }

            for mode in TutorialMode.allCases {
                let instruction = try XCTUnwrap(
                    language.tutorialSteps(for: mode).first { $0.text.contains("N−S") },
                    "Missing N−S tutorial instruction for \(language.rawValue)/\(mode.rawValue)"
                )
                XCTAssertTrue(instruction.text.localizedCaseInsensitiveContains(expectedFragments.suspect))
                XCTAssertTrue(instruction.text.localizedCaseInsensitiveContains(expectedFragments.cancellation))
            }
        }
    }

    func testUkrainianLanguageCodesNormalizeToBCP47Language() {
        XCTAssertEqual(AppLanguage.normalized("uk"), .uk)
        XCTAssertEqual(AppLanguage.normalized("uk-UA"), .uk)
        XCTAssertEqual(AppLanguage.normalized("uk_UA"), .uk)
        XCTAssertEqual(AppLanguage.uk.rawValue, "uk")
        XCTAssertEqual(AppLanguage.uk.title, "Українська")
    }

    func testUkrainianCoreCopyIsCompleteAndDoesNotFallBackToAnotherLanguage() {
        let ukrainian = AppLanguage.uk

        XCTAssertEqual(ukrainian.welcome.enterGame, "УВІЙТИ В ГРУ")
        XCTAssertEqual(ukrainian.auth.continueAction, "ДАЛІ")
        XCTAssertEqual(ukrainian.profile.languageLabel, "// МОВА")
        XCTAssertEqual(ukrainian.home.createOnlineRoom, "СТВОРИТИ ОНЛАЙН-КІМНАТУ")
        XCTAssertEqual(ukrainian.localGame.youAreSpy, "ТИ ШПИГУН")
        XCTAssertEqual(ukrainian.game.detectivesWin, "ДЕТЕКТИВИ ПЕРЕМОГЛИ")
        XCTAssertNotEqual(ukrainian.welcome, AppLanguage.en.welcome)
        XCTAssertNotEqual(ukrainian.game, AppLanguage.ru.game)
    }

    func testLiveActivityContractPreservesUkrainianDisplayLanguage() {
        let state = SpyClashMatchActivityAttributes.ContentState(
            phase: .playing,
            mode: .questions,
            participants: [],
            round: 1,
            displayLanguageCode: "uk-UA",
            revision: 1
        )

        XCTAssertEqual(state.displayLanguageCode, "uk")
    }

    func testLiveActivityParticipantFallbackUsesInjectedDisplayLanguageCopy() {
        let fallback = "ОПЕРАТИВНИК"
        for storedName in ["", "AGENT", "OPERATIVE"] {
            let participant = SpyClashMatchActivityAttributes.Participant(
                id: storedName.isEmpty ? "blank" : storedName.lowercased(),
                displayName: storedName
            )
            XCTAssertEqual(participant.resolvedDisplayName(fallback: fallback), fallback)
            XCTAssertEqual(participant.compactName(fallback: fallback), fallback)
        }

        let namedParticipant = SpyClashMatchActivityAttributes.Participant(
            id: "raven",
            displayName: "Red Raven"
        )
        XCTAssertEqual(
            namedParticipant.resolvedDisplayName(fallback: fallback),
            "Red Raven"
        )
        XCTAssertEqual(namedParticipant.compactName(fallback: fallback), "RED RAVEN")
    }

    func testActiveLiveActivityProjectionUsesNewAppLanguageBeforeAccountSync() throws {
        let room = GameRoom.previewRoom(status: "playing")
        let viewerEmail = try XCTUnwrap(room.playersList.first?.email)
        let viewer = SpyUser(
            id: "language-switch-viewer",
            email: viewerEmail,
            fullName: nil,
            displayName: "Red Raven",
            avatar: "🕵️",
            language: "en",
            role: nil,
            isVerified: nil,
            rating: nil,
            gamesPlayed: nil,
            gamesWon: nil,
            remoteSpyID: nil,
            spyCardTheme: nil,
            spyCardAccent: nil,
            spyCardBadge: nil,
            radarInvitePolicy: nil
        )

        XCTAssertEqual(
            try XCTUnwrap(room.liveActivityProjection(for: viewer)).state.displayLanguageCode,
            "en"
        )
        XCTAssertEqual(
            try XCTUnwrap(
                room.liveActivityProjection(for: viewer, displayLanguage: .uk)
            ).state.displayLanguageCode,
            "uk"
        )
    }

    func testBase44ErrorsNeverExposeEnglishFallbackInUkrainian() {
        XCTAssertEqual(
            Base44Error(message: "Authentication required.", statusCode: 401)
                .localizedMessage(for: .uk),
            "Увійдіть до акаунта, щоб продовжити."
        )
        XCTAssertEqual(
            Base44Error(message: "Unknown server detail", statusCode: 503)
                .localizedMessage(for: .uk),
            "Сервіс тимчасово недоступний. Спробуйте ще раз."
        )
        XCTAssertEqual(
            Base44Error(message: "Network request failed.", retryable: true)
                .localizedMessage(for: .uk),
            "Перевірте з’єднання з мережею та спробуйте ще раз."
        )
        XCTAssertEqual(
            Base44Error(
                message: "Update required",
                statusCode: 426,
                code: "client_update_required"
            ).localizedMessage(for: .uk),
            "Оновіть SpyClash, щоб продовжити."
        )
    }

    func testGameRoomDecodesDurableDetectiveVoteCancellationEventAndLegacyDefaults() throws {
        let decoder = JSONDecoder()
        let room = try decoder.decode(
            GameRoom.self,
            from: Data(#"""
            {
                "id":"room-1",
                "code":"ABC123",
                "detective_vote_cancellation_event_id":"event-1",
                "detective_vote_cancellation_round_id":"round-7",
                "detective_vote_cancellation_present_at":"2033-05-18T03:33:20.600Z",
                "detective_vote_cancellation_reason":"no_viable_candidate"
            }
            """#.utf8)
        )

        XCTAssertEqual(room.detectiveVoteCancellationEventID, "event-1")
        XCTAssertEqual(room.detectiveVoteCancellationRoundID, "round-7")
        XCTAssertEqual(
            room.detectiveVoteCancellationPresentAt,
            "2033-05-18T03:33:20.600Z"
        )
        XCTAssertEqual(room.detectiveVoteCancellationReason, "no_viable_candidate")
        XCTAssertNotNil(DetectiveVoteCancellationEvent(room: room))

        let legacyRoom = try decoder.decode(
            GameRoom.self,
            from: Data(#"{"id":"legacy","code":"OLD123"}"#.utf8)
        )
        XCTAssertNil(legacyRoom.detectiveVoteCancellationEventID)
        XCTAssertNil(legacyRoom.detectiveVoteCancellationRoundID)
        XCTAssertNil(legacyRoom.detectiveVoteCancellationPresentAt)
        XCTAssertNil(legacyRoom.detectiveVoteCancellationReason)
    }

    func testDetectiveVoteCancellationTimingUsesSharedFuturePresentationDate() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let event = DetectiveVoteCancellationEvent(
            roomID: "room-1",
            eventID: "event-1",
            roundID: "round-1",
            presentAt: now.addingTimeInterval(0.6)
        )

        let timing = try XCTUnwrap(
            DetectiveVoteCancellationPresentationPolicy.timing(
                for: event,
                now: now,
                handledEventIDs: []
            )
        )

        XCTAssertEqual(timing.startDelay, 0.6, accuracy: 0.001)
        XCTAssertEqual(timing.elapsedAtStart, 0, accuracy: 0.001)
        XCTAssertEqual(
            timing.visibleDuration,
            DetectiveVoteCancellationPresentationPolicy.presentationDuration,
            accuracy: 0.001
        )
        XCTAssertEqual(
            timing.endAt.timeIntervalSince(event.presentAt),
            DetectiveVoteCancellationPresentationPolicy.presentationDuration,
            accuracy: 0.001
        )
    }

    func testDetectiveVoteCancellationTimingKeepsLateClientOnSharedEndDate() throws {
        let presentAt = Date(timeIntervalSince1970: 2_000_000_000)
        let now = presentAt.addingTimeInterval(1.2)
        let event = DetectiveVoteCancellationEvent(
            roomID: "room-1",
            eventID: "event-1",
            roundID: "round-1",
            presentAt: presentAt
        )

        let timing = try XCTUnwrap(
            DetectiveVoteCancellationPresentationPolicy.timing(
                for: event,
                now: now,
                handledEventIDs: []
            )
        )

        XCTAssertEqual(timing.startDelay, 0, accuracy: 0.001)
        XCTAssertEqual(timing.elapsedAtStart, 1.2, accuracy: 0.001)
        XCTAssertEqual(timing.visibleDuration, 3.6, accuracy: 0.001)
    }

    func testDetectiveVoteCancellationTimingRejectsHandledStaleAndFarFutureEvents() {
        let presentAt = Date(timeIntervalSince1970: 2_000_000_000)
        let event = DetectiveVoteCancellationEvent(
            roomID: "room-1",
            eventID: "event-1",
            roundID: "round-1",
            presentAt: presentAt
        )

        XCTAssertNil(
            DetectiveVoteCancellationPresentationPolicy.timing(
                for: event,
                now: presentAt,
                handledEventIDs: [event.id]
            )
        )
        XCTAssertNil(
            DetectiveVoteCancellationPresentationPolicy.timing(
                for: event,
                now: presentAt.addingTimeInterval(
                    DetectiveVoteCancellationPresentationPolicy.presentationDuration
                ),
                handledEventIDs: []
            )
        )
        XCTAssertNil(
            DetectiveVoteCancellationPresentationPolicy.timing(
                for: event,
                now: presentAt.addingTimeInterval(
                    -DetectiveVoteCancellationPresentationPolicy.maximumFutureLead - 0.01
                ),
                handledEventIDs: []
            )
        )
    }

    func testDetectiveVoteCancellationCopyMatchesApprovedRussianAndAllLocales() {
        let russian = DetectiveVoteCancellationCopy.localized(languageCode: "ru")
        XCTAssertEqual(russian.title, "МНЕНИЯ РАЗДЕЛИЛИСЬ")
        XCTAssertEqual(
            russian.body,
            "Ни один подозреваемый уже не сможет набрать достаточно голосов."
        )
        XCTAssertEqual(
            russian.footer,
            "ГОЛОСОВАНИЕ ОТМЕНЕНО · ИГРА ПРОДОЛЖАЕТСЯ"
        )

        let english = DetectiveVoteCancellationCopy.localized(languageCode: "en")
        XCTAssertEqual(english.title, "OPINIONS ARE DIVIDED")
        XCTAssertEqual(english.body, "No suspect can still receive enough votes.")
        XCTAssertEqual(english.footer, "VOTING CANCELLED · GAME CONTINUES")

        let spanish = DetectiveVoteCancellationCopy.localized(languageCode: "es-MX")
        XCTAssertEqual(spanish.title, "OPINIONES DIVIDIDAS")
        XCTAssertEqual(
            spanish.body,
            "Ningún sospechoso podrá reunir ya los votos suficientes."
        )

        let ukrainian = DetectiveVoteCancellationCopy.localized(languageCode: "uk-UA")
        XCTAssertEqual(ukrainian.title, "ДУМКИ РОЗДІЛИЛИСЯ")
        XCTAssertEqual(ukrainian.footer, "ГОЛОСУВАННЯ СКАСОВАНО · ГРА ТРИВАЄ")
    }

    func testLocalTimerAwardsSpyOnTickThatReachesZeroWithoutGuessGrace() {
        XCTAssertEqual(
            LocalGameDeadlinePolicy.outcome(afterTickFrom: 2),
            .continuePlaying(remainingSeconds: 1)
        )
        XCTAssertEqual(
            LocalGameDeadlinePolicy.outcome(afterTickFrom: 1),
            .spyWins
        )
        XCTAssertEqual(
            LocalGameDeadlinePolicy.outcome(afterTickFrom: 0),
            .spyWins
        )
    }

    func testSharedGameIntroMotionKeepsTimelineAndCardArcDeterministic() {
        XCTAssertEqual(SpyExperienceMotion.segment(-1, from: 0.2, to: 0.8), 0)
        XCTAssertEqual(SpyExperienceMotion.segment(1.2, from: 0.2, to: 0.8), 1)
        XCTAssertEqual(SpyExperienceMotion.segment(0.5, from: 0.2, to: 0.8), 0.5, accuracy: 0.0001)

        let start = CGPoint(x: 20, y: 120)
        let end = CGPoint(x: 180, y: 120)
        XCTAssertEqual(
            SpyExperienceMotion.arcPoint(from: start, to: end, progress: 0, lift: 60),
            start
        )
        XCTAssertEqual(
            SpyExperienceMotion.arcPoint(from: start, to: end, progress: 1, lift: 60),
            end
        )
        XCTAssertLessThan(
            SpyExperienceMotion.arcPoint(from: start, to: end, progress: 0.5, lift: 60).y,
            start.y
        )
    }

    func testLocalLobbyPrimaryActionRequiresGenerationForUnpreparedCustomTheme() {
        let resolution = LocalLobbyPrimaryActionPolicy.resolve(
            hasCustomTheme: true,
            hasGeneratedPack: false,
            source: .generated
        )

        XCTAssertEqual(resolution.action, .generateRequired)
        XCTAssertFalse(resolution.isEnabled)
    }

    func testLocalLobbyPrimaryActionRequiresAWordSource() {
        let resolution = LocalLobbyPrimaryActionPolicy.resolve(
            hasCustomTheme: false,
            hasGeneratedPack: false,
            source: .none
        )

        XCTAssertEqual(resolution.action, .sourceRequired)
        XCTAssertFalse(resolution.isEnabled)
    }

    func testLocalLobbyPrimaryActionDealsCardsFromSavedOrGeneratedSource() {
        for source: LocalLobbyPrimaryActionPolicy.Source in [.saved, .generated] {
            let resolution = LocalLobbyPrimaryActionPolicy.resolve(
                hasCustomTheme: source == .generated,
                hasGeneratedPack: source == .generated,
                source: source
            )

            XCTAssertEqual(resolution.action, .dealCards, "Unexpected action for \(source)")
            XCTAssertTrue(resolution.isEnabled, "Expected enabled CTA for \(source)")
        }
    }

    func testForgotCardReviewOnlyResumesTimerThatWasRunningInTheSameLiveRound() {
        XCTAssertTrue(
            LocalGameInterruptionPolicy.shouldResumeTimerAfterCardReview(
                wasRunning: true,
                phaseIsPlaying: true,
                remainingSeconds: 42
            )
        )
        XCTAssertFalse(
            LocalGameInterruptionPolicy.shouldResumeTimerAfterCardReview(
                wasRunning: false,
                phaseIsPlaying: true,
                remainingSeconds: 42
            ),
            "A card review opened from an already-paused game must leave it paused"
        )
        XCTAssertFalse(
            LocalGameInterruptionPolicy.shouldResumeTimerAfterCardReview(
                wasRunning: true,
                phaseIsPlaying: false,
                remainingSeconds: 42
            )
        )
        XCTAssertFalse(
            LocalGameInterruptionPolicy.shouldResumeTimerAfterCardReview(
                wasRunning: true,
                phaseIsPlaying: true,
                remainingSeconds: 0
            )
        )
    }

    func testLocalBackgroundInterruptionPausesOnlyRunningGameplay() {
        XCTAssertTrue(
            LocalGameInterruptionPolicy.shouldPauseForBackground(
                phaseIsPlaying: true,
                isAlreadyPaused: false
            )
        )
        XCTAssertFalse(
            LocalGameInterruptionPolicy.shouldPauseForBackground(
                phaseIsPlaying: true,
                isAlreadyPaused: true
            )
        )
        XCTAssertFalse(
            LocalGameInterruptionPolicy.shouldPauseForBackground(
                phaseIsPlaying: false,
                isAlreadyPaused: false
            )
        )
    }

    func testLocalBackgroundInterruptionConcealsOnlyAnOpenRoleCard() {
        XCTAssertTrue(
            LocalGameInterruptionPolicy.shouldConcealRoleCard(
                phaseIsCards: true,
                isRevealed: true
            )
        )
        XCTAssertFalse(
            LocalGameInterruptionPolicy.shouldConcealRoleCard(
                phaseIsCards: true,
                isRevealed: false
            )
        )
        XCTAssertFalse(
            LocalGameInterruptionPolicy.shouldConcealRoleCard(
                phaseIsCards: false,
                isRevealed: true
            )
        )
    }

    func testLocalAccusationCatchesAnyAssignedSpyRatherThanOnlyThePrimarySpy() {
        let spyFlags = [true, false, true, false, true, false]

        XCTAssertTrue(LocalGameAccusationPolicy.caughtSpy(at: 0, spyFlags: spyFlags))
        XCTAssertTrue(LocalGameAccusationPolicy.caughtSpy(at: 2, spyFlags: spyFlags))
        XCTAssertTrue(LocalGameAccusationPolicy.caughtSpy(at: 4, spyFlags: spyFlags))
        XCTAssertFalse(LocalGameAccusationPolicy.caughtSpy(at: 1, spyFlags: spyFlags))
        XCTAssertFalse(LocalGameAccusationPolicy.caughtSpy(at: 99, spyFlags: spyFlags))
    }

    func testLocalMultiSpyAccusationContinuesUntilLastSpyOrParity() {
        let spyFlags = [true, true, false, false, false, false]

        XCTAssertEqual(
            LocalGameAccusationPolicy.outcome(accusing: 0, spyFlags: spyFlags),
            .continuePlaying,
            "Eliminating one of two spies must not award detectives the match"
        )
        XCTAssertEqual(
            LocalGameAccusationPolicy.outcome(accusing: 2, spyFlags: spyFlags),
            .continuePlaying,
            "A wrong accusation must continue while spies have not reached parity"
        )
        XCTAssertEqual(
            LocalGameAccusationPolicy.outcome(
                accusing: 3,
                spyFlags: spyFlags,
                eliminatedIndices: [2]
            ),
            .spyWins,
            "After the second detective is eliminated, two spies reach parity with two detectives"
        )
        XCTAssertEqual(
            LocalGameAccusationPolicy.outcome(
                accusing: 1,
                spyFlags: spyFlags,
                eliminatedIndices: [0]
            ),
            .detectivesWin,
            "Detectives win only after the last active spy is eliminated"
        )
        XCTAssertEqual(
            LocalGameAccusationPolicy.outcome(
                accusing: 0,
                spyFlags: spyFlags,
                eliminatedIndices: [0]
            ),
            .invalidAccusation
        )
    }

    func testLocalPrivateVoteUsesSameNMinusSThresholdAsOnline() {
        let active = Array(0..<6)

        XCTAssertEqual(
            LocalPrivateVotePolicy.threshold(
                activeIndices: active,
                activeSpyIndices: [0]
            ),
            5
        )
        XCTAssertEqual(
            LocalPrivateVotePolicy.threshold(
                activeIndices: active,
                activeSpyIndices: [0, 1]
            ),
            4
        )
    }

    func testLocalPrivateVoteRejectsSelfVoteAndKeepsFirstVoteImmutable() throws {
        let active = Array(0..<6)
        XCTAssertNil(
            LocalPrivateVotePolicy.appendingImmutableVote(
                voterIndex: 2,
                targetIndex: 2,
                activeIndices: active,
                existingVotes: []
            )
        )

        let first = try XCTUnwrap(
            LocalPrivateVotePolicy.appendingImmutableVote(
                voterIndex: 2,
                targetIndex: 0,
                activeIndices: active,
                existingVotes: []
            )
        )
        XCTAssertEqual(first, [LocalPrivateVote(voterIndex: 2, targetIndex: 0)])
        XCTAssertNil(
            LocalPrivateVotePolicy.appendingImmutableVote(
                voterIndex: 2,
                targetIndex: 1,
                activeIndices: active,
                existingVotes: first
            )
        )
    }

    func testLocalPrivateVoteEjectsAtFiveOfSixWithOneSpy() {
        let decision = LocalPrivateVotePolicy.decision(
            activeIndices: Array(0..<6),
            activeSpyIndices: [0],
            votes: [1, 2, 3, 4, 5].map {
                LocalPrivateVote(voterIndex: $0, targetIndex: 0)
            }
        )

        XCTAssertEqual(decision, .eject(index: 0, threshold: 5))
    }

    func testLocalPrivateVoteCancelsEarlyWhenNoCandidateCanReachThreshold() {
        let decision = LocalPrivateVotePolicy.decision(
            activeIndices: Array(0..<6),
            activeSpyIndices: [0],
            votes: [
                LocalPrivateVote(voterIndex: 1, targetIndex: 0),
                LocalPrivateVote(voterIndex: 2, targetIndex: 0),
                LocalPrivateVote(voterIndex: 3, targetIndex: 0),
                LocalPrivateVote(voterIndex: 0, targetIndex: 1),
                LocalPrivateVote(voterIndex: 4, targetIndex: 1)
            ]
        )

        XCTAssertEqual(decision, .cancel(threshold: 5))
    }

    func testLocalPrivateVoteDoesNotCountCandidateAsTheirOwnRemainingVote() {
        let decision = LocalPrivateVotePolicy.decision(
            activeIndices: Array(0..<6),
            activeSpyIndices: [1],
            votes: [
                LocalPrivateVote(voterIndex: 1, targetIndex: 0),
                LocalPrivateVote(voterIndex: 2, targetIndex: 0),
                LocalPrivateVote(voterIndex: 3, targetIndex: 0),
                LocalPrivateVote(voterIndex: 4, targetIndex: 0),
                LocalPrivateVote(voterIndex: 5, targetIndex: 1)
            ]
        )

        XCTAssertEqual(decision, .cancel(threshold: 5))
    }

    func testLocalPrivateVoteEjectsAtFourOfSixWithTwoActiveSpies() {
        let decision = LocalPrivateVotePolicy.decision(
            activeIndices: Array(0..<6),
            activeSpyIndices: [0, 1],
            votes: [1, 2, 3, 4].map {
                LocalPrivateVote(voterIndex: $0, targetIndex: 0)
            }
        )

        XCTAssertEqual(decision, .eject(index: 0, threshold: 4))
    }

    func testLocalSpyAssignmentSamplesUniqueInRangeIdentitiesAtApprovedCount() {
        for _ in 0..<100 {
            let indices = LocalSpyAssignmentPolicy.randomSpyIndices(
                playerCount: 9,
                requestedSpyCount: 3
            )
            XCTAssertEqual(indices.count, 3)
            XCTAssertEqual(Set(indices).count, 3)
            XCTAssertTrue(indices.allSatisfy { (0..<9).contains($0) })
        }

        XCTAssertEqual(
            LocalSpyAssignmentPolicy.randomSpyIndices(playerCount: 6, requestedSpyCount: 3).count,
            2
        )
        XCTAssertTrue(
            LocalSpyAssignmentPolicy.randomSpyIndices(playerCount: 2, requestedSpyCount: 1).isEmpty
        )
    }

    func testRoleCardGateCountsOnlyCurrentActivePlayers() throws {
        var room = GameRoom.previewRoom(status: "playing", playerCount: 6)
        let spectator = try XCTUnwrap(room.playersList.last)
        room.spectators = [spectator.email]
        room.cardsRead = room.activePlayers.map { $0.email.uppercased() }

        XCTAssertEqual(room.activeCardsReadList.count, 5)
        XCTAssertTrue(room.allRoleCardsRead)

        room.cardsRead = [spectator.email] + room.activePlayers.dropLast().map(\.email)
        XCTAssertEqual(room.activeCardsReadList.count, 4)
        XCTAssertFalse(room.allRoleCardsRead)
    }

    func testConfirmedPlayerCanReopenRoleCardWhileWaitingForOthers() {
        XCTAssertTrue(
            OnlineRoleRevealInteractionPolicy.canToggleRoleCard(
                isConfirmed: true,
                isConfirming: false
            )
        )
    }

    func testRoleCardDoesNotToggleWhileConfirmationIsInFlight() {
        XCTAssertFalse(
            OnlineRoleRevealInteractionPolicy.canToggleRoleCard(
                isConfirmed: false,
                isConfirming: true
            )
        )
    }

    func testPreviewRoomUsesCurrentSixCharacterRoomCodeContract() {
        let room = GameRoom.previewRoom(status: "waiting")

        XCTAssertEqual(room.code.count, 6)
        XCTAssertTrue(room.code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    func testExclusionUsesAuthoritativeServerThreshold() {
        var room = GameRoom.previewRoom(status: "playing", playerCount: 6)

        XCTAssertEqual(room.activePlayers.count, 6)
        XCTAssertEqual(room.exclusionVoteThreshold, 5)

        room.spectators = [room.playersList[5].email]
        room.serverExclusionVoteThreshold = 4
        XCTAssertEqual(room.activePlayers.count, 5)
        XCTAssertEqual(room.exclusionVoteThreshold, 4)
    }

    func testMultiSpyRoomNeverComputesLegacyNMinusOneThresholdLocally() {
        var room = GameRoom.previewRoom(status: "playing", playerCount: 6)
        room.lobbySpyCount = 2
        room.spyEmails = Array(room.playersList.prefix(2).map(\.email))
        room.serverExclusionVoteThreshold = 4

        XCTAssertEqual(room.exclusionVoteThreshold, 4)

        room.serverExclusionVoteThreshold = nil
        XCTAssertEqual(room.exclusionVoteThreshold, 0)
    }

    func testSpyCountRangeIsCappedAtOneSpyPerThreePlayersAndThreeHardMaximum() {
        let expected: [(players: Int, maximum: Int)] = [
            (3, 1), (5, 1),
            (6, 2), (8, 2),
            (9, 3), (12, 3), (30, 3)
        ]

        for sample in expected {
            XCTAssertEqual(
                GameRoom.maximumSpyCount(forPlayerCount: sample.players),
                sample.maximum,
                "Unexpected maximum for \(sample.players) players"
            )
        }
    }

    func testSpyCountChooserAppearsOnlyWhenRosterSupportsMultipleSpies() {
        XCTAssertFalse(GameRoom.canChooseSpyCount(forPlayerCount: 3))
        XCTAssertFalse(GameRoom.canChooseSpyCount(forPlayerCount: 5))
        XCTAssertTrue(GameRoom.canChooseSpyCount(forPlayerCount: 6))
        XCTAssertTrue(GameRoom.canChooseSpyCount(forPlayerCount: 9))
    }

    func testSpyMembershipUsesProjectedArrayWithLegacyScalarFallback() throws {
        let players = #"[{"email":"one@example.com","name":"One","avatar":"1"},{"email":"two@example.com","name":"Two","avatar":"2"},{"email":"three@example.com","name":"Three","avatar":"3"}]"#
        let multi = try JSONDecoder().decode(
            GameRoom.self,
            from: Data("{\"id\":\"multi\",\"code\":\"ABC123\",\"players\":\(players),\"spy_email\":\"one@example.com\",\"spy_emails\":[\"one@example.com\",\"two@example.com\"],\"lobby_spy_count\":2,\"spies_know_each_other\":true,\"exclusion_vote_threshold\":1}".utf8)
        )

        XCTAssertEqual(multi.spyEmailsList, ["one@example.com", "two@example.com"])
        XCTAssertTrue(multi.isSpy(email: "one@example.com"))
        XCTAssertTrue(multi.isSpy(email: "TWO@example.com"))
        XCTAssertFalse(multi.isSpy(email: "three@example.com"))
        XCTAssertEqual(multi.spyPlayers.map(\.email), ["one@example.com", "two@example.com"])
        XCTAssertEqual(multi.exclusionVoteThreshold, 1)

        let legacy = try JSONDecoder().decode(
            GameRoom.self,
            from: Data("{\"id\":\"legacy\",\"code\":\"ABC123\",\"players\":\(players),\"spy_email\":\"three@example.com\"}".utf8)
        )
        XCTAssertEqual(legacy.spyEmailsList, ["three@example.com"])
        XCTAssertTrue(legacy.isSpy(email: "three@example.com"))
        XCTAssertEqual(legacy.exclusionVoteThreshold, 2)
    }

    func testLobbyStateDefaultsLegacySnapshotsToOneHiddenTeamSpy() throws {
        let data = Data(#"{"game_mode":"questions","game_duration_seconds":900,"lobby_word_source":"none","lobby_word_count":0,"lobby_word_count_mode":"recommended","lobby_word_pool":[]}"#.utf8)

        let payload = try JSONDecoder().decode(LobbyStatePayload.self, from: data)

        XCTAssertEqual(payload.spyCount, 1)
        XCTAssertFalse(payload.spiesKnowEachOther)
    }

    func testTypedMultiSpyErrorsExposeUpdateAndRosterFailures() {
        XCTAssertTrue(
            Base44Error(
                message: "Update required",
                statusCode: 426,
                code: "client_update_required"
            ).isClientUpdateRequired
        )
        XCTAssertTrue(
            Base44Error(
                message: "Invalid count",
                statusCode: 400,
                code: "spy_count_invalid_for_player_count"
            ).isSpyCountInvalidForPlayerCount
        )
    }

    func testUnrankedMultiSpyMatchRemainsVisibleInOnlineHistoryButNotCompetitiveStats() throws {
        let records = try JSONDecoder().decode(
            [GameHistory].self,
            from: Data(
                #"[{"id":"multi","room_code":"ABC123","match_type":"online","ranked":false,"spy_count":2},{"id":"ranked","room_code":"DEF456","match_type":"online","ranked":true,"spy_count":1},{"id":"local","room_code":"LOCAL","match_type":"local","ranked":false,"spy_count":2}]"#.utf8
            )
        )

        XCTAssertEqual(records.filter(\.isOnlineHistoryMatch).map(\.id), ["multi", "ranked"])
        XCTAssertEqual(records.filter(\.isOnlineCompetitiveMatch).map(\.id), ["ranked"])
    }

    func testOnlineTimerExpiresExactlyAtZeroWithoutGuessGrace() {
        var room = GameRoom.previewRoom(status: "playing")
        let start = Date(timeIntervalSince1970: 1_000)
        room.gameStartedAt = ISO8601DateFormatter().string(from: start)
        room.gameDurationSeconds = 300

        let beforeDeadline = OnlineTimerSnapshot(
            room: room,
            now: start.addingTimeInterval(299.2)
        )
        XCTAssertEqual(beforeDeadline.displayedSeconds, 1)
        XCTAssertFalse(beforeDeadline.isExpired)

        let atDeadline = OnlineTimerSnapshot(
            room: room,
            now: start.addingTimeInterval(300)
        )
        XCTAssertEqual(atDeadline.displayedSeconds, 0)
        XCTAssertTrue(atDeadline.isExpired)
    }

    func testPausedOnlineTimerDoesNotExpirePastWallClockDeadline() {
        var room = GameRoom.previewRoom(status: "playing")
        let start = Date(timeIntervalSince1970: 1_000)
        room.gameStartedAt = ISO8601DateFormatter().string(from: start)
        room.gameDurationSeconds = 300
        room.gamePausedAt = ISO8601DateFormatter().string(from: start.addingTimeInterval(120))

        let snapshot = OnlineTimerSnapshot(
            room: room,
            now: start.addingTimeInterval(600)
        )
        XCTAssertEqual(snapshot.displayedSeconds, 180)
        XCTAssertFalse(snapshot.isExpired)
    }

    func testExpiredRoomFinalizationScopeRequiresSameExpiredActiveMatch() throws {
        var room = GameRoom.previewRoom(status: "playing")
        let start = Date(timeIntervalSince1970: 1_000)
        room.gameStartedAt = ISO8601DateFormatter().string(from: start)
        room.gameDurationSeconds = 60
        let scope = try XCTUnwrap(OnlineRoomMatchScope(room: room))

        XCTAssertTrue(
            ExpiredRoomFinalizationRetryPolicy.canAttempt(
                scope: scope,
                room: room,
                now: start.addingTimeInterval(60)
            )
        )

        room.gamePausedAt = ISO8601DateFormatter().string(from: start.addingTimeInterval(30))
        XCTAssertFalse(
            ExpiredRoomFinalizationRetryPolicy.canAttempt(
                scope: scope,
                room: room,
                now: start.addingTimeInterval(90)
            )
        )

        room.gamePausedAt = nil
        room.matchID = "replacement-match"
        XCTAssertFalse(
            ExpiredRoomFinalizationRetryPolicy.canAttempt(
                scope: scope,
                room: room,
                now: start.addingTimeInterval(90)
            )
        )
    }

    func testExpiredRoomFinalizationRetriesClockSkewAndTemporaryFailuresOnly() {
        XCTAssertTrue(
            ExpiredRoomFinalizationRetryPolicy.isRetryable(
                Base44Error(
                    message: "The server game deadline has not elapsed.",
                    statusCode: 409,
                    code: "invalid_ranked_terminal"
                )
            )
        )
        XCTAssertTrue(
            ExpiredRoomFinalizationRetryPolicy.isRetryable(
                Base44Error(message: "Temporary failure", statusCode: 503)
            )
        )
        XCTAssertTrue(
            ExpiredRoomFinalizationRetryPolicy.isRetryable(
                Base44Error(
                    message: "Terminal reconciliation pending",
                    statusCode: 409,
                    code: "terminal_reconciliation_pending"
                )
            )
        )
        XCTAssertFalse(
            ExpiredRoomFinalizationRetryPolicy.isRetryable(
                Base44Error(
                    message: "Participant missing",
                    statusCode: 409,
                    code: "participant_missing"
                )
            )
        )
        XCTAssertFalse(
            ExpiredRoomFinalizationRetryPolicy.isRetryable(
                Base44Error(message: "Invalid request", statusCode: 422)
            )
        )
    }

    func testExpiredRoomFinalizationBackoffDefersLongTailWithoutTerminalStop() {
        let delays = ExpiredRoomFinalizationRetryPolicy.retryDelaysMilliseconds

        XCTAssertEqual(delays, [250, 500, 1_000, 2_000, 4_000, 6_000, 8_000])
        XCTAssertEqual(delays.reduce(0, +), 21_750)
        XCTAssertEqual(
            ExpiredRoomFinalizationRetryPolicy.delayMilliseconds(
                afterFailedAttempt: delays.count
            ),
            60_000
        )
        XCTAssertEqual(
            ExpiredRoomFinalizationRetryPolicy.delayMilliseconds(
                afterFailedAttempt: 10_000
            ),
            60_000
        )
    }

    func testExpiredRoomFinalizationRetriesStaleCandidateOverNewerExpiredRoom() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = start.addingTimeInterval(61)
        var current = GameRoom.previewRoom(status: "playing")
        current.gameStartedAt = ISO8601DateFormatter().string(from: start)
        current.gameDurationSeconds = 60
        current.roomRevision = 12
        let scope = try XCTUnwrap(OnlineRoomMatchScope(room: current))

        var staleCandidate = current
        staleCandidate.status = "finished"
        staleCandidate.winner = "spy"
        staleCandidate.roomRevision = 11

        XCTAssertEqual(
            ExpiredRoomFinalizationRetryPolicy.disposition(
                for: staleCandidate,
                over: current,
                scope: scope,
                now: now
            ),
            .retryCurrent
        )

        var terminalCurrent = current
        terminalCurrent.status = "finished"
        terminalCurrent.winner = "spy"
        XCTAssertEqual(
            ExpiredRoomFinalizationRetryPolicy.disposition(
                for: staleCandidate,
                over: terminalCurrent,
                scope: scope,
                now: now
            ),
            .stop
        )
    }

    func testAuthoritativeRoomPolicyRejectsLowerRevisionVoteAndExpiryResponses() throws {
        var voteCurrent = GameRoom.previewRoom(status: "voting", playerCount: 6)
        voteCurrent.roomRevision = 12
        var staleVoteResponse = voteCurrent
        staleVoteResponse.roomRevision = 11
        let voteScope = try XCTUnwrap(OnlineRoomMatchScope(room: voteCurrent))

        XCTAssertFalse(
            OnlineAuthoritativeRoomPolicy.canAdopt(
                candidate: staleVoteResponse,
                over: voteCurrent,
                scope: voteScope
            )
        )

        var expiryCurrent = GameRoom.previewRoom(status: "playing")
        expiryCurrent.roomRevision = 8
        var staleExpiryResponse = expiryCurrent
        staleExpiryResponse.status = "finished"
        staleExpiryResponse.winner = "spy"
        staleExpiryResponse.roomRevision = 7
        let expiryScope = try XCTUnwrap(OnlineRoomMatchScope(room: expiryCurrent))

        XCTAssertFalse(
            OnlineAuthoritativeRoomPolicy.canAdopt(
                candidate: staleExpiryResponse,
                over: expiryCurrent,
                scope: expiryScope
            )
        )
    }

    func testAuthoritativeRoomPolicyAcceptsEqualAndNewerScopedResponses() throws {
        var current = GameRoom.previewRoom(status: "playing")
        current.roomRevision = 20
        let scope = try XCTUnwrap(OnlineRoomMatchScope(room: current))

        var equal = current
        equal.status = "finished"
        equal.winner = "spy"
        XCTAssertTrue(
            OnlineAuthoritativeRoomPolicy.canAdopt(
                candidate: equal,
                over: current,
                scope: scope
            )
        )

        var newer = equal
        newer.roomRevision = 21
        XCTAssertTrue(
            OnlineAuthoritativeRoomPolicy.canAdopt(
                candidate: newer,
                over: current,
                scope: scope
            )
        )
    }

    func testTerminalRealtimeRevisionCannotBeRolledBackByOlderPlayingResponse() throws {
        var terminalCurrent = GameRoom.previewRoom(status: "playing")
        terminalCurrent.status = "finished"
        terminalCurrent.winner = "spy"
        terminalCurrent.roomRevision = 31
        let scope = try XCTUnwrap(OnlineRoomMatchScope(room: terminalCurrent))

        var stalePlayingResponse = terminalCurrent
        stalePlayingResponse.status = "playing"
        stalePlayingResponse.winner = nil
        stalePlayingResponse.roomRevision = 30

        XCTAssertFalse(
            OnlineAuthoritativeRoomPolicy.canAdopt(
                candidate: stalePlayingResponse,
                over: terminalCurrent,
                scope: scope
            )
        )
    }

    func testDetectiveVoteResponseRecognizesAuthoritativeCancellation() {
        let previous = GameRoom.previewRoom(status: "voting", playerCount: 6)
        var authoritative = previous
        authoritative.voteRequests = []
        authoritative.detectiveVotes = []

        XCTAssertEqual(
            DetectiveVoteResponsePolicy.classify(
                previous: previous,
                authoritative: authoritative
            ),
            .cancelled
        )
    }

    func testDetectiveVoteInactiveReconciliationRequiresExactTypedConflict() {
        XCTAssertTrue(
            DetectiveVoteResponsePolicy.shouldReconcileInactiveVote(
                Base44Error(
                    message: "Detective voting is no longer active.",
                    statusCode: 409,
                    code: "detective_vote_inactive"
                )
            )
        )
        XCTAssertFalse(
            DetectiveVoteResponsePolicy.shouldReconcileInactiveVote(
                Base44Error(
                    message: "Detective voting is no longer active.",
                    statusCode: 409
                )
            )
        )
        XCTAssertFalse(
            DetectiveVoteResponsePolicy.shouldReconcileInactiveVote(
                Base44Error(
                    message: "Participant missing.",
                    statusCode: 409,
                    code: "participant_missing"
                )
            )
        )
    }

    func testDetectiveVoteRoundChangedReconciliationRequiresExactActionAndCode() {
        let changed = Base44Error(
            message: "The detective vote round changed.",
            statusCode: 409,
            code: "detective_vote_round_changed"
        )
        XCTAssertTrue(
            DetectiveVoteRoundChangedPolicy.shouldReconcile(
                action: "cast_detective_vote",
                error: changed
            )
        )
        XCTAssertFalse(
            DetectiveVoteRoundChangedPolicy.shouldReconcile(
                action: "request_vote",
                error: changed
            )
        )
        XCTAssertFalse(
            DetectiveVoteRoundChangedPolicy.shouldReconcile(
                action: "cast_detective_vote",
                error: Base44Error(
                    message: "The detective vote round changed.",
                    statusCode: 409
                )
            )
        )
        XCTAssertFalse(
            DetectiveVoteRoundChangedPolicy.shouldReconcile(
                action: "cast_detective_vote",
                error: Base44Error(
                    message: "Conflict",
                    statusCode: 409,
                    code: "cas_contention",
                    retryable: true
                )
            )
        )
    }

    func testDetectiveVoteRoundChangedFeedbackIsSilentForRoundBButReportsCancellation() {
        var roundA = GameRoom.previewRoom(status: "voting", playerCount: 6)
        roundA.detectiveVoteRoundID = "vote-round-a"

        var roundB = roundA
        roundB.detectiveVoteRoundID = "vote-round-b"
        XCTAssertEqual(
            DetectiveVoteRoundChangedPolicy.feedback(
                previous: roundA,
                authoritative: roundB
            ),
            .silent
        )

        var cancelled = roundA
        cancelled.detectiveVoteRoundID = nil
        cancelled.voteRequests = []
        cancelled.detectiveVotes = []
        XCTAssertEqual(
            DetectiveVoteRoundChangedPolicy.feedback(
                previous: roundA,
                authoritative: cancelled
            ),
            .cancelled
        )

        var ejected = cancelled
        ejected.spectators = [roundA.playersList[1].email]
        XCTAssertEqual(
            DetectiveVoteRoundChangedPolicy.feedback(
                previous: roundA,
                authoritative: ejected
            ),
            .silent
        )

        var finished = cancelled
        finished.status = "finished"
        finished.winner = "detectives"
        XCTAssertEqual(
            DetectiveVoteRoundChangedPolicy.feedback(
                previous: roundA,
                authoritative: finished
            ),
            .silent
        )
    }

    func testDetectiveVoteConflictRecoveryRequiresExactTypedRetryableConflict() {
        XCTAssertTrue(
            DetectiveVoteConflictRecoveryPolicy.isRecoverableConflict(
                Base44Error(
                    message: "Lease busy",
                    statusCode: 409,
                    code: "active_lease",
                    retryable: true
                )
            )
        )
        XCTAssertTrue(
            DetectiveVoteConflictRecoveryPolicy.isRecoverableConflict(
                Base44Error(
                    message: "CAS busy",
                    statusCode: 409,
                    code: "cas_contention",
                    retryable: true
                )
            )
        )
        XCTAssertFalse(
            DetectiveVoteConflictRecoveryPolicy.isRecoverableConflict(
                Base44Error(
                    message: "Lease busy",
                    statusCode: 409,
                    code: "active_lease",
                    retryable: false
                )
            )
        )
        XCTAssertFalse(
            DetectiveVoteConflictRecoveryPolicy.isRecoverableConflict(
                Base44Error(message: "Conflict", statusCode: 409, retryable: true)
            )
        )
        XCTAssertFalse(
            DetectiveVoteConflictRecoveryPolicy.isRecoverableConflict(CancellationError())
        )
    }

    func testGameRoomDecodesAuthoritativeVoteRoundAndPendingTerminalFlag() throws {
        let payload = #"""
        {
            "id":"room-1",
            "code":"ABC123",
            "detective_vote_round_id":"vote-round-a",
            "terminal_reconciliation_pending":true
        }
        """#

        let room = try JSONDecoder().decode(GameRoom.self, from: Data(payload.utf8))

        XCTAssertEqual(room.detectiveVoteRoundID, "vote-round-a")
        XCTAssertEqual(room.terminalReconciliationPending, true)
    }

    func testDetectiveVoteConflictRecoveryRejectsWrongMatchScope() throws {
        let previous = GameRoom.previewRoom(status: "voting", playerCount: 6)
        let actor = try XCTUnwrap(previous.playersList.first?.email)
        let target = try XCTUnwrap(previous.playersList.dropFirst().first?.email)
        let cast = try XCTUnwrap(
            DetectiveVoteCastScope(
                room: previous,
                actorEmail: actor,
                targetEmail: target
            )
        )
        var wrongMatch = previous
        wrongMatch.matchID = "replacement-match"

        XCTAssertEqual(
            DetectiveVoteConflictRecoveryPolicy.resolution(
                previous: previous,
                authoritative: wrongMatch,
                cast: cast,
                now: Date()
            ),
            .reject
        )
    }

    func testDetectiveVoteConflictRecoveryAcceptsPersistedExactVoteAndCancellation() throws {
        let previous = GameRoom.previewRoom(status: "voting", playerCount: 6)
        let actor = try XCTUnwrap(previous.playersList.first?.email)
        let target = try XCTUnwrap(previous.playersList.dropFirst().first?.email)
        let cast = try XCTUnwrap(
            DetectiveVoteCastScope(
                room: previous,
                actorEmail: actor.uppercased(),
                targetEmail: target.uppercased()
            )
        )

        var persisted = previous
        persisted.detectiveVotes = [
            VoteRecord(voterEmail: actor.lowercased(), votedForEmail: target.lowercased())
        ]
        XCTAssertEqual(
            DetectiveVoteConflictRecoveryPolicy.resolution(
                previous: previous,
                authoritative: persisted,
                cast: cast,
                now: Date()
            ),
            .persisted
        )

        var cancelled = previous
        cancelled.voteRequests = []
        cancelled.detectiveVotes = []
        cancelled.detectiveVoteRoundID = nil
        XCTAssertEqual(
            DetectiveVoteConflictRecoveryPolicy.resolution(
                previous: previous,
                authoritative: cancelled,
                cast: cast,
                now: Date()
            ),
            .cancelled
        )
    }

    func testDetectiveVoteConflictRecoveryAcceptsEjectionFinishAndDeadline() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var previous = GameRoom.previewRoom(status: "voting", playerCount: 6)
        previous.gameStartedAt = ISO8601DateFormatter().string(from: start)
        previous.gameDurationSeconds = 60
        let actor = try XCTUnwrap(previous.playersList.first?.email)
        let target = try XCTUnwrap(previous.playersList.dropFirst().first?.email)
        let cast = try XCTUnwrap(
            DetectiveVoteCastScope(
                room: previous,
                actorEmail: actor,
                targetEmail: target
            )
        )

        var ejected = previous
        ejected.spectators = [target.uppercased()]
        ejected.detectiveVoteRoundID = nil
        XCTAssertEqual(
            DetectiveVoteConflictRecoveryPolicy.resolution(
                previous: previous,
                authoritative: ejected,
                cast: cast,
                now: start.addingTimeInterval(30)
            ),
            .ejected
        )

        var finished = previous
        finished.status = "finished"
        finished.winner = "detectives"
        finished.detectiveVoteRoundID = nil
        XCTAssertEqual(
            DetectiveVoteConflictRecoveryPolicy.resolution(
                previous: previous,
                authoritative: finished,
                cast: cast,
                now: start.addingTimeInterval(30)
            ),
            .finished
        )

        XCTAssertEqual(
            DetectiveVoteConflictRecoveryPolicy.resolution(
                previous: previous,
                authoritative: previous,
                cast: cast,
                now: start.addingTimeInterval(60)
            ),
            .deadline
        )
    }

    func testDetectiveVoteConflictRecoveryNeverRetriesIntoReopenedVoteRound() throws {
        var roundA = GameRoom.previewRoom(status: "voting", playerCount: 6)
        roundA.detectiveVoteRoundID = "vote-round-a"
        let actor = try XCTUnwrap(roundA.playersList.first?.email)
        let target = try XCTUnwrap(roundA.playersList.dropFirst().first?.email)
        let cast = try XCTUnwrap(
            DetectiveVoteCastScope(
                room: roundA,
                actorEmail: actor,
                targetEmail: target
            )
        )

        var roundB = roundA
        roundB.detectiveVoteRoundID = "vote-round-b"
        roundB.detectiveVotes = []

        XCTAssertFalse(cast.matchesVoteRound(roundB))
        XCTAssertTrue(cast.hasChangedVoteRound(roundB))
        XCTAssertEqual(
            DetectiveVoteConflictRecoveryPolicy.resolution(
                previous: roundA,
                authoritative: roundB,
                cast: cast,
                now: Date()
            ),
            .superseded
        )
    }

    func testDetectiveVoteConflictRecoveryTreatsBlankRoundWithNewRequestsAsSuperseded() throws {
        var roundA = GameRoom.previewRoom(status: "voting", playerCount: 6)
        roundA.detectiveVoteRoundID = "vote-round-a"
        let actor = try XCTUnwrap(roundA.playersList.first?.email)
        let target = try XCTUnwrap(roundA.playersList.dropFirst().first?.email)
        let cast = try XCTUnwrap(
            DetectiveVoteCastScope(
                room: roundA,
                actorEmail: actor,
                targetEmail: target
            )
        )

        var roundBRequestPhase = roundA
        roundBRequestPhase.detectiveVoteRoundID = nil
        roundBRequestPhase.detectiveVotes = []
        roundBRequestPhase.voteRequests = [roundA.playersList[2].email]

        XCTAssertTrue(cast.hasMissingVoteRound(roundBRequestPhase))
        XCTAssertFalse(cast.hasChangedVoteRound(roundBRequestPhase))
        XCTAssertEqual(
            DetectiveVoteConflictRecoveryPolicy.resolution(
                previous: roundA,
                authoritative: roundBRequestPhase,
                cast: cast,
                now: Date()
            ),
            .superseded
        )
        XCTAssertEqual(
            DetectiveVoteRoundChangedPolicy.feedback(
                previous: roundA,
                authoritative: roundBRequestPhase
            ),
            .silent
        )
    }

    func testDetectiveVoteDirectSuccessDispositionOnlyRecordsPersistedVote() throws {
        var roundA = GameRoom.previewRoom(status: "voting", playerCount: 6)
        roundA.detectiveVoteRoundID = "vote-round-a"
        let actor = try XCTUnwrap(roundA.playersList.first?.email)
        let target = try XCTUnwrap(roundA.playersList.dropFirst().first?.email)
        let cast = try XCTUnwrap(
            DetectiveVoteCastScope(
                room: roundA,
                actorEmail: actor,
                targetEmail: target
            )
        )

        var persisted = roundA
        persisted.detectiveVotes = [
            VoteRecord(voterEmail: actor, votedForEmail: target)
        ]
        XCTAssertEqual(
            DetectiveVoteDirectSuccessPolicy.disposition(
                previous: roundA,
                authoritative: persisted,
                cast: cast,
                now: Date()
            ),
            .recorded
        )

        var cancelled = roundA
        cancelled.detectiveVoteRoundID = nil
        cancelled.voteRequests = []
        cancelled.detectiveVotes = []
        XCTAssertEqual(
            DetectiveVoteDirectSuccessPolicy.disposition(
                previous: roundA,
                authoritative: cancelled,
                cast: cast,
                now: Date()
            ),
            .cancelled
        )

        var roundBRequestPhase = roundA
        roundBRequestPhase.detectiveVoteRoundID = nil
        roundBRequestPhase.detectiveVotes = []
        roundBRequestPhase.voteRequests = [roundA.playersList[2].email]
        XCTAssertEqual(
            DetectiveVoteDirectSuccessPolicy.disposition(
                previous: roundA,
                authoritative: roundBRequestPhase,
                cast: cast,
                now: Date()
            ),
            .adoptSilently
        )

        XCTAssertEqual(
            DetectiveVoteDirectSuccessPolicy.disposition(
                previous: roundA,
                authoritative: roundA,
                cast: cast,
                now: Date()
            ),
            .reconcile
        )
    }

    func testDetectiveVoteConflictRecoveryWaitsForPendingTerminalBeforeExactVote() throws {
        let previous = GameRoom.previewRoom(status: "voting", playerCount: 6)
        let actor = try XCTUnwrap(previous.playersList.first?.email)
        let target = try XCTUnwrap(previous.playersList.dropFirst().first?.email)
        let cast = try XCTUnwrap(
            DetectiveVoteCastScope(
                room: previous,
                actorEmail: actor,
                targetEmail: target
            )
        )

        var pending = previous
        pending.terminalReconciliationPending = true
        pending.detectiveVotes = [
            VoteRecord(voterEmail: actor, votedForEmail: target)
        ]
        XCTAssertEqual(
            DetectiveVoteConflictRecoveryPolicy.resolution(
                previous: previous,
                authoritative: pending,
                cast: cast,
                now: Date()
            ),
            .retry
        )

        pending.status = "finished"
        pending.winner = "detectives"
        pending.terminalReconciliationPending = false
        pending.detectiveVoteRoundID = nil
        XCTAssertEqual(
            DetectiveVoteConflictRecoveryPolicy.resolution(
                previous: previous,
                authoritative: pending,
                cast: cast,
                now: Date()
            ),
            .finished
        )
    }

    func testDetectiveVoteConflictRecoveryRetriesAbsentVoteUntilCappedExhaustion() throws {
        let previous = GameRoom.previewRoom(status: "voting", playerCount: 6)
        let actor = try XCTUnwrap(previous.playersList.first?.email)
        let target = try XCTUnwrap(previous.playersList.dropFirst().first?.email)
        let cast = try XCTUnwrap(
            DetectiveVoteCastScope(
                room: previous,
                actorEmail: actor,
                targetEmail: target
            )
        )

        XCTAssertEqual(
            DetectiveVoteConflictRecoveryPolicy.resolution(
                previous: previous,
                authoritative: previous,
                cast: cast,
                now: Date()
            ),
            .retry
        )
        XCTAssertEqual(
            DetectiveVoteConflictRecoveryPolicy.retryDelaysMilliseconds,
            [250, 500, 1_000, 2_000, 4_000, 8_000, 8_000, 8_000]
        )
        XCTAssertEqual(
            DetectiveVoteConflictRecoveryPolicy.delayMilliseconds(beforeRetry: 7),
            8_000
        )
        XCTAssertNil(
            DetectiveVoteConflictRecoveryPolicy.delayMilliseconds(beforeRetry: 8)
        )
    }

    func testDetectiveVoteResponseDoesNotMislabelExclusionOrTerminalResultAsCancellation() {
        let previous = GameRoom.previewRoom(status: "voting", playerCount: 6)
        let excludedEmail = previous.activePlayers[0].email

        var exclusion = previous
        exclusion.voteRequests = []
        exclusion.detectiveVotes = []
        exclusion.spectators = [excludedEmail]
        exclusion.eliminatedEmails = [excludedEmail]
        XCTAssertEqual(
            DetectiveVoteResponsePolicy.classify(
                previous: previous,
                authoritative: exclusion
            ),
            .recorded
        )

        var caseVariantExclusion = previous
        caseVariantExclusion.voteRequests = []
        caseVariantExclusion.detectiveVotes = []
        caseVariantExclusion.spectators = [excludedEmail.uppercased()]
        XCTAssertEqual(
            DetectiveVoteResponsePolicy.classify(
                previous: previous,
                authoritative: caseVariantExclusion
            ),
            .recorded
        )

        var terminal = previous
        terminal.status = "finished"
        terminal.winner = "detectives"
        terminal.voteRequests = []
        terminal.detectiveVotes = []
        XCTAssertEqual(
            DetectiveVoteResponsePolicy.classify(
                previous: previous,
                authoritative: terminal
            ),
            .recorded
        )
    }

    func testOnlineVoteIdentityPolicyExcludesSelfAndEliminatedEmailsCaseInsensitively() throws {
        let room = GameRoom.previewRoom(status: "voting")
        let currentPlayer = try XCTUnwrap(room.activePlayers.first)
        let eliminatedPlayer = try XCTUnwrap(room.activePlayers.last)

        let candidates = OnlineVoteIdentityPolicy.candidates(
            from: room.activePlayers,
            currentUserEmail: "  \(currentPlayer.email.uppercased())  ",
            eliminatedEmails: [eliminatedPlayer.email.uppercased()]
        )

        XCTAssertFalse(candidates.contains { $0.email == currentPlayer.email })
        XCTAssertFalse(candidates.contains { $0.email == eliminatedPlayer.email })
        XCTAssertEqual(candidates.map(\.email), [room.activePlayers[1].email])
    }

    func testOnlineVoteIdentityPolicyFindsCurrentVoteCaseInsensitively() throws {
        let room = GameRoom.previewRoom(status: "voting")
        let currentPlayer = try XCTUnwrap(room.activePlayers.first)
        let vote = VoteRecord(
            voterEmail: currentPlayer.email.uppercased(),
            votedForEmail: room.activePlayers[1].email
        )

        XCTAssertEqual(
            OnlineVoteIdentityPolicy.currentUserVote(
                in: [vote],
                currentUserEmail: " \(currentPlayer.email) "
            ),
            vote
        )
    }

    func testQuestionAskerConfirmsBeforeAdvance() {
        var room = GameRoom.previewRoom(status: "playing")
        room.questionPhase = "asking"

        XCTAssertEqual(
            room.onlineRoundCommand(
                for: room.currentAskerEmail,
                isHost: true,
                isTransitioning: false
            ),
            .markAnswerHeard
        )
        XCTAssertNil(
            room.onlineRoundCommand(
                for: room.currentAnswererEmail,
                isHost: false,
                isTransitioning: false
            )
        )
    }

    func testLegacyCountdownAdvancesImmediatelyAndOnlyAskerAdvances() {
        var room = GameRoom.previewRoom(status: "playing")
        let startedAt = Date(timeIntervalSince1970: 1_000)
        room.questionPhase = "countdown"
        room.countdownStartedAt = ISO8601DateFormatter().string(from: startedAt)

        XCTAssertEqual(room.countdownRemaining(at: startedAt.addingTimeInterval(2)), 0, accuracy: 0.001)
        XCTAssertTrue(
            room.shouldAdvanceQuestionAfterCountdown(
                for: room.currentAskerEmail,
                at: startedAt.addingTimeInterval(5)
            )
        )
        XCTAssertFalse(
            room.shouldAdvanceQuestionAfterCountdown(
                for: room.currentAnswererEmail,
                at: startedAt.addingTimeInterval(5)
            )
        )
    }

    func testResultsCanContinueFromAnyAuthenticatedPlayer() {
        var room = GameRoom.previewRoom(status: "playing")
        room.questionPhase = "results"
        let participant = try! XCTUnwrap(room.playersList.last)

        XCTAssertEqual(
            room.onlineRoundCommand(
                for: participant.email.uppercased(),
                isHost: false,
                isTransitioning: false
            ),
            .continueRound
        )
    }

    func testAssociationStateAndCommandsMatchServerContract() throws {
        var room = GameRoom.previewRoom(status: "playing")
        room.gameMode = "associations"
        room.currentAskerEmail = nil
        room.currentAnswer = AssociationRoundState.idle.encodedValue

        XCTAssertEqual(
            room.onlineRoundCommand(
                for: room.hostEmail,
                isHost: true,
                isTransitioning: false
            ),
            .startAssociation
        )

        let speaker = try XCTUnwrap(room.playersList.last)
        room.currentAskerEmail = speaker.email
        room.currentAnswer = AssociationRoundState(spoken: [room.playersList[0].email], spinning: false).encodedValue
        XCTAssertEqual(room.associationRoundState.spoken, [room.playersList[0].email])
        XCTAssertEqual(
            room.onlineRoundCommand(
                for: speaker.email,
                isHost: false,
                isTransitioning: false
            ),
            .advanceAssociation
        )

        room.currentAnswer = AssociationRoundState(spoken: [], spinning: true).encodedValue
        XCTAssertNil(
            room.onlineRoundCommand(
                for: speaker.email,
                isHost: false,
                isTransitioning: false
            )
        )
        XCTAssertTrue(room.canStopAssociationSpin(for: speaker.email, isHost: false))
        XCTAssertEqual(room.associationSpinSettlementDelay(for: speaker.email), 0.5)
        XCTAssertTrue(
            room.canStopAssociationSpin(
                for: room.playersList[0].email,
                isHost: false
            ),
            "Every active client must be able to recover a stuck spin."
        )
        XCTAssertEqual(room.associationSpinSettlementDelay(for: room.playersList[0].email), 1.0)
        XCTAssertEqual(room.associationSpinSettlementDelay(for: room.playersList[1].email), 1.5)
        XCTAssertFalse(room.canStopAssociationSpin(for: "outside@example.com", isHost: false))
        XCTAssertNil(room.associationSpinSettlementDelay(for: "outside@example.com"))

        room.spectators = [room.playersList[0].email]
        XCTAssertFalse(
            room.canStopAssociationSpin(
                for: room.playersList[0].email,
                isHost: true
            ),
            "Spectators cannot mutate the round."
        )
        XCTAssertNil(room.associationSpinSettlementDelay(for: room.playersList[0].email))
    }

    func testMalformedLegacyAssociationStateFallsBackToIdle() {
        var room = GameRoom.previewRoom(status: "playing")
        room.gameMode = "associations"
        room.currentAnswer = "legacy free-form answer"

        XCTAssertEqual(room.associationRoundState, .idle)
    }

    func testRoomRefreshFailureTrackerWarnsOnceAndRecoversOnce() {
        var tracker = RoomRefreshFailureTracker()

        XCTAssertFalse(tracker.recordFailure())
        XCTAssertFalse(tracker.recordFailure())
        XCTAssertTrue(tracker.recordFailure())
        XCTAssertFalse(tracker.recordFailure())
        XCTAssertEqual(tracker.consecutiveFailures, 4)

        XCTAssertTrue(tracker.recordSuccess())
        XCTAssertFalse(tracker.recordSuccess())
        XCTAssertEqual(tracker.consecutiveFailures, 0)

        XCTAssertFalse(tracker.recordFailure())
        XCTAssertFalse(tracker.recordFailure())
        XCTAssertTrue(tracker.recordFailure())
    }

    func testRoomMonitorDiscardsInFlightSnapshotWithoutStoppingDuringLocalOperation() {
        XCTAssertEqual(
            RoomPollPolicy.disposition(
                monitoredRoomID: "room-1",
                activeRoomID: "room-1",
                isCancelled: false,
                hasActiveOperation: true,
                fetchedRoomExists: true
            ),
            .discardAndContinue
        )
        XCTAssertEqual(
            RoomPollPolicy.disposition(
                monitoredRoomID: "room-1",
                activeRoomID: "room-1",
                isCancelled: false,
                hasActiveOperation: false,
                isLatestRefreshRequest: false,
                fetchedRoomExists: true
            ),
            .discardAndContinue
        )
        XCTAssertEqual(
            RoomPollPolicy.disposition(
                monitoredRoomID: "room-1",
                activeRoomID: "room-2",
                isCancelled: false,
                hasActiveOperation: false,
                fetchedRoomExists: true
            ),
            .stop
        )
        XCTAssertEqual(
            RoomPollPolicy.disposition(
                monitoredRoomID: "room-1",
                activeRoomID: "room-1",
                isCancelled: false,
                hasActiveOperation: false,
                fetchedRoomExists: false
            ),
            .close
        )
        XCTAssertEqual(
            RoomPollPolicy.disposition(
                monitoredRoomID: "room-1",
                activeRoomID: "room-1",
                isCancelled: false,
                hasActiveOperation: false,
                didRoomSyncRevisionChange: true,
                fetchedRoomExists: true
            ),
            .discardAndContinue
        )
    }

    func testRoomPollPolicyUsesRealtimeFallbackCadenceAndBoundedFailureBackoff() {
        XCTAssertEqual(
            RoomPollPolicy.delaySeconds(
                roomStatus: "waiting",
                consecutiveFailures: 0,
                isApplicationActive: true
            ),
            2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RoomPollPolicy.delaySeconds(
                roomStatus: "playing",
                consecutiveFailures: 0,
                isApplicationActive: true
            ),
            2,
            accuracy: 0.001
        )
        XCTAssertEqual(RoomPollPolicy.delaySeconds(roomStatus: "waiting", consecutiveFailures: 1, isApplicationActive: true), 4)
        XCTAssertEqual(RoomPollPolicy.delaySeconds(roomStatus: "waiting", consecutiveFailures: 2, isApplicationActive: true), 8)
        XCTAssertEqual(RoomPollPolicy.delaySeconds(roomStatus: "waiting", consecutiveFailures: 8, isApplicationActive: true), 30)
        XCTAssertEqual(RoomPollPolicy.delaySeconds(roomStatus: "waiting", consecutiveFailures: 0, isApplicationActive: false), 20)
    }

    func testRoomPollPolicyRejectsLobbySnapshotOlderThanCurrentRevision() {
        XCTAssertFalse(
            RoomPollPolicy.acceptsSnapshot(
                currentLobbyRevision: 9,
                fetchedLobbyRevision: 8
            )
        )
        XCTAssertTrue(
            RoomPollPolicy.acceptsSnapshot(
                currentLobbyRevision: 9,
                fetchedLobbyRevision: 9
            )
        )
        XCTAssertTrue(
            RoomPollPolicy.acceptsSnapshot(
                currentLobbyRevision: nil,
                fetchedLobbyRevision: nil
            )
        )
    }
}

final class ShellSupplementaryRefreshPolicyTests: XCTestCase {
    func testSupplementaryNetworkTrafficStopsForRealtimeGameplay() {
        XCTAssertFalse(
            ShellSupplementaryRefreshPolicy.shouldRun(activeRoomStatus: "roulette")
        )
        XCTAssertFalse(
            ShellSupplementaryRefreshPolicy.shouldRun(activeRoomStatus: "PLAYING")
        )
        XCTAssertTrue(
            ShellSupplementaryRefreshPolicy.shouldRun(activeRoomStatus: "waiting")
        )
        XCTAssertTrue(
            ShellSupplementaryRefreshPolicy.shouldRun(activeRoomStatus: nil)
        )
    }
}

final class LobbyLatestWinsStateTests: XCTestCase {
    func testNewDurationIntentDoesNotWaitForPriorRequestToFinish() throws {
        var state = LobbyLatestWinsState()
        state.reset(confirmedRevision: 4)
        state.enqueue(roomID: "room-1", state: payload(duration: 480))
        let first = try XCTUnwrap(state.beginNext())

        state.enqueue(roomID: "room-1", state: payload(duration: 720))

        XCTAssertTrue(state.hasOptimisticChanges)
        XCTAssertFalse(state.finish(first, confirmedRevision: 5))
        let second = try XCTUnwrap(state.beginNext())
        XCTAssertEqual(second.expectedRevision, 5)
        XCTAssertEqual(second.intent.state.gameDurationSeconds, 720)
        XCTAssertTrue(state.finish(second, confirmedRevision: 6))
        XCTAssertFalse(state.hasOptimisticChanges)
    }

    func testSuccessfulRequestRecordsServerConfirmedMutation() throws {
        var state = LobbyLatestWinsState()
        let mutationID = UUID()
        state.reset(confirmedRevision: 4)
        state.enqueue(
            roomID: "room-1",
            state: payload(duration: 480),
            mutationID: mutationID
        )
        let request = try XCTUnwrap(state.beginNext())

        XCTAssertTrue(state.finish(request, confirmedRevision: 5))
        XCTAssertEqual(state.lastServerConfirmedMutationID, mutationID)
    }

    func testFailedRequestDoesNotRecordServerConfirmation() throws {
        var state = LobbyLatestWinsState()
        state.reset(confirmedRevision: 4)
        state.enqueue(roomID: "room-1", state: payload(duration: 480))
        let request = try XCTUnwrap(state.beginNext())

        XCTAssertFalse(state.fail(request, retry: false))
        XCTAssertNil(state.lastServerConfirmedMutationID)
    }

    func testUnadvancedRevisionDoesNotRecordServerConfirmation() throws {
        var state = LobbyLatestWinsState()
        state.reset(confirmedRevision: 4)
        state.enqueue(roomID: "room-1", state: payload(duration: 480))
        let request = try XCTUnwrap(state.beginNext())

        XCTAssertFalse(state.finish(request, confirmedRevision: 4))
        XCTAssertFalse(state.hasOptimisticChanges)
        XCTAssertNil(state.lastServerConfirmedMutationID)
    }

    func testRecoveredCommittedRequestRecordsServerConfirmation() throws {
        var state = LobbyLatestWinsState()
        let mutationID = UUID()
        state.reset(confirmedRevision: 4)
        state.enqueue(
            roomID: "room-1",
            state: payload(duration: 480),
            mutationID: mutationID
        )
        let request = try XCTUnwrap(state.beginNext())
        _ = state.fail(request, retry: false)

        XCTAssertTrue(
            state.recordRecoveredServerConfirmation(
                request,
                confirmedRevision: 5
            )
        )
        XCTAssertEqual(state.lastServerConfirmedMutationID, mutationID)
    }

    func testPendingIntentCoalescesToLatestModeAndDuration() throws {
        var state = LobbyLatestWinsState()
        state.enqueue(roomID: "room-1", state: payload(duration: 300))
        state.enqueue(
            roomID: "room-1",
            state: payload(duration: 600, mode: .associations)
        )

        let request = try XCTUnwrap(state.beginNext())
        XCTAssertEqual(request.intent.state.gameDurationSeconds, 600)
        XCTAssertEqual(request.intent.state.gameMode, .associations)
    }

    func testIdenticalLatestPayloadIsRecognizedWithoutCreatingRevisionChurn() throws {
        var state = LobbyLatestWinsState()
        let current = payload(duration: 300)

        state.enqueue(roomID: "room-1", state: current)
        XCTAssertTrue(state.latestStateMatches(roomID: "room-1", state: current))

        _ = try XCTUnwrap(state.beginNext())
        XCTAssertTrue(state.latestStateMatches(roomID: "room-1", state: current))
        XCTAssertFalse(
            state.latestStateMatches(
                roomID: "room-1",
                state: payload(duration: 360)
            )
        )
    }

    func testConflictRetryKeepsMutationIdentityAndUsesFreshRevision() throws {
        var state = LobbyLatestWinsState()
        state.reset(confirmedRevision: 7)
        state.enqueue(roomID: "room-1", state: payload(duration: 360))
        let first = try XCTUnwrap(state.beginNext())

        XCTAssertTrue(state.fail(first, retry: true))
        state.reconcile(confirmedRevision: 9)
        let retry = try XCTUnwrap(state.beginNext())

        XCTAssertEqual(retry.intent.mutationID, first.intent.mutationID)
        XCTAssertEqual(retry.expectedRevision, 9)
        XCTAssertEqual(retry.intent.retryCount, 1)
    }

    func testPendingIntentClearsWhenUserReturnsToConfirmedState() {
        var state = LobbyLatestWinsState()
        let confirmed = payload(duration: 300)

        XCTAssertTrue(
            state.enqueueLatest(
                roomID: "room-1",
                state: payload(duration: 600),
                confirmedState: confirmed
            )
        )
        XCTAssertFalse(
            state.enqueueLatest(
                roomID: "room-1",
                state: confirmed,
                confirmedState: confirmed
            )
        )
        XCTAssertFalse(state.hasOptimisticChanges)
    }

    func testReturningToInflightStateDropsNewerPendingIntent() throws {
        var state = LobbyLatestWinsState()
        let inflightState = payload(duration: 300)
        state.enqueue(roomID: "room-1", state: inflightState)
        _ = try XCTUnwrap(state.beginNext())

        _ = state.enqueueLatest(
            roomID: "room-1",
            state: payload(duration: 600),
            confirmedState: payload(duration: 900)
        )
        XCTAssertTrue(state.hasPendingIntent)

        XCTAssertFalse(
            state.enqueueLatest(
                roomID: "room-1",
                state: inflightState,
                confirmedState: payload(duration: 900)
            )
        )
        XCTAssertFalse(state.hasPendingIntent)
        XCTAssertTrue(state.hasOptimisticChanges)
    }

    func testServerWordIDsDoNotCreateSemanticLobbyChange() {
        var local = payload(duration: 300)
        local.lobbyWordSource = .manual
        local.lobbyWordCount = 2
        local.lobbyWordPool = [
            LobbyWordPoolEntry(word: "  Cafe\u{301}   Noir ", enabled: true),
            LobbyWordPoolEntry(word: "Cipher", enabled: false)
        ]
        var server = local
        server.lobbyWordPool = [
            LobbyWordPoolEntry(id: "lw_1", word: "Café Noir", enabled: true),
            LobbyWordPoolEntry(id: "lw_2", word: "Cipher", enabled: false)
        ]

        XCTAssertTrue(local.equivalentForLobbySync(to: server))
    }

    func testSpyCountAndTeammateKnowledgeAreSemanticLobbyChanges() {
        let baseline = payload(duration: 300)
        var twoSpies = baseline
        twoSpies.spyCount = 2
        var knownTeammates = baseline
        knownTeammates.spiesKnowEachOther = true

        XCTAssertFalse(baseline.equivalentForLobbySync(to: twoSpies))
        XCTAssertFalse(baseline.equivalentForLobbySync(to: knownTeammates))
    }

    private func payload(
        duration: Int,
        mode: SpyGameMode = .questions
    ) -> LobbyStatePayload {
        LobbyStatePayload(
            gameMode: mode,
            gameDurationSeconds: duration,
            lobbyWordSource: .none,
            lobbySourcePackID: nil,
            lobbySourceName: nil,
            lobbyTheme: nil,
            lobbyCategory: nil,
            lobbyWordCount: 0,
            lobbyWordCountMode: .recommended,
            lobbyWordPool: []
        )
    }
}

final class LobbySyncFeedbackStateTests: XCTestCase {
    func testPendingThenConfirmedShowsServerConfirmation() {
        let mutationID = UUID()
        var state = LobbySyncFeedbackState()

        state.update(snapshot(pending: false, confirmationID: nil))
        state.update(snapshot(pending: true, confirmationID: nil))
        XCTAssertEqual(state.phase, .syncing)

        state.update(snapshot(pending: false, confirmationID: mutationID))
        XCTAssertEqual(state.phase, .serverConfirmed(mutationID))
    }

    func testPendingThenFailureDoesNotShowConfirmation() {
        var state = LobbySyncFeedbackState()

        state.update(snapshot(pending: false, confirmationID: nil))
        state.update(snapshot(pending: true, confirmationID: nil))
        state.update(snapshot(pending: false, confirmationID: nil))

        XCTAssertEqual(state.phase, .hidden)
    }

    func testNewEditReplacesConfirmationAndFailedEditDoesNotRestoreIt() {
        let firstMutationID = UUID()
        var state = LobbySyncFeedbackState()

        state.update(snapshot(pending: false, confirmationID: nil))
        state.update(snapshot(pending: true, confirmationID: nil))
        state.update(snapshot(pending: false, confirmationID: firstMutationID))
        XCTAssertEqual(state.phase, .serverConfirmed(firstMutationID))

        state.update(snapshot(pending: true, confirmationID: firstMutationID))
        XCTAssertEqual(state.phase, .syncing)

        state.update(snapshot(pending: false, confirmationID: firstMutationID))
        XCTAssertEqual(state.phase, .hidden)
    }

    func testIntermediateConfirmationDoesNotBecomeSuccessAfterNewerEditFails() {
        let intermediateMutationID = UUID()
        var state = LobbySyncFeedbackState()

        state.update(snapshot(pending: false, confirmationID: nil))
        state.update(snapshot(pending: true, confirmationID: nil))
        state.update(snapshot(pending: true, confirmationID: intermediateMutationID))
        state.update(snapshot(pending: false, confirmationID: intermediateMutationID))

        XCTAssertEqual(state.phase, .hidden)
    }

    func testOldDismissalCannotHideNewerServerConfirmation() {
        let firstMutationID = UUID()
        let secondMutationID = UUID()
        var state = LobbySyncFeedbackState()

        state.update(snapshot(pending: false, confirmationID: nil))
        state.update(snapshot(pending: true, confirmationID: nil))
        state.update(snapshot(pending: false, confirmationID: firstMutationID))
        state.update(snapshot(pending: true, confirmationID: firstMutationID))
        state.update(snapshot(pending: false, confirmationID: secondMutationID))

        state.dismissServerConfirmation(firstMutationID)

        XCTAssertEqual(state.phase, .serverConfirmed(secondMutationID))
    }

    private func snapshot(
        pending: Bool,
        confirmationID: UUID?
    ) -> LobbySyncFeedbackSnapshot {
        LobbySyncFeedbackSnapshot(
            roomID: "room-1",
            hasOptimisticChanges: pending,
            lastServerConfirmedMutationID: confirmationID
        )
    }
}

final class WaitingStartActionModeTests: XCTestCase {
    func testSyncSequenceBlocksStartUntilConfirmationDwellEnds() {
        let confirmationID = UUID()

        XCTAssertEqual(
            mode(feedbackPhase: .hidden),
            .action
        )
        XCTAssertEqual(
            mode(feedbackPhase: .syncing, hasOptimisticChanges: true),
            .syncing
        )
        XCTAssertEqual(
            mode(feedbackPhase: .serverConfirmed(confirmationID)),
            .serverConfirmed(confirmationID)
        )
        XCTAssertTrue(WaitingStartActionMode.syncing.blocksStart)
        XCTAssertTrue(WaitingStartActionMode.serverConfirmed(confirmationID).blocksStart)
        XCTAssertFalse(WaitingStartActionMode.action.blocksStart)
    }

    func testNewEditImmediatelyReplacesSavedStateWithSyncing() {
        let resolved = mode(
            feedbackPhase: .serverConfirmed(UUID()),
            isEditingLobbySlider: true
        )

        XCTAssertEqual(resolved, .syncing)
        XCTAssertTrue(resolved.blocksStart)
    }

    func testFailureReplacesStartAndRemainsBlocked() {
        let resolved = mode(
            feedbackPhase: .syncing,
            hasSyncFailure: true
        )

        XCTAssertEqual(resolved, .failed)
        XCTAssertTrue(resolved.blocksStart)
    }

    func testReadyLobbyWithoutAuthoritativeConfirmationShowsSyncing() {
        XCTAssertEqual(
            mode(
                feedbackPhase: .hidden,
                requiresServerConfirmation: true,
                isServerConfirmed: false
            ),
            .syncing
        )
        XCTAssertEqual(
            mode(
                feedbackPhase: .serverConfirmed(UUID()),
                requiresServerConfirmation: true,
                isServerConfirmed: false
            ),
            .syncing
        )
    }

    private func mode(
        feedbackPhase: LobbySyncFeedbackPhase,
        isEditingLobbySlider: Bool = false,
        hasOptimisticChanges: Bool = false,
        hasSyncFailure: Bool = false,
        requiresServerConfirmation: Bool = false,
        isServerConfirmed: Bool = true
    ) -> WaitingStartActionMode {
        WaitingStartActionMode.resolve(
            feedbackPhase: feedbackPhase,
            isEditingLobbySlider: isEditingLobbySlider,
            hasOptimisticChanges: hasOptimisticChanges,
            hasSyncFailure: hasSyncFailure,
            requiresServerConfirmation: requiresServerConfirmation,
            isServerConfirmed: isServerConfirmed
        )
    }
}

final class LobbyStartGateTests: XCTestCase {
    func testAvailableAppearanceRequiresAllStartPrerequisites() {
        XCTAssertFalse(
            LobbyStartGate.hasPrerequisites(
                playerCount: 2,
                isThemeSelectionReady: true,
                isGeneratingRoomTheme: false
            )
        )
        XCTAssertFalse(
            LobbyStartGate.hasPrerequisites(
                playerCount: 3,
                isThemeSelectionReady: false,
                isGeneratingRoomTheme: false
            )
        )
        XCTAssertFalse(
            LobbyStartGate.hasPrerequisites(
                playerCount: 3,
                isThemeSelectionReady: true,
                isGeneratingRoomTheme: true
            )
        )
        XCTAssertTrue(
            LobbyStartGate.hasPrerequisites(
                playerCount: 3,
                isThemeSelectionReady: true,
                isGeneratingRoomTheme: false
            )
        )
    }

    func testRequiresPositiveRevisionAndMatchingAuthoritativeState() {
        let confirmed = payload(duration: 600)

        XCTAssertFalse(isConfirmed(revision: 0, authoritative: confirmed, local: confirmed))
        XCTAssertTrue(isConfirmed(revision: 4, authoritative: confirmed, local: confirmed))
        XCTAssertFalse(
            isConfirmed(
                revision: 4,
                authoritative: confirmed,
                local: payload(duration: 720)
            )
        )
    }

    func testEditingPendingAndFailureEachBlockStart() {
        let confirmed = payload(duration: 600)

        XCTAssertFalse(
            isConfirmed(
                revision: 4,
                authoritative: confirmed,
                local: confirmed,
                isEditingLobbySlider: true
            )
        )
        XCTAssertFalse(
            isConfirmed(
                revision: 4,
                authoritative: confirmed,
                local: confirmed,
                hasOptimisticChanges: true
            )
        )
        XCTAssertFalse(
            isConfirmed(
                revision: 4,
                authoritative: confirmed,
                local: confirmed,
                hasSyncFailure: true
            )
        )
    }

    private func isConfirmed(
        revision: Int,
        authoritative: LobbyStatePayload?,
        local: LobbyStatePayload,
        isEditingLobbySlider: Bool = false,
        hasOptimisticChanges: Bool = false,
        hasSyncFailure: Bool = false
    ) -> Bool {
        LobbyStartGate.isServerConfirmed(
            roomRevision: revision,
            authoritativeState: authoritative,
            localState: local,
            hasOptimisticChanges: hasOptimisticChanges,
            hasSyncFailure: hasSyncFailure,
            isEditingLobbySlider: isEditingLobbySlider
        )
    }

    private func payload(duration: Int) -> LobbyStatePayload {
        LobbyStatePayload(
            gameMode: .questions,
            gameDurationSeconds: duration,
            lobbyWordSource: .manual,
            lobbySourcePackID: nil,
            lobbySourceName: "Manual",
            lobbyTheme: "Cities",
            lobbyCategory: "Cities",
            lobbyWordCount: 2,
            lobbyWordCountMode: .custom,
            lobbyWordPool: [
                LobbyWordPoolEntry(word: "Kyiv", enabled: true),
                LobbyWordPoolEntry(word: "London", enabled: true)
            ]
        )
    }
}

final class LobbyPresentationPolicyTests: XCTestCase {
    func testPoolPreviewIsHiddenOnlyWhenTotalPoolIsEmpty() {
        XCTAssertFalse(
            LobbyPresentationPolicy.shouldShowPoolPreview(totalWordCount: 0)
        )
        XCTAssertTrue(
            LobbyPresentationPolicy.shouldShowPoolPreview(totalWordCount: 4)
        )
    }

    func testOnlyNewRemoteGuestRevisionAnimates() {
        XCTAssertTrue(
            shouldAnimate(appliedRevision: 7, incomingRevision: 8)
        )
        XCTAssertFalse(
            shouldAnimate(isHost: true, appliedRevision: 7, incomingRevision: 8)
        )
        XCTAssertFalse(
            shouldAnimate(reduceMotion: true, appliedRevision: 7, incomingRevision: 8)
        )
        XCTAssertFalse(
            shouldAnimate(isConfiguredRoom: false, appliedRevision: 7, incomingRevision: 8)
        )
        XCTAssertFalse(
            shouldAnimate(isEditingLobbySlider: true, appliedRevision: 7, incomingRevision: 8)
        )
        XCTAssertFalse(
            shouldAnimate(appliedRevision: -1, incomingRevision: 8)
        )
        XCTAssertFalse(
            shouldAnimate(appliedRevision: 8, incomingRevision: 8)
        )
        XCTAssertFalse(
            shouldAnimate(appliedRevision: 9, incomingRevision: 8)
        )
    }

    func testAnyActiveSliderDefersWholeAuthoritativeSnapshot() {
        XCTAssertFalse(
            LobbyPresentationPolicy.shouldDeferAuthoritativeUpdate(
                isDraggingDuration: false,
                isDraggingWordCount: false
            )
        )
        XCTAssertTrue(
            LobbyPresentationPolicy.shouldDeferAuthoritativeUpdate(
                isDraggingDuration: true,
                isDraggingWordCount: false
            )
        )
        XCTAssertTrue(
            LobbyPresentationPolicy.shouldDeferAuthoritativeUpdate(
                isDraggingDuration: false,
                isDraggingWordCount: true
            )
        )
    }

    func testDeferredAuthoritativeUpdateLatchesForcedRollbackUntilApplied() {
        var deferred = DeferredLobbyUpdateState()

        deferred.record(force: false)
        XCTAssertTrue(deferred.isPending)
        XCTAssertFalse(deferred.requiresForce)

        deferred.record(force: true)
        XCTAssertTrue(deferred.isPending)
        XCTAssertTrue(deferred.requiresForce)

        deferred.record(force: false)
        XCTAssertTrue(deferred.requiresForce)

        deferred.clear()
        XCTAssertFalse(deferred.isPending)
        XCTAssertFalse(deferred.requiresForce)
    }

    func testUnrelatedModeAndDurationUpdateDoesNotCollapseExpandedPool() {
        let original = payload(
            mode: .questions,
            duration: 300,
            theme: "Cities"
        )
        let settingsOnlyUpdate = payload(
            mode: .associations,
            duration: 600,
            theme: "Cities"
        )
        let differentPool = payload(
            mode: .associations,
            duration: 600,
            theme: "Comic-book heroes"
        )

        XCTAssertFalse(shouldResetExpandedPool(from: original, to: settingsOnlyUpdate))
        XCTAssertTrue(shouldResetExpandedPool(from: original, to: differentPool))
    }

    func testPoolExpansionStaysOpenButSameThemeReplacementCollapses() {
        let original = payload(
            mode: .questions,
            duration: 300,
            theme: "Cities"
        )
        var expanded = original
        expanded.lobbyWordPool.append(
            LobbyWordPoolEntry(word: "Bratislava", enabled: true)
        )
        var replacement = original
        replacement.lobbyWordPool = [
            LobbyWordPoolEntry(word: "Paris", enabled: true),
            LobbyWordPoolEntry(word: "Madrid", enabled: true)
        ]

        XCTAssertFalse(shouldResetExpandedPool(from: original, to: expanded))
        XCTAssertTrue(shouldResetExpandedPool(from: original, to: replacement))
    }

    func testSavedPackAndGeneratedSourceChangesCollapseExpandedPool() {
        var savedA = payload(
            mode: .questions,
            duration: 300,
            theme: "Cities"
        )
        savedA.lobbyWordSource = .saved
        savedA.lobbySourcePackID = "pack-a"
        var savedB = savedA
        savedB.lobbySourcePackID = "pack-b"
        var ai = savedA
        ai.lobbyWordSource = .ai
        ai.lobbySourcePackID = nil

        XCTAssertTrue(shouldResetExpandedPool(from: savedA, to: savedB))
        XCTAssertTrue(shouldResetExpandedPool(from: savedA, to: ai))
    }

    func testPresentationSnapshotCarriesWholeLobbyRevision() {
        let state = payload(
            mode: .associations,
            duration: 720,
            theme: "Comic-book heroes"
        )
        let snapshot = LobbyPresentationSnapshot(
            roomID: "room-1",
            revision: 12,
            state: state
        )

        XCTAssertEqual(snapshot.revision, 12)
        XCTAssertEqual(snapshot.state.gameMode, .associations)
        XCTAssertEqual(snapshot.state.gameDurationSeconds, 720)
        XCTAssertEqual(snapshot.state.lobbyWordCount, 2)
        XCTAssertEqual(snapshot.state.lobbyWordPool.map(\.word), ["Kyiv", "London"])
    }

    private func shouldAnimate(
        isHost: Bool = false,
        reduceMotion: Bool = false,
        isConfiguredRoom: Bool = true,
        isEditingLobbySlider: Bool = false,
        appliedRevision: Int,
        incomingRevision: Int
    ) -> Bool {
        LobbyPresentationPolicy.shouldAnimateRemoteUpdate(
            isHost: isHost,
            reduceMotion: reduceMotion,
            isConfiguredRoom: isConfiguredRoom,
            isEditingLobbySlider: isEditingLobbySlider,
            appliedRevision: appliedRevision,
            incomingRevision: incomingRevision
        )
    }

    private func payload(
        mode: SpyGameMode,
        duration: Int,
        theme: String
    ) -> LobbyStatePayload {
        LobbyStatePayload(
            gameMode: mode,
            gameDurationSeconds: duration,
            lobbyWordSource: .manual,
            lobbySourcePackID: nil,
            lobbySourceName: theme,
            lobbyTheme: theme,
            lobbyCategory: theme,
            lobbyWordCount: 2,
            lobbyWordCountMode: .custom,
            lobbyWordPool: [
                LobbyWordPoolEntry(word: "Kyiv", enabled: true),
                LobbyWordPoolEntry(word: "London", enabled: false)
            ]
        )
    }

    private func shouldResetExpandedPool(
        from current: LobbyStatePayload,
        to incoming: LobbyStatePayload
    ) -> Bool {
        LobbyPresentationPolicy.shouldResetExpandedPool(
            current: LobbyPoolIdentity(state: current),
            incoming: LobbyPoolIdentity(state: incoming),
            currentWordKeys: Set(current.lobbyWordPool.map { $0.word.lowercased() }),
            incomingWordKeys: Set(incoming.lobbyWordPool.map { $0.word.lowercased() })
        )
    }
}

final class LobbySyncRetryPolicyTests: XCTestCase {
    func testOnlyTypedPreActionLeaseConflictsRetryRoomActions() {
        XCTAssertTrue(
            Base44Error(
                message: "Account identity is being updated.",
                statusCode: 409,
                code: "active_lease",
                retryable: true
            ).isRetryableRoomActionConflict
        )
        XCTAssertFalse(
            Base44Error(
                message: "Account identity is being updated.",
                statusCode: 409
            ).isRetryableRoomActionConflict
        )
        XCTAssertFalse(
            Base44Error(
                message: "Room changed",
                statusCode: 409,
                code: "lobby_revision_conflict",
                retryable: true
            ).isRetryableRoomActionConflict
        )
    }

    func testOnlyTypedLobbyConflictTriggersRevisionRefresh() {
        XCTAssertTrue(
            LobbySyncRetryPolicy.isRevisionConflict(
                Base44Error(
                    message: "Room changed",
                    statusCode: 409,
                    code: "lobby_revision_conflict"
                )
            )
        )
        XCTAssertFalse(
            LobbySyncRetryPolicy.isRevisionConflict(
                Base44Error(
                    message: "Ready voting started",
                    statusCode: 409,
                    code: "room_status_conflict"
                )
            )
        )
    }

    func testTransientNetworkLossAndServerFailureAreRetryable() {
        XCTAssertTrue(
            LobbySyncRetryPolicy.isRetryable(
                URLError(.networkConnectionLost)
            )
        )
        XCTAssertTrue(
            LobbySyncRetryPolicy.isRetryable(
                Base44Error(message: "Unavailable", statusCode: 503)
            )
        )
        XCTAssertFalse(
            LobbySyncRetryPolicy.isRetryable(
                Base44Error(message: "Invalid", statusCode: 422)
            )
        )
        XCTAssertFalse(
            LobbySyncRetryPolicy.isRetryable(
                URLError(.cancelled)
            )
        )
    }
}

final class LobbyDraftPoolPolicyTests: XCTestCase {
    func testInvalidatedGeneratedDraftDoesNotReusePreviousAuthoritativePool() {
        XCTAssertEqual(
            LobbyDraftPoolPolicy.generatedPayloadWords(
                localWords: nil,
                priorAuthoritativeWords: ["Embassy", "Cipher"]
            ),
            []
        )
        XCTAssertEqual(
            LobbyDraftPoolPolicy.generatedPayloadWords(
                localWords: ["Orbit", "Comet"],
                priorAuthoritativeWords: ["Embassy", "Cipher"]
            ),
            ["Orbit", "Comet"]
        )
    }
}

final class GameRoomRealtimeSignalParserTests: XCTestCase {
    func testAcceptsOnlyExactUserRoomAndEntityEnvelope() throws {
        let entityRoom = "entities:app-1:GameRoomSignal"
        let event: [String: Any] = [
            "type": "update",
            "id": "signal-1",
            "data": [
                "user_id": "user-1",
                "room_id": "room-1",
                "lobby_revision": 8,
                "room_revision": 14,
                "room_updated_at": "2026-08-06T12:00:00.000Z",
                "state": "active"
            ]
        ]
        let encoded = try JSONSerialization.data(withJSONObject: event)
        let envelope: [String: Any] = [
            "room": entityRoom,
            "data": try XCTUnwrap(String(data: encoded, encoding: .utf8))
        ]

        XCTAssertEqual(
            GameRoomRealtimeSignalParser.parse(
                payload: [envelope],
                expectedEntityRoom: entityRoom,
                expectedUserID: "user-1",
                expectedRoomID: "room-1"
            ),
            GameRoomRealtimeSignal(
                roomID: "room-1",
                lobbyRevision: 8,
                roomRevision: 14,
                roomUpdatedAt: "2026-08-06T12:00:00.000Z",
                state: "active"
            )
        )
        XCTAssertNil(
            GameRoomRealtimeSignalParser.parse(
                payload: [envelope],
                expectedEntityRoom: entityRoom,
                expectedUserID: "user-2",
                expectedRoomID: "room-1"
            )
        )
        XCTAssertNil(
            GameRoomRealtimeSignalParser.parse(
                payload: [envelope],
                expectedEntityRoom: entityRoom,
                expectedUserID: "user-1",
                expectedRoomID: "room-2"
            )
        )
    }

    func testAcceptsZeroAndRejectsMalformedOrNegativeRevision() throws {
        let entityRoom = "entities:app-1:GameRoomSignal"
        let event: [String: Any] = [
            "type": "update",
            "data": [
                "user_id": "user-1",
                "room_id": "room-1",
                "lobby_revision": 0,
                "state": "active"
            ]
        ]
        let encoded = try JSONSerialization.data(withJSONObject: event)
        let envelope: [String: Any] = [
            "room": entityRoom,
            "data": try XCTUnwrap(String(data: encoded, encoding: .utf8))
        ]

        XCTAssertEqual(
            GameRoomRealtimeSignalParser.parse(
                payload: [envelope],
                expectedEntityRoom: entityRoom,
                expectedUserID: "user-1",
                expectedRoomID: "room-1"
            ),
            GameRoomRealtimeSignal(
                roomID: "room-1",
                lobbyRevision: 0,
                roomRevision: nil,
                roomUpdatedAt: nil,
                state: "active"
            )
        )
        XCTAssertNil(
            GameRoomRealtimeSignalParser.parse(
                payload: [["room": entityRoom, "data": "not-json"]],
                expectedEntityRoom: entityRoom,
                expectedUserID: "user-1",
                expectedRoomID: "room-1"
            )
        )

        var oversizedEvent = event
        var oversizedData = try XCTUnwrap(oversizedEvent["data"] as? [String: Any])
        oversizedData["lobby_revision"] = 1e20
        oversizedEvent["data"] = oversizedData
        let oversizedEncoded = try JSONSerialization.data(withJSONObject: oversizedEvent)
        let oversizedEnvelope: [String: Any] = [
            "room": entityRoom,
            "data": try XCTUnwrap(String(data: oversizedEncoded, encoding: .utf8))
        ]
        XCTAssertNil(
            GameRoomRealtimeSignalParser.parse(
                payload: [oversizedEnvelope],
                expectedEntityRoom: entityRoom,
                expectedUserID: "user-1",
                expectedRoomID: "room-1"
            )
        )

        var negativeEvent = event
        var negativeData = try XCTUnwrap(negativeEvent["data"] as? [String: Any])
        negativeData["lobby_revision"] = -1
        negativeEvent["data"] = negativeData
        let negativeEncoded = try JSONSerialization.data(withJSONObject: negativeEvent)
        let negativeEnvelope: [String: Any] = [
            "room": entityRoom,
            "data": try XCTUnwrap(String(data: negativeEncoded, encoding: .utf8))
        ]
        XCTAssertNil(
            GameRoomRealtimeSignalParser.parse(
                payload: [negativeEnvelope],
                expectedEntityRoom: entityRoom,
                expectedUserID: "user-1",
                expectedRoomID: "room-1"
            )
        )
    }
}

final class SpySliderInteractionStateTests: XCTestCase {
    func testOnlyOptedInNonTrackingRemoteTransactionAnimatesSlider() {
        XCTAssertTrue(
            SpySliderProgrammaticUpdatePolicy.shouldAnimate(
                isTracking: false,
                allowsAnimation: true,
                transactionHasAnimation: true,
                reduceMotion: false
            )
        )
        XCTAssertFalse(
            SpySliderProgrammaticUpdatePolicy.shouldAnimate(
                isTracking: true,
                allowsAnimation: true,
                transactionHasAnimation: true,
                reduceMotion: false
            )
        )
        XCTAssertFalse(
            SpySliderProgrammaticUpdatePolicy.shouldAnimate(
                isTracking: false,
                allowsAnimation: false,
                transactionHasAnimation: true,
                reduceMotion: false
            )
        )
        XCTAssertFalse(
            SpySliderProgrammaticUpdatePolicy.shouldAnimate(
                isTracking: false,
                allowsAnimation: true,
                transactionHasAnimation: false,
                reduceMotion: false
            )
        )
        XCTAssertFalse(
            SpySliderProgrammaticUpdatePolicy.shouldAnimate(
                isTracking: false,
                allowsAnimation: true,
                transactionHasAnimation: true,
                reduceMotion: true
            )
        )
    }

    func testTouchCancelRestoresInitialValueWithoutCommit() throws {
        var interaction = SpySliderInteractionState()

        XCTAssertTrue(interaction.begin(at: 15))
        interaction.track(9)

        XCTAssertEqual(try XCTUnwrap(interaction.cancel()), 15)
        XCTAssertFalse(interaction.isEditing)
        XCTAssertNil(interaction.lastTrackedValue)
        XCTAssertNil(interaction.commit(9))
    }

    func testTouchUpCommitsExactFinalNativeValue() throws {
        var interaction = SpySliderInteractionState()

        XCTAssertTrue(interaction.begin(at: 15))
        interaction.track(9)

        XCTAssertEqual(try XCTUnwrap(interaction.commit(8)), 8)
        XCTAssertFalse(interaction.isEditing)
        XCTAssertNil(interaction.cancel())
    }

    func testAccessibilityValueChangeCommitsWithoutTouchLifecycle() {
        var interaction = SpySliderInteractionState()

        XCTAssertTrue(interaction.commitsValueChangeImmediately(isTracking: false))
        XCTAssertFalse(interaction.commitsValueChangeImmediately(isTracking: true))

        XCTAssertTrue(interaction.begin(at: 15))
        XCTAssertFalse(interaction.commitsValueChangeImmediately(isTracking: false))
    }
}

final class RadarCameraAssistanceGateTests: XCTestCase {
    func testCameraAssistanceRequiresExplicitAuthorizedRadarIntent() {
        XCTAssertTrue(
            RadarCameraAssistanceGate.canEnable(
                hasExplicitRadarIntent: true,
                wantsScanning: true,
                authorizationStatus: .authorized,
                supportsCameraAssistance: true,
                supportsWorldTracking: true
            )
        )
        XCTAssertFalse(
            RadarCameraAssistanceGate.canEnable(
                hasExplicitRadarIntent: false,
                wantsScanning: true,
                authorizationStatus: .authorized,
                supportsCameraAssistance: true,
                supportsWorldTracking: true
            )
        )
        XCTAssertFalse(
            RadarCameraAssistanceGate.canEnable(
                hasExplicitRadarIntent: true,
                wantsScanning: true,
                authorizationStatus: .notDetermined,
                supportsCameraAssistance: true,
                supportsWorldTracking: true
            )
        )
    }
}

final class RadarInvitationInteractionPolicyTests: XCTestCase {
    func testSecondTapCancelsOnlyPendingInvitation() {
        XCTAssertEqual(
            RadarInvitationInteractionPolicy.action(
                invitePolicy: .ask,
                availability: .available,
                invitationState: nil
            ),
            .send
        )
        XCTAssertEqual(
            RadarInvitationInteractionPolicy.action(
                invitePolicy: .ask,
                availability: .available,
                invitationState: .waiting
            ),
            .cancel
        )
        XCTAssertEqual(
            RadarInvitationInteractionPolicy.action(
                invitePolicy: .ask,
                availability: .available,
                invitationState: .accepted
            ),
            .none
        )
    }

    func testUnavailablePlayersCannotSendOrCancelInvitation() {
        XCTAssertEqual(
            RadarInvitationInteractionPolicy.action(
                invitePolicy: .blocked,
                availability: .available,
                invitationState: nil
            ),
            .none
        )
        XCTAssertEqual(
            RadarInvitationInteractionPolicy.action(
                invitePolicy: .ask,
                availability: .inGame,
                invitationState: .waiting
            ),
            .none
        )
    }

    func testLiveAvailabilityReconcilesCardState() {
        XCTAssertEqual(
            RadarInvitationInteractionPolicy.state(
                after: .inGame,
                currentState: .waiting
            ),
            .inGame
        )
        XCTAssertNil(
            RadarInvitationInteractionPolicy.state(
                after: .available,
                currentState: .inGame
            )
        )
        XCTAssertEqual(
            RadarInvitationInteractionPolicy.state(
                after: .available,
                currentState: .declined
            ),
            .declined
        )
    }

    func testCancellationMustMatchInvitationAndSender() {
        let invitation = RadarIncomingInvitation(
            roomCode: "ABC123",
            hostCallSign: "Host",
            hostAvatar: "🕵️",
            wireInvitationID: "invite-1",
            sourcePeerID: "peer-1"
        )

        XCTAssertTrue(
            RadarInvitationCancellationPolicy.matches(
                invitation: invitation,
                invitationID: "invite-1",
                sourcePeerID: "peer-1"
            )
        )
        XCTAssertFalse(
            RadarInvitationCancellationPolicy.matches(
                invitation: invitation,
                invitationID: "invite-2",
                sourcePeerID: "peer-1"
            )
        )
        XCTAssertFalse(
            RadarInvitationCancellationPolicy.matches(
                invitation: invitation,
                invitationID: "invite-1",
                sourcePeerID: "peer-2"
            )
        )
    }
}

final class NavigationSwipeTests: XCTestCase {
    func testResolverMapsHorizontalSwipeDirection() {
        XCTAssertEqual(
            TabSwipeResolver.resolve(translation: CGSize(width: -80, height: 10)),
            .next
        )
        XCTAssertEqual(
            TabSwipeResolver.resolve(translation: CGSize(width: 80, height: -10)),
            .previous
        )
    }

    func testResolverRejectsShortVerticalAndDiagonalDrags() {
        XCTAssertNil(
            TabSwipeResolver.resolve(
                translation: CGSize(width: TabSwipeResolver.minimumTranslation - 1, height: 0)
            )
        )
        XCTAssertNil(TabSwipeResolver.resolve(translation: CGSize(width: 25, height: 90)))
        XCTAssertNil(TabSwipeResolver.resolve(translation: CGSize(width: 80, height: 70)))
    }

    func testResolverAcceptsHorizontalDominantDragAtThreshold() {
        XCTAssertEqual(
            TabSwipeResolver.resolve(
                translation: CGSize(width: TabSwipeResolver.minimumTranslation, height: 10)
            ),
            .previous
        )
    }

    func testResolverSuppressesTabSwipeWhileTextInputIsActive() {
        XCTAssertNil(
            TabSwipeResolver.resolve(
                translation: CGSize(width: -120, height: 4),
                isTextInputActive: true
            )
        )
        XCTAssertEqual(
            TabSwipeResolver.resolve(
                translation: CGSize(width: -120, height: 4),
                isTextInputActive: false
            ),
            .next
        )
    }

    func testResolverSuppressesTabSwipeFromInteractiveHorizontalControl() {
        XCTAssertNil(
            TabSwipeResolver.resolve(
                translation: CGSize(width: -120, height: 4),
                isInteractiveHorizontalControlActive: true
            )
        )
        XCTAssertEqual(
            TabSwipeResolver.resolve(
                translation: CGSize(width: -120, height: 4),
                isInteractiveHorizontalControlActive: false
            ),
            .next
        )
    }

    func testPrimaryTabsAdvanceWithoutWrapping() {
        XCTAssertEqual(AppTab.home.primaryNeighbor(for: .next), .packs)
        XCTAssertEqual(AppTab.packs.primaryNeighbor(for: .next), .profile)
        XCTAssertNil(AppTab.profile.primaryNeighbor(for: .next))

        XCTAssertEqual(AppTab.profile.primaryNeighbor(for: .previous), .packs)
        XCTAssertEqual(AppTab.packs.primaryNeighbor(for: .previous), .home)
        XCTAssertNil(AppTab.home.primaryNeighbor(for: .previous))
    }

    func testNonPrimaryTabsDoNotParticipateInPrimarySwipes() {
        XCTAssertNil(AppTab.game.primaryNeighbor(for: .next))
        XCTAssertNil(AppTab.local.primaryNeighbor(for: .previous))
        XCTAssertNil(AppTab.history.primaryNeighbor(for: .previous))
    }

    func testCommunityTabsAdvanceWithoutExitOrWrapping() {
        XCTAssertEqual(CommunityTab.network.swipeNeighbor(for: .next), .me)
        XCTAssertEqual(CommunityTab.me.swipeNeighbor(for: .previous), .network)
        XCTAssertNil(CommunityTab.network.swipeNeighbor(for: .previous))
        XCTAssertNil(CommunityTab.me.swipeNeighbor(for: .next))
        XCTAssertNil(CommunityTab.exit.swipeNeighbor(for: .next))
    }

    func testCommunityMeTransitionWaitsForProfileAndIdleActions() {
        XCTAssertFalse(
            CommunityMeTransitionResolver.canCommit(
                selfUserID: nil,
                activeAction: nil
            )
        )
        XCTAssertFalse(
            CommunityMeTransitionResolver.canCommit(
                selfUserID: "user-a",
                activeAction: "friend-user-b"
            )
        )
        XCTAssertTrue(
            CommunityMeTransitionResolver.canCommit(
                selfUserID: "user-a",
                activeAction: nil
            )
        )
    }

    func testCommunityProfileResponseIsRejectedAfterNetworkInvalidatesRequest() {
        var state = CommunityProfileRequestState()
        let requestID = UUID()

        XCTAssertEqual(state.begin(requestID), requestID)
        XCTAssertTrue(state.accepts(requestID))

        state.invalidate()

        XCTAssertNil(state.activeRequestID)
        XCTAssertFalse(state.accepts(requestID))
    }

    func testActiveRoomPreviewWinsOverExplicitHomeRootPresentation() {
        XCTAssertFalse(
            HomeRootPresentationPolicy.showsLandingActions(
                hasActiveRoom: true,
                explicitlyRequested: true
            )
        )
        XCTAssertFalse(
            HomeRootPresentationPolicy.showsLandingActions(
                hasActiveRoom: true,
                explicitlyRequested: false
            )
        )
        XCTAssertTrue(
            HomeRootPresentationPolicy.showsLandingActions(
                hasActiveRoom: false,
                explicitlyRequested: true
            )
        )
        XCTAssertEqual(
            HomeRootPresentationPolicy.primaryAction(hasActiveRoom: true),
            .returnToActiveRoom
        )
        XCTAssertEqual(
            HomeRootPresentationPolicy.primaryAction(hasActiveRoom: false),
            .chooseMode
        )
    }
}
