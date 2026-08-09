import assert from "node:assert/strict";
import test from "node:test";

import {
  localGameTimeoutOutcome,
  localTeamWinner,
  pickLocalSpyIndices,
} from "./localGameRules.js";

test("local game ends immediately with a spy win at zero", () => {
  assert.deepEqual(localGameTimeoutOutcome(), {
    phase: "finished",
    winner: "spy",
    timeLeft: 0,
    timeExpired: true,
    showSpyGuess: false,
  });
});

test("local multi-spy deal chooses the approved number of unique identities", () => {
  const samples = [0.95, 0.2, 0.75, 0.1, 0.5, 0.3, 0.8, 0.4];
  let cursor = 0;
  const spies = pickLocalSpyIndices(9, 3, () => samples[cursor++ % samples.length]);
  assert.equal(spies.length, 3);
  assert.equal(new Set(spies).size, 3);
  assert(spies.every((index) => index >= 0 && index < 9));
  assert.throws(() => pickLocalSpyIndices(5, 2), RangeError);
});

test("plural team outcome waits for all spies and awards parity to spies", () => {
  assert.equal(localTeamWinner({
    activePlayerIndices: [0, 1, 2, 3, 4, 5],
    spyIndices: [4, 5],
  }), null);
  assert.equal(localTeamWinner({
    activePlayerIndices: [0, 1, 4, 5],
    spyIndices: [4, 5],
  }), "spy");
  assert.equal(localTeamWinner({
    activePlayerIndices: [0, 1, 2],
    spyIndices: [4, 5],
  }), "detectives");
  assert.equal(localTeamWinner({
    activePlayerIndices: [0, 1, 2, 4],
    spyIndices: [4, 5],
  }), null);
});
