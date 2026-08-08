import assert from "node:assert/strict";
import test from "node:test";

import { localGameTimeoutOutcome } from "./localGameRules.js";

test("local game ends immediately with a spy win at zero", () => {
  assert.deepEqual(localGameTimeoutOutcome(), {
    phase: "finished",
    winner: "spy",
    timeLeft: 0,
    timeExpired: true,
    showSpyGuess: false,
  });
});
