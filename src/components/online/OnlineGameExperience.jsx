import { useEffect, useMemo, useRef, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import {
  countdownRemainingSeconds,
  deriveOnlineGamePresentation,
  onlineRoundCommand,
  parseAssociationRoundState,
} from "@/lib/onlineGamePresentation";
import "./OnlineGameExperience.css";

const localize = (lang, en, ru) => (lang === "ru" ? ru : en);

function Wordmark() {
  return (
    <span className="oge-wordmark" aria-label="SpyClash">
      <span>SPY</span><span>CLASH</span>
    </span>
  );
}

function CinematicBackdrop() {
  return <div className="oge-backdrop" aria-hidden="true" />;
}

function SyncBanner({ syncState, t }) {
  if (syncState === "connected") return null;
  return (
    <div className="oge-sync-banner" role="status" aria-live="polite">
      ↻ {t("room_sync_reconnecting")}
    </div>
  );
}

function MissionRoleCard({
  presentation,
  category,
  revealed,
  hero = false,
  onToggle,
  t,
  lang,
  accessibilityId,
  buttonRef = undefined,
}) {
  const role = presentation.viewerRole;
  const isDetective = role === "detective";
  const isSpy = role === "spy";
  const roleTitle = isSpy
    ? t("game_you_are_spy")
    : isDetective
      ? t("game_you_are_detective")
      : localize(lang, "SPECTATOR", "НАБЛЮДАТЕЛЬ");
  const roleHint = isSpy
    ? t("game_spy_hint")
    : role === "spectator"
      ? localize(lang, "Observe the mission. Your role is read-only.", "Наблюдай за миссией. Ты не участвуешь в раунде.")
      : null;
  const revealedAccessibilityLabel = [
    roleTitle,
    presentation.secretWord,
    category ? `${t("game_category_label")} ${String(category).toUpperCase()}` : null,
    roleHint,
  ].filter(Boolean).join(". ");

  return (
    <button
      type="button"
      ref={buttonRef}
      className={[
        "oge-role-card",
        hero ? "is-hero" : "is-compact",
        revealed ? "is-revealed" : "",
        isSpy ? "is-spy" : "is-detective",
      ].filter(Boolean).join(" ")}
      onClick={onToggle}
      aria-pressed={revealed}
      aria-label={revealed ? revealedAccessibilityLabel : t("game_tap_to_reveal")}
      data-testid={accessibilityId}
    >
      <span className="oge-role-card-inner">
        <span className="oge-role-face oge-role-face-back" aria-hidden={revealed}>
          <img className="oge-role-logo" src="/icon-192.png" alt="" />
          <span className="oge-role-back-title">SPYCLASH</span>
          <span className="oge-role-classification">// {t("game_dont_show")}</span>
        </span>
        <span className="oge-role-face oge-role-face-front" aria-hidden={!revealed}>
          <span className="oge-role-kicker">// {localize(lang, "YOUR ROLE", "ТВОЯ РОЛЬ")}</span>
          <span className="oge-role-icon" aria-hidden="true">{isSpy ? "S" : isDetective ? "D" : "O"}</span>
          <span className="oge-role-title">{roleTitle}</span>
          {presentation.secretWord && (
            <span className="oge-role-word">{presentation.secretWord}</span>
          )}
          {roleHint && <span className="oge-role-hint">{roleHint}</span>}
          <span className="oge-role-category">
            {category ? `${t("game_category_label")} ${String(category).toUpperCase()}` : "// CLASSIFIED"}
          </span>
        </span>
      </span>
    </button>
  );
}

function HeaderControl({ label, children, onClick, disabled = false, testId }) {
  return (
    <button
      type="button"
      className="oge-icon-button"
      aria-label={label}
      title={label}
      onClick={onClick}
      disabled={disabled}
      data-testid={testId}
    >
      {children}
    </button>
  );
}

function OperativeRail({ room, userEmail }) {
  const eliminated = new Set(room.eliminated_emails || []);
  return (
    <div className="oge-operative-rail" data-testid="onlineExperience.players">
      {(room.players || []).map((player) => {
        const isCurrent = player.email === userEmail;
        const isTurn = player.email === room.current_asker_email
          || player.email === room.current_answerer_email;
        const isEliminated = eliminated.has(player.email);
        return (
          <div
            key={player.email}
            className={[
              "oge-operative",
              isCurrent ? "is-current" : "",
              isTurn ? "is-turn" : "",
              isEliminated ? "is-eliminated" : "",
            ].filter(Boolean).join(" ")}
          >
            <span className="oge-operative-avatar">{player.avatar || player.name?.slice(0, 1) || "•"}</span>
            <span className="oge-operative-name">{String(player.name || "AGENT").toUpperCase()}</span>
            <span className="oge-operative-line" />
          </div>
        );
      })}
    </div>
  );
}

function PairPerson({ label, player, asker = false, right = false }) {
  return (
    <div className={`oge-pair-person${asker ? " is-asker" : ""}${right ? " is-right" : ""}`}>
      <span className="oge-stage-avatar">{player?.avatar || "•"}</span>
      <span className="oge-pair-copy">
        <span className="oge-stage-kicker">{label}</span>
        <span className="oge-pair-name">{String(player?.name || "PENDING").toUpperCase()}</span>
      </span>
    </div>
  );
}

function QuestionStage({ room, t }) {
  const asker = (room.players || []).find((player) => player.email === room.current_asker_email);
  const answerer = (room.players || []).find((player) => player.email === room.current_answerer_email);
  return (
    <div className="oge-pair-strip" data-testid="onlineExperience.questionPair">
      <PairPerson label={t("qr_asks")} player={asker} asker />
      <span className="oge-pair-arrow" aria-hidden="true" />
      <PairPerson label={t("qr_answers")} player={answerer} right />
    </div>
  );
}

function CountdownStage({ seconds, t, lang }) {
  return (
    <div className="oge-countdown-stage" data-testid="onlineExperience.questionCountdown">
      <span className="oge-stage-kicker">{t("qr_next_question")}</span>
      <span className="oge-countdown-value">{Math.max(0, Math.ceil(seconds))}</span>
      <span className="oge-stage-message">
        {localize(lang, "SYNCHRONIZING ALL OPERATIVES", "СИНХРОНИЗАЦИЯ ИГРОКОВ")}
      </span>
    </div>
  );
}

function ExpiredStage({ presentation, guessTimeLeft, t, lang }) {
  const safeGuessTime = Math.max(0, Math.ceil(Number(guessTimeLeft) || 0));
  const spyCanAct = presentation.viewerRole === "spy" && !presentation.isSpectator;
  return (
    <div className="oge-expired-stage" data-testid="onlineExperience.timeExpired" role="status" aria-live="polite">
      <span className="oge-expired-icon" aria-hidden="true">⏱</span>
      <span className="oge-stage-kicker">// {t("game_time_up")}</span>
      <span className="oge-expired-value">{safeGuessTime}s</span>
      <span className="oge-stage-message">
        {spyCanAct
          ? localize(lang, "FINAL CHANCE TO GUESS", "ПОСЛЕДНИЙ ШАНС УГАДАТЬ")
          : t("game_waiting_spy")}
      </span>
    </div>
  );
}

function AssociationStage({ room, state, lang }) {
  const player = (room.players || []).find((candidate) => candidate.email === room.current_asker_email);
  const activeCount = (room.players || []).filter(
    (candidate) => !(room.spectators || []).includes(candidate.email),
  ).length;
  return (
    <div className="oge-association-stage" data-testid="onlineExperience.associationState">
      <span className="oge-stage-kicker">
        {state.spinning
          ? localize(lang, "SELECTING NEXT SPEAKER", "ВЫБИРАЕМ СЛЕДУЮЩЕГО")
          : localize(lang, "CURRENT SPEAKER", "СЕЙЧАС ГОВОРИТ")}
      </span>
      <span className={`oge-association-avatar${state.spinning ? " is-spinning" : ""}`}>
        {state.spinning ? "⌁" : (player?.avatar || "•")}
      </span>
      <span className="oge-association-name">
        {state.spinning
          ? localize(lang, "SIGNAL SCANNING", "СКАНИРУЕМ СИГНАЛ")
          : String(player?.name || "PENDING").toUpperCase()}
      </span>
      <span className="oge-stage-message">{state.spoken.length} / {activeCount}</span>
    </div>
  );
}

function ResultsStage({ room, t }) {
  const eliminated = new Set(room.eliminated_emails || []);
  const scores = (room.players || [])
    .filter((player) => !eliminated.has(player.email))
    .map((player) => {
      const feedback = (room.player_feedback || []).find((item) => item.email === player.email);
      return { ...player, score: Number(feedback?.likes || 0) - Number(feedback?.dislikes || 0) };
    })
    .sort((left, right) => right.score - left.score || String(left.name).localeCompare(String(right.name)));

  return (
    <div className="oge-results-stage" data-testid="onlineExperience.roundResults">
      <div className="oge-stage-title">{t("rr_title")}</div>
      <div className="oge-result-list">
        {scores.map((player, index) => (
          <div className="oge-result-row" key={player.email}>
            <span className="oge-result-rank">{String(index + 1).padStart(2, "0")}</span>
            <span>{player.avatar || "•"}</span>
            <span className="oge-result-name">{String(player.name || "AGENT").toUpperCase()}</span>
            <span className={`oge-result-score${player.score < 0 ? " is-negative" : ""}`}>
              {player.score > 0 ? "+" : ""}{player.score}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}

function VotingStage({ presentation, userEmail, onCastVote, busyAction, lang }) {
  const viewerEmail = String(userEmail || "").trim().toLocaleLowerCase();
  const eliminated = new Set(
    (presentation.eliminatedEmails || []).map((email) => String(email || "").trim().toLocaleLowerCase()),
  );
  const candidates = presentation.activePlayers.filter((player) => {
    const email = String(player.email || "").trim().toLocaleLowerCase();
    return email && email !== viewerEmail && !eliminated.has(email);
  });
  const canCastVote = presentation.isPlayer && !presentation.isSpectator;
  return (
    <div className="oge-voting-stage" data-testid="onlineExperience.votingCandidates">
      <div className="oge-stage-title">{localize(lang, "CHOOSE A SUSPECT", "ВЫБЕРИ ПОДОЗРЕВАЕМОГО")}</div>
      <div className="oge-vote-grid">
        {candidates.map((candidate) => {
          const selected = presentation.myVote?.voted_for_email === candidate.email;
          return (
            <button
              type="button"
              key={candidate.email}
              className={`oge-vote-candidate${selected ? " is-selected" : ""}`}
              onClick={() => onCastVote(candidate.email)}
              disabled={!canCastVote || Boolean(presentation.myVote) || busyAction === "cast_detective_vote"}
              data-testid={`onlineExperience.vote.${candidate.email.replaceAll(/[^a-zA-Z0-9]/g, "-")}`}
            >
              <span className="oge-vote-avatar">{candidate.avatar || "•"}</span>
              <span className="oge-vote-name">{String(candidate.name || "AGENT").toUpperCase()}</span>
            </button>
          );
        })}
      </div>
      <div className="oge-vote-hint">
        {presentation.myVote
          ? localize(lang, "VOTE RECORDED", "ГОЛОС ПРИНЯТ")
          : localize(lang, "THE VOTE IS FINAL", "ГОЛОС НЕЛЬЗЯ ИЗМЕНИТЬ")}
      </div>
    </div>
  );
}

function RoundStage({ room, presentation, countdown, timeExpired, guessTimeLeft, onCastVote, busyAction, t, lang }) {
  if (timeExpired) {
    return (
      <ExpiredStage
        presentation={presentation}
        guessTimeLeft={guessTimeLeft}
        t={t}
        lang={lang}
      />
    );
  }
  if (presentation.isVotingActive) {
    return (
      <VotingStage
        presentation={presentation}
        userEmail={presentation.viewerEmail}
        onCastVote={onCastVote}
        busyAction={busyAction}
        lang={lang}
      />
    );
  }
  if (presentation.roundPhase === "results") return <ResultsStage room={room} t={t} />;
  if (presentation.gameMode === "associations") {
    return <AssociationStage room={room} state={presentation.associationState} lang={lang} />;
  }
  if (presentation.roundPhase === "countdown") {
    return <CountdownStage seconds={countdown} t={t} lang={lang} />;
  }
  return <QuestionStage room={room} t={t} />;
}

function ActionButton({ primary = false, children, onClick, disabled = false, testId = undefined }) {
  return (
    <button
      type="button"
      className={`oge-action${primary ? " is-primary" : ""}`}
      onClick={onClick}
      disabled={disabled}
      data-testid={testId}
    >
      {children}
    </button>
  );
}

function commandCopy(action, t, lang) {
  switch (action) {
    case "mark_answer_heard": return t("qr_answer_received_btn");
    case "continue_round": return t("rr_continue");
    case "start_association": return localize(lang, "START ASSOCIATIONS", "НАЧАТЬ АССОЦИАЦИИ");
    case "advance_association": return localize(lang, "ASSOCIATION GIVEN", "АССОЦИАЦИЯ НАЗВАНА");
    default: return null;
  }
}

export function OnlineRoleRevealScene({
  room,
  user,
  revealed,
  confirming,
  syncState,
  onReveal,
  onConfirm,
  onLeave,
  t,
  lang,
}) {
  const presentation = useMemo(
    () => deriveOnlineGamePresentation(room, user.email),
    [room, user.email],
  );
  const currentPlayer = (room.players || []).find((player) => player.email === user.email);
  const confirmed = presentation.hasReadRoleCard || presentation.isSpectator;

  return (
    <div className="oge-shell">
      <CinematicBackdrop />
      <SyncBanner syncState={syncState} t={t} />
      <div className="oge-role-gate-frame">
        <header className="oge-brand-header">
          <Wordmark />
          <span className="oge-room-code">// {String(room.code || "").toUpperCase()}</span>
        </header>

        <main className="oge-role-gate-content">
          <div>
            <div className="oge-role-kicker">{localize(lang, "// YOUR CARD", "// ТВОЯ КАРТА")}</div>
            <div className="oge-player-identity">
              <span>{currentPlayer?.avatar || "•"}</span>
              <span>{String(currentPlayer?.name || "AGENT").toUpperCase()}</span>
            </div>
          </div>

          <div className="oge-role-gate-card-slot">
            <MissionRoleCard
              presentation={presentation}
              category={room.category}
              revealed={revealed}
              hero
              onToggle={() => { if (!confirmed && !revealed) onReveal(); }}
              t={t}
              lang={lang}
              accessibilityId="onlineExperience.roleCard"
            />
          </div>

          <div className="oge-role-gate-bottom">
            {confirmed ? (
              <div className="oge-read-status" data-testid="onlineExperience.waiting">
                <div className="oge-read-title">
                  {localize(
                    lang,
                    `WAITING ${presentation.cardsReadCount || (room.cards_read || []).length} / ${(room.players || []).length}`,
                    `ОЖИДАЕМ ${(room.cards_read || []).length} / ${(room.players || []).length}`,
                  )}
                </div>
                <div className="oge-read-roster" data-testid="onlineExperience.cardsReadRoster">
                  {(room.players || []).map((player) => {
                    const checked = (room.cards_read || []).includes(player.email)
                      || (room.spectators || []).includes(player.email);
                    return (
                      <span key={player.email} className={`oge-read-avatar${checked ? " is-read" : ""}`}>
                        {player.avatar || "•"}
                      </span>
                    );
                  })}
                </div>
              </div>
            ) : revealed ? (
              <ActionButton
                primary
                onClick={onConfirm}
                disabled={confirming}
                testId="onlineExperience.confirmRole"
              >
                {confirming ? "…" : `✓ ${t("game_ready_btn").replace(/^✓\s*/u, "")}`}
              </ActionButton>
            ) : (
              <div className="oge-stage-message">{t("game_tap_to_reveal")}</div>
            )}
          </div>

          <button type="button" className="oge-leave-link" onClick={onLeave} data-testid="onlineExperience.leave">
            {localize(lang, "LEAVE GAME", "ВЫЙТИ ИЗ ИГРЫ")}
          </button>
        </main>
      </div>
    </div>
  );
}

export function OnlineActiveGameScene({
  room,
  user,
  revealed,
  timeLeft,
  timeExpired,
  guessTimeLeft,
  syncState,
  busyAction,
  onToggleRole,
  onTogglePause,
  onLeave,
  onRoundAction,
  onAdvanceQuestion,
  onStopAssociationSpin,
  onRequestVote,
  onCastVote,
  onSpyGuess,
  t,
  lang,
}) {
  const [nowMs, setNowMs] = useState(() => Date.now());
  const [confirmingLeave, setConfirmingLeave] = useState(false);
  const handledCountdown = useRef(null);
  const handledAssociationSpin = useRef(null);
  const frameRef = useRef(null);
  const overlayCardRef = useRef(null);
  const onToggleRoleRef = useRef(onToggleRole);
  onToggleRoleRef.current = onToggleRole;
  const presentation = useMemo(() => ({
    ...deriveOnlineGamePresentation(room, user.email),
    viewerEmail: user.email,
    eliminatedEmails: room.eliminated_emails || [],
  }), [room, user.email]);
  const command = timeExpired ? null : onlineRoundCommand(room, user.email);
  const associationState = useMemo(
    () => parseAssociationRoundState(room.current_answer),
    [room.current_answer],
  );
  const countdown = countdownRemainingSeconds(room, nowMs);
  const durationSeconds = Math.max(Number(room.game_duration_seconds) || 1, 1);
  const safeTimeLeft = Math.max(Number(timeLeft) || 0, 0);
  const timerProgress = Math.max(0, Math.min(1, safeTimeLeft / durationSeconds));
  const critical = safeTimeLeft <= 60;

  useEffect(() => {
    if (presentation.roundPhase !== "countdown" || presentation.isPaused) return undefined;
    const timer = window.setInterval(() => setNowMs(Date.now()), 250);
    return () => window.clearInterval(timer);
  }, [presentation.isPaused, presentation.roundPhase, room.countdown_started_at]);

  useEffect(() => {
    if (
      presentation.roundPhase !== "countdown"
      || countdown > 0
      || timeExpired
      || presentation.isPaused
      || busyAction
    ) return;
    if (room.current_asker_email !== user.email) return;
    const key = `${room.id}:${room.countdown_started_at || "countdown"}`;
    if (handledCountdown.current === key) return;
    handledCountdown.current = key;
    Promise.resolve(onAdvanceQuestion()).then((updated) => {
      if (!updated && handledCountdown.current === key) {
        handledCountdown.current = null;
      }
    });
  }, [
    countdown,
    busyAction,
    onAdvanceQuestion,
    presentation.isPaused,
    presentation.roundPhase,
    room.countdown_started_at,
    room.current_asker_email,
    room.id,
    timeExpired,
    user.email,
  ]);

  useEffect(() => {
    if (!associationState.spinning || !presentation.canStopAssociationSpin || timeExpired) return undefined;
    const key = `${room.id}:${room.round_number || 1}:${room.current_asker_email || "pending"}:${room.current_answer}`;
    if (handledAssociationSpin.current === key) return undefined;
    const timer = window.setTimeout(() => {
      if (handledAssociationSpin.current === key) return;
      handledAssociationSpin.current = key;
      Promise.resolve(onStopAssociationSpin()).then((updated) => {
        if (!updated && handledAssociationSpin.current === key) {
          handledAssociationSpin.current = null;
        }
      });
    }, 2200);
    return () => window.clearTimeout(timer);
  }, [
    associationState.spinning,
    onStopAssociationSpin,
    presentation.canStopAssociationSpin,
    room.current_answer,
    room.current_asker_email,
    room.id,
    room.round_number,
    timeExpired,
  ]);

  const isPaused = presentation.isPaused;
  const roundCommandTitle = commandCopy(command, t, lang);
  const hasEnabledWords = (room.word_pool || []).some((entry) => entry?.enabled !== false);
  const canSpyGuess = presentation.viewerRole === "spy"
    && !presentation.isSpectator
    && hasEnabledWords
    && !isPaused;
  const canRequestVote = presentation.isPlayer
    && !presentation.isSpectator
    && !presentation.hasRequestedVote
    && !presentation.isVotingActive
    && !isPaused
    && !timeExpired;
  const suppressFallback = presentation.roundPhase === "results"
    || presentation.roundPhase === "countdown"
    || presentation.isVotingActive
    || (presentation.gameMode === "associations" && associationState.spinning);
  const spyGuessAction = {
    action: "submit_spy_guess",
    title: localize(lang, "GUESS THE WORD", "УГАДАТЬ СЛОВО"),
    handler: onSpyGuess,
  };
  const primaryAction = timeExpired
    ? (canSpyGuess ? spyGuessAction : null)
    : command
      ? { action: command, title: roundCommandTitle, handler: () => onRoundAction(command) }
      : canSpyGuess && !suppressFallback
        ? spyGuessAction
        : canRequestVote && !suppressFallback
          ? { action: "request_vote", title: localize(lang, "START VOTE", "НАЧАТЬ ГОЛОСОВАНИЕ"), handler: onRequestVote }
          : null;
  const showRoleControl = true;
  const showSecondaryVote = canRequestVote
    && !suppressFallback
    && primaryAction?.action !== "request_vote";
  const showSecondaryGuess = !timeExpired && canSpyGuess
    && !suppressFallback
    && primaryAction?.action !== "submit_spy_guess";
  const showActionTray = Boolean(primaryAction || showRoleControl || showSecondaryVote || showSecondaryGuess);
  const showCentralRoleCard = presentation.roundPhase !== "results"
    && !presentation.isVotingActive;
  const showRoleOverlay = !showCentralRoleCard
    && revealed
    && !isPaused
    && !confirmingLeave;

  useEffect(() => {
    const frame = frameRef.current;
    if (frame) frame.inert = showRoleOverlay;
    if (!showRoleOverlay) return () => {
      if (frame) frame.inert = false;
    };

    const previousFocus = document.activeElement;
    const focusFrame = window.requestAnimationFrame(() => overlayCardRef.current?.focus());
    const handleKeyDown = (event) => {
      if (event.key === "Escape") {
        event.preventDefault();
        onToggleRoleRef.current?.();
      } else if (event.key === "Tab") {
        event.preventDefault();
        overlayCardRef.current?.focus();
      }
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => {
      window.cancelAnimationFrame(focusFrame);
      document.removeEventListener("keydown", handleKeyDown);
      if (frame) frame.inert = false;
      if (previousFocus instanceof HTMLElement) previousFocus.focus();
    };
  }, [showRoleOverlay]);

  const formattedTime = `${Math.floor(safeTimeLeft / 60)}:${String(safeTimeLeft % 60).padStart(2, "0")}`;

  return (
    <div className="oge-shell">
      <CinematicBackdrop />
      <SyncBanner syncState={syncState} t={t} />
      <div className="oge-frame" ref={frameRef}>
        <header className="oge-brand-header">
          <Wordmark />
          <div className="oge-header-controls">
            <HeaderControl
              label={localize(lang, presentation.isHost ? "Close game" : "Leave game", presentation.isHost ? "Закрыть игру" : "Выйти из игры")}
              onClick={() => setConfirmingLeave(true)}
              testId="onlineExperience.leave"
            >
              ↗
            </HeaderControl>
            {presentation.isHost && (
              <HeaderControl
                label={isPaused ? t("game_resume_btn") : t("game_pause_btn")}
                onClick={onTogglePause}
                disabled={busyAction === "pause_game" || busyAction === "resume_game"}
                testId="onlineExperience.pauseResume"
              >
                {isPaused ? "▶" : "Ⅱ"}
              </HeaderControl>
            )}
          </div>
        </header>

        <section className="oge-timer" data-testid="onlineExperience.timer">
          <span className="oge-timer-label">{t("game_round_label")} {Math.max(Number(room.round_number) || 1, 1)}</span>
          <span className={`oge-timer-value${critical ? " is-critical" : ""}`}>{formattedTime}</span>
          <span className="oge-timer-track">
            <span
              className={`oge-timer-progress${critical ? " is-critical" : ""}`}
              style={{ width: `${timerProgress * 100}%` }}
            />
          </span>
        </section>

        <OperativeRail room={room} userEmail={user.email} />

        <main className="oge-central">
          <div className="oge-central-scroll">
            {showCentralRoleCard && (
              <MissionRoleCard
                presentation={presentation}
                category={room.category}
                revealed={revealed}
                onToggle={onToggleRole}
                t={t}
                lang={lang}
                accessibilityId="onlineExperience.compactRoleCard"
              />
            )}
            <div className="oge-stage">
              <RoundStage
                room={room}
                presentation={{ ...presentation, associationState }}
                countdown={countdown}
                timeExpired={timeExpired}
                guessTimeLeft={guessTimeLeft}
                onCastVote={onCastVote}
                busyAction={busyAction}
                t={t}
                lang={lang}
              />
            </div>
          </div>
        </main>

        {showActionTray && <footer className="oge-action-tray" data-testid="onlineExperience.actionTray">
          {primaryAction && (
            <ActionButton
              primary
              onClick={primaryAction.handler}
              disabled={Boolean(busyAction)}
              testId={
                primaryAction.action === "request_vote"
                  ? "onlineExperience.action.vote"
                  : primaryAction.action === "submit_spy_guess"
                    ? "onlineExperience.action.spyGuess"
                    : "onlineExperience.action.next"
              }
            >
              {busyAction === primaryAction.action ? "…" : primaryAction.title}
            </ActionButton>
          )}
          <div className="oge-action-row">
            {showRoleControl && (
              <ActionButton onClick={onToggleRole} testId="onlineExperience.action.reveal">
                {revealed
                  ? localize(lang, "HIDE CARD", "СКРЫТЬ КАРТУ")
                  : localize(lang, "SHOW CARD", "ПОКАЗАТЬ КАРТУ")}
              </ActionButton>
            )}
            {showSecondaryVote && (
              <ActionButton onClick={onRequestVote} disabled={Boolean(busyAction)} testId="onlineExperience.action.vote">
                {localize(lang, "VOTE", "ГОЛОСОВАНИЕ")}
              </ActionButton>
            )}
            {showSecondaryGuess && (
              <ActionButton onClick={onSpyGuess} disabled={Boolean(busyAction)} testId="onlineExperience.action.spyGuess">
                {localize(lang, "GUESS", "УГАДАТЬ")}
              </ActionButton>
            )}
          </div>
        </footer>}
      </div>

      <AnimatePresence>
        {showRoleOverlay && (
          <motion.div
            className="oge-role-overlay"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            role="dialog"
            aria-modal="true"
            aria-label={localize(lang, "Your role card", "Твоя карта роли")}
          >
            <MissionRoleCard
              presentation={presentation}
              category={room.category}
              revealed
              hero
              onToggle={onToggleRole}
              t={t}
              lang={lang}
              accessibilityId="onlineExperience.overlayRoleCard"
              buttonRef={overlayCardRef}
            />
          </motion.div>
        )}
      </AnimatePresence>

      <AnimatePresence>
        {isPaused && (
          <motion.div
            className="oge-paused-overlay"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            role="status"
            aria-live="polite"
          >
            <div className="oge-paused-card">
              <div className="oge-overlay-title">{localize(lang, "PAUSED", "ПАУЗА")}</div>
              <div className="oge-overlay-copy">{localize(lang, "THE TIMER IS STOPPED", "ТАЙМЕР ОСТАНОВЛЕН")}</div>
              {presentation.isHost && (
                <ActionButton primary onClick={onTogglePause} disabled={Boolean(busyAction)} testId="onlineExperience.pauseResume">
                  ▶ {t("game_resume_btn")}
                </ActionButton>
              )}
              <ActionButton onClick={() => setConfirmingLeave(true)} testId="onlineExperience.leave">
                {localize(lang, presentation.isHost ? "CLOSE GAME" : "LEAVE GAME", presentation.isHost ? "ЗАКРЫТЬ ИГРУ" : "ВЫЙТИ ИЗ ИГРЫ")}
              </ActionButton>
            </div>
          </motion.div>
        )}
      </AnimatePresence>

      <AnimatePresence>
        {confirmingLeave && (
          <motion.div
            className="oge-confirm-overlay"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            role="dialog"
            aria-modal="true"
          >
            <div className="oge-confirm-card">
              <div className="oge-stage-title">
                {localize(lang, presentation.isHost ? "CLOSE GAME?" : "LEAVE GAME?", presentation.isHost ? "ЗАКРЫТЬ ИГРУ?" : "ВЫЙТИ ИЗ ИГРЫ?")}
              </div>
              <ActionButton primary onClick={onLeave}>
                {localize(lang, presentation.isHost ? "CLOSE GAME" : "LEAVE GAME", presentation.isHost ? "ЗАКРЫТЬ ИГРУ" : "ВЫЙТИ ИЗ ИГРЫ")}
              </ActionButton>
              <ActionButton onClick={() => setConfirmingLeave(false)}>
                {localize(lang, "CANCEL", "ОТМЕНА")}
              </ActionButton>
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
