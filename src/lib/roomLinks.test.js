import test from "node:test";
import assert from "node:assert/strict";
import { roomCodeFromPayload } from "./roomLinks.js";

const options = { currentOrigin: "https://spyclash.com" };

test("accepts every supported cross-platform room payload", () => {
  const payloads = [
    "R7VN",
    "https://spyclash.com/#/Home?join=R7VN",
    "https://spyclash.com/Home?code=r7vn",
    "spyclash://join?code=R7VN",
    "spyclash://room/R7VN",
    "https://spyclash.com/join/R7VN",
    "https://preview.base44.app/#/Home?join=R7VN",
  ];

  for (const payload of payloads) {
    assert.equal(roomCodeFromPayload(payload, options), "R7VN", payload);
  }
});

test("rejects auth callbacks, foreign hosts, and malformed room codes", () => {
  const payloads = [
    "spyclash://auth?code=R7VN",
    "https://evil.example/?join=R7VN",
    "spyclash://join?code=R!VN",
    "ABC",
    "",
  ];

  for (const payload of payloads) {
    assert.equal(roomCodeFromPayload(payload, options), null, payload);
  }
});
