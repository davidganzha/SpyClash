import Foundation

extension AppState {
    /// Count completed matches, including unranked and local games. Profile
    /// `games_played` only counts competitive games and is not a survey clock.
    func recordCompletedOnlineGameForAcquisitionSurvey(_ room: GameRoom?) {
        guard let room, let user,
              room.normalizedStatus == "finished",
              let matchID = room.matchID?.nilIfBlank,
              ["spy", "detectives"].contains(room.winner?.lowercased() ?? ""),
              room.playersList.contains(where: {
                  $0.email.trimmingCharacters(in: .whitespacesAndNewlines)
                      .lowercased() == user.email.trimmingCharacters(in: .whitespacesAndNewlines)
                      .lowercased()
              }) else { return }
        recordCompletedGameForAcquisitionSurvey(id: "online:\(matchID)", userID: user.id)
    }

    func recordCompletedGameForAcquisitionSurvey(id: String, userID: String) {
        guard user?.id == userID, !requiresOnboarding else { return }
#if DEBUG
        guard !shouldUsePreviewData else { return }
#endif
        if acquisitionSurveyStore.recordCompletedGame(id: id, for: userID) {
            acquisitionSurveyRevision &+= 1
        }
    }

    var isAcquisitionSurveyHomeAvailable: Bool {
        guard user != nil,
              !isRestoring, !isBusy, !requiresOnboarding,
              selectedTab == .home, shellRoute == .main,
              activeRoom == nil, presentedSheet == nil,
              pendingJoinCode == nil, !isShellChromeSuppressed,
              radarNearby.incomingInvitation == nil,
              authHomeRevealPhase == .idle,
              standardAuthCinematicStage == nil,
              !isFinishingOnboarding else { return false }
        return true
    }

    var canPresentAcquisitionSurvey: Bool {
        guard isAcquisitionSurveyHomeAvailable, let user else { return false }
        return acquisitionSurveyStore.isEligible(for: user.id, remoteSource: user.acquisitionSource)
    }

    func claimAcquisitionSurveyPresentation(for userID: String) -> Bool {
        guard user?.id == userID, canPresentAcquisitionSurvey else { return false }
        // Claim before presentation, so dismissal, relaunch and account changes
        // cannot repeatedly interrupt the player with the same optional question.
        acquisitionSurveyStore.markPresented(for: userID)
        acquisitionSurveyRevision &+= 1
        return true
    }

    func answerAcquisitionSurvey(_ source: OnboardingAcquisitionSource, userID: String) {
        guard user?.id == userID else { return }
        acquisitionSurveyStore.saveAnswer(source: source, for: userID)
        acquisitionSurveyRevision &+= 1
        queuePendingAcquisitionSurveySync()
    }

    func cancelAcquisitionSurveySync() {
        acquisitionSurveySyncTask?.cancel()
        acquisitionSurveySyncTask = nil
        acquisitionSurveySyncID = nil
        acquisitionSurveyRevision &+= 1
    }

    func queuePendingAcquisitionSurveySync() {
        guard acquisitionSurveySyncTask == nil,
              let user, !requiresOnboarding, client.hasSessionToken,
              let source = acquisitionSurveyStore.pendingAnswer(for: user.id) else { return }
#if DEBUG
        guard !shouldUsePreviewData else { return }
#endif
        let userID = user.id
        let runID = UUID()
        acquisitionSurveySyncID = runID
        acquisitionSurveySyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.acquisitionSurveySyncID == runID {
                    self.acquisitionSurveySyncTask = nil
                    self.acquisitionSurveySyncID = nil
                }
            }
            do {
                try await self.client.saveAcquisitionSource(source)
                guard !Task.isCancelled,
                      self.acquisitionSurveySyncID == runID,
                      self.user?.id == userID else { return }
                self.acquisitionSurveyStore.markSynced(source: source, for: userID)
                // Apply only the field we wrote. A full stale User snapshot
                // could overwrite concurrent membership, language or Radar work.
                self.user?.acquisitionSource = source.rawValue
            } catch {
                // Keep the answer durable. Retry on the next foreground/home
                // visit without blocking gameplay or showing the survey again.
            }
        }
    }
}
