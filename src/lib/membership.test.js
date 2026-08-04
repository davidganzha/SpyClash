import test from "node:test";
import assert from "node:assert/strict";
import {
  PUBLIC_ACCESS_BENEFITS,
  PUBLIC_ACCESS_TIER,
  getTodayAiUsage,
  normalizeMembership,
} from "./membership.js";
import {
  ACCOUNT_AVATARS,
  accountAvatarForDisplay,
  canSelectAccountAvatar,
  resolveAccountAvatarSelection,
} from "./avatars.js";

test("public access exposes the complete shared avatar catalog", () => {
  assert.deepEqual(ACCOUNT_AVATARS, ["🕵️", "🥷", "🧠", "🎭", "🃏", "👁️", "🔥", "⚡️", "🎯", "🛡️"]);
  for (const avatar of ACCOUNT_AVATARS) {
    assert.equal(canSelectAccountAvatar(avatar), true);
  }
});

test("public access grants unrestricted benefits regardless of old entitlement payloads", () => {
  for (const payload of [
    {},
    { tier: "free", active: false },
    { tier: "unknown", active: false },
    { benefits: { ai_generations_daily_limit: 10, full_history: false } },
  ]) {
    const membership = normalizeMembership(payload);
    assert.equal(membership.tier, PUBLIC_ACCESS_TIER);
    assert.equal(membership.active, true);
    assert.deepEqual(membership.benefits, PUBLIC_ACCESS_BENEFITS);
    assert.equal(membership.ai_remaining, null);
  }
});

test("public access discards retired wire tiers without exposing them", () => {
  for (const payload of [
    { active: true, tier: "retired-a", protocol: "retired-a" },
    { active: true, tier: "retired-b", protocol: "retired-a" },
  ]) {
    const membership = normalizeMembership(payload);
    assert.equal(membership.tier, PUBLIC_ACCESS_TIER);
    assert.equal(membership.protocol, null);
    assert.deepEqual(membership.providers, []);
    assert.deepEqual(membership.benefits, PUBLIC_ACCESS_BENEFITS);
  }

  const legacyBuildResponse = normalizeMembership({
    active: true,
    tier: "retired-b",
    protocol: "retired-a",
    providers: ["retired-a"],
    expires_at: "9999-12-31T23:59:59Z",
  });
  assert.equal(legacyBuildResponse.expires_at, null);
  assert.deepEqual(legacyBuildResponse.providers, []);
});

test("public access keeps usage metadata without retaining provider markers", () => {
  const membership = normalizeMembership({
    providers: ["apple", 42, "stripe"],
    expires_at: "2026-08-01T00:00:00.000Z",
    ai_generations_today: 27,
  });

  assert.deepEqual(membership.providers, []);
  assert.equal(membership.expires_at, null);
  assert.equal(membership.ai_generations_today, 27);
  assert.equal(membership.benefits.ai_generations_daily_limit, null);
});

test("counts AI usage only for the current UTC day", () => {
  const now = new Date("2026-07-13T12:00:00.000Z");
  assert.equal(getTodayAiUsage({
    last_ai_generation_date: "2026-07-13T08:00:00.000Z",
    ai_generations_today: 7,
  }, now), 7);
  assert.equal(getTodayAiUsage({
    last_ai_generation_date: "2026-07-12T23:59:59.000Z",
    ai_generations_today: 10,
  }, now), 0);
});

test("avatar selection has no paid category", () => {
  assert.equal(resolveAccountAvatarSelection("🃏", "🕵️"), "🃏");
  assert.equal(resolveAccountAvatarSelection("👁️", "🕵️"), "👁️");
  assert.equal(resolveAccountAvatarSelection("unknown", "🥷"), "🥷");
  assert.equal(accountAvatarForDisplay("legacy-avatar"), "legacy-avatar");
});
