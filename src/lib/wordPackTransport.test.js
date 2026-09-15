import assert from "node:assert/strict";
import test from "node:test";
import { dispatchWordPackGeneration } from "./wordPackTransport.js";

test("generation carries one request ID, cloned exclusions and fresh-result preference", async () => {
  const exclusions = ["Mars"];
  let payload;
  const result = await dispatchWordPackGeneration({
    theme: "Space",
    count: 10,
    excludedWords: exclusions,
    makeRequestID: () => "generation-1",
    invoke: async (body) => {
      payload = body;
      exclusions.push("Venus");
      return { data: { words: ["Saturn", "Jupiter"] } };
    },
  });
  assert.deepEqual(payload.exclude_words, ["Mars"]);
  assert.equal(payload.request_id, "generation-1");
  assert.equal(payload.prefer_fresh, true);
  assert.deepEqual(result.words, ["Saturn", "Jupiter"]);
});

test("independent regenerations receive separate request IDs", async () => {
  const calls = [];
  for (const count of [10, 20]) {
    await dispatchWordPackGeneration({
      theme: "Space",
      count,
      invoke: async (body) => { calls.push(body); return {}; },
    });
  }
  assert.notEqual(calls[0].request_id, calls[1].request_id);
});

test("unknown outcomes, request ID conflicts and untyped errors cannot start another generation", async () => {
  for (const failure of [
    { status: 409, code: "outcome_unknown", retryable: true },
    { status: 409, code: "word_pack_request_id_conflict", retryable: false },
    { status: 409, code: "cas_contention", retryable: true },
    { status: 409, code: "active_lease", retryable: false },
    { status: 409, code: "active_lease", retryable: true },
    { status: 503, retryable: true },
    new TypeError("Failed to fetch"),
  ]) {
    let attempts = 0;
    await assert.rejects(dispatchWordPackGeneration({
      theme: "Space",
      count: 10,
      invoke: async () => { attempts += 1; throw failure; },
    }));
    assert.equal(attempts, 1);
  }
});
