import { rolloutEnabled } from "./limitless-rollout.ts";
import { applyCasadaAccess, summarizeMembership } from "./membership.ts";
import {
  applyAdminGenerationGrant,
  applyCasadaGenerationAccess,
  resolveGenerationMembership,
} from "../generateWordPack/membership.ts";
import { casadaPurchaseRetirement } from "../app-store-entitlement/apple-entitlement.ts";

function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}

Deno.test("LIMITLESS rollout is explicit and off for missing or malformed settings", () => {
  for (const value of [undefined, "", "false", "1", "TRUE", " true "]) {
    assert(!rolloutEnabled(value));
  }
  assert(rolloutEnabled("true"));
});

Deno.test("paid mode does not inherit universal CASADA privileges", () => {
  const free = applyCasadaAccess(summarizeMembership([]), false);
  assert(!free.active && free.tier === "free" && free.protocol === "limitless");
  assert(
    free.benefits.ai_generations_daily_limit === 10 &&
      free.benefits.history_limit === 5,
  );
  const generation = applyCasadaGenerationAccess(
    resolveGenerationMembership([]),
    false,
  );
  assert(!generation.active && generation.protocol === free.protocol);
});

Deno.test("Apple preparation requires both an access rollout and purchase activation", () => {
  assert(casadaPurchaseRetirement(true, true)?.status === 409);
  assert(casadaPurchaseRetirement(false, false)?.status === 503);
  assert(casadaPurchaseRetirement(false, true) === null);
});

Deno.test("independent function bundles share the exact same rollout policy", async () => {
  const canonical = await Deno.readTextFile(
    new URL("./limitless-rollout.ts", import.meta.url),
  );
  for (
    const dir of [
      "generateWordPack",
      "app-store-entitlement",
      "communityAction",
    ]
  ) {
    assert(
      await Deno.readTextFile(
        new URL("../" + dir + "/limitless-rollout.ts", import.meta.url),
      ) === canonical,
    );
  }
  const membership = await Deno.readTextFile(
    new URL("./membership.ts", import.meta.url),
  );
  assert(
    await Deno.readTextFile(
      new URL("../communityAction/membership.ts", import.meta.url),
    ) === membership,
  );
});

Deno.test("unknown providers cannot create paid access", () => {
  const records = [{
    provider: "unknown",
    status: "active",
    expires_at: "2099-01-01T00:00:00Z",
  }];
  assert(!summarizeMembership(records).active);
  assert(!resolveGenerationMembership(records).active);
});

Deno.test("membership and generator agree on paid expiry and revocation", () => {
  const now = new Date("2026-09-05T00:00:00Z");
  for (
    const status of [
      "active",
      "grace_period",
      "refunded",
      "revoked",
      "expired",
      "billing_retry",
    ]
  ) {
    const records = [{
      provider: "apple",
      status,
      expires_at: "2026-09-06T00:00:00Z",
    }];
    const membership = summarizeMembership(records, now);
    const generation = resolveGenerationMembership(records, now);
    assert(membership.active === generation.active);
    assert(membership.expires_at === generation.expires_at);
  }
  const granted = applyAdminGenerationGrant(resolveGenerationMembership([]), [{
    active: true,
    expires_at: "2026-09-06T00:00:00Z",
  }], now);
  assert(granted.expires_at === "2026-09-06T00:00:00.000Z");
});
