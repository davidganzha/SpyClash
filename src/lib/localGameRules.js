export function localGameTimeoutOutcome() {
  return {
    phase: "finished",
    winner: "spy",
    timeLeft: 0,
    timeExpired: true,
    showSpyGuess: false,
  };
}
