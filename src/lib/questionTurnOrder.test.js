import assert from "node:assert/strict";
import test from "node:test";

import {
  createQuestionTurnOrder,
  nextQuestionTurnStep,
  questionPairForStep,
} from "./questionTurnOrder.js";

test("question order uses a complete Fisher-Yates permutation", () => {
  const samples = [0.75, 0.1, 0.5];
  const order = createQuestionTurnOrder(4, () => samples.shift());

  assert.deepEqual(order, [2, 1, 0, 3]);
  assert.deepEqual([...order].sort((left, right) => left - right), [0, 1, 2, 3]);
});

test("question pairs keep one frozen cyclic order across round boundaries", () => {
  const order = [2, 0, 3, 1];
  const pairs = [];
  let step = 0;

  for (let index = 0; index < order.length * 2; index += 1) {
    pairs.push(questionPairForStep(order, step));
    step = nextQuestionTurnStep(order, step);
  }

  assert.deepEqual(pairs, [
    { askerIndex: 2, answererIndex: 0 },
    { askerIndex: 0, answererIndex: 3 },
    { askerIndex: 3, answererIndex: 1 },
    { askerIndex: 1, answererIndex: 2 },
    { askerIndex: 2, answererIndex: 0 },
    { askerIndex: 0, answererIndex: 3 },
    { askerIndex: 3, answererIndex: 1 },
    { askerIndex: 1, answererIndex: 2 },
  ]);
  assert.notEqual(pairs[3].answererIndex, pairs[4].answererIndex);
});

test("invalid or undersized orders fail closed", () => {
  assert.deepEqual(createQuestionTurnOrder(-1), []);
  assert.equal(questionPairForStep([], 0), null);
  assert.equal(questionPairForStep([0], 0), null);
  assert.equal(nextQuestionTurnStep([0], 4), 0);
});
