import { isAllowedSpyCount } from "./multiSpyRules.js";

export function pickLocalSpyIndices(playerCount, spyCount, random = Math.random) {
  const players = Math.floor(Number(playerCount) || 0);
  const spies = Number(spyCount);
  if (!isAllowedSpyCount(players, spies)) {
    throw new RangeError("Local games require a valid spy count and at least three players");
  }

  const indices = Array.from({ length: players }, (_, index) => index);
  for (let index = indices.length - 1; index > 0; index -= 1) {
    const sample = Number(random());
    const bounded = Number.isFinite(sample) ? Math.max(0, Math.min(sample, 0.999999999)) : 0;
    const swapIndex = Math.floor(bounded * (index + 1));
    [indices[index], indices[swapIndex]] = [indices[swapIndex], indices[index]];
  }
  return indices.slice(0, spies).sort((left, right) => left - right);
}

export function localTeamWinner({ activePlayerIndices = [], spyIndices = [] } = {}) {
  const active = new Set(activePlayerIndices.map(Number).filter(Number.isInteger));
  const spies = new Set(spyIndices.map(Number).filter(Number.isInteger));
  const activeSpies = [...spies].filter((index) => active.has(index)).length;
  if (activeSpies === 0) return "detectives";
  const activeDetectives = Math.max(active.size - activeSpies, 0);
  if (activeSpies >= activeDetectives) return "spy";
  return null;
}

export function localGameTimeoutOutcome() {
  return {
    phase: "finished",
    winner: "spy",
    timeLeft: 0,
    timeExpired: true,
    showSpyGuess: false,
  };
}

export function shouldResumeLocalTimerAfterCardReview({
  wasRunning = false,
  phase = "",
  timeLeft = 0,
} = {}) {
  return wasRunning === true && phase === "playing" && Number(timeLeft) > 0;
}
