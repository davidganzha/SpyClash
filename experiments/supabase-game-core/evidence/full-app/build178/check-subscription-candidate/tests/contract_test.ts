import { fixture, resetFixture } from "./sdk-stub.ts";
import { prepareLegacyBilling } from "../../../../../supabase/functions/app-services/legacy-billing.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
function equal(actual: unknown, expected: unknown, message = "Unexpected value") {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${message}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
  }
}

const appID = "69a0e57fa939f578082f8091";
const origin = "https://spyclash.com";
const actorID = "00000000-0000-4000-8000-000000000178";
const credential = "fixture-user-credential";
const config = {
  SUPABASE_URL: "http://127.0.0.1:54321",
  APP_BILLING_PROVIDER: "base44",
  APP_LEGACY_BILLING_ENABLED: "true",
  APP_LEGACY_PURCHASES_ENABLED: "true",
};

function fakeDB() {
  const tx = (parts: TemplateStringsArray) => {
    const sql = parts.join("?");
    if (sql.includes("from app_private.profiles")) return [{ state: "active" }];
    if (sql.includes("from app_private.legacy_links")) return [{
      state: "active", legacy_user_id: "fixture-base44-user", source_origin: origin,
    }];
    if (sql.includes("pg_advisory_xact_lock_shared")) return [];
    throw new Error("Unexpected database write/query: " + sql);
  };
  return { begin: (callback: (tx: any) => unknown) => callback(tx) };
}

async function bridgeResult(value: unknown) {
  let checks = 0;
  const evidence = await prepareLegacyBilling({
    actor: { id: actorID, email: "fixture@example.test", contactEmail: "fixture@example.test", full_name: "Fixture", metadata: {} },
    body: { action: "check", base44_access_token: credential }, config,
  }, {
    db: fakeDB(),
    fetch: ((input: string | URL | Request, init?: RequestInit) => {
      const path = new URL(String(input)).pathname;
      const headers = new Headers(init?.headers);
      equal(headers.get("Authorization"), "Bearer " + credential);
      if (path.endsWith("/entities/User/me")) {
        return Promise.resolve(Response.json({ id: "fixture-base44-user" }));
      }
      equal(path, `/api/apps/${appID}/functions/checkSubscription`);
      equal(init?.method, "POST");
      checks++;
      return Promise.resolve(Response.json(value));
    }) as typeof fetch,
  });
  equal(checks, 1);
  return evidence;
}

Deno.test("fresh pulled handler and unchanged billing bridge enforce the membership contract", async (t) => {
  const originalServe = Deno.serve;
  const originalGet = Deno.env.get;
  const originalFetch = globalThis.fetch;
  const originalError = console.error;
  const settings: Record<string, string> = {
    SPYCLASH_LIMITLESS_ENABLED: "true",
    SPYCLASH_LIMITLESS_APPLE_PURCHASE_ENABLED: "true",
  };
  let handler: ((request: Request) => Promise<Response>) | undefined;
  let externalRequests = 0;
  try {
    Deno.serve = ((callback: typeof handler) => { handler = callback; return {}; }) as typeof Deno.serve;
    Deno.env.get = (name) => settings[name];
    globalThis.fetch = (() => { externalRequests++; throw new Error("Network is forbidden in contract tests"); }) as typeof fetch;
    console.error = () => {};
    await import("../base44/functions/checkSubscription/entry.ts");
    assert(handler, "Expected the actual candidate Deno handler");
    const invoke = async (headers: Record<string, string> = {}, method = "POST", body = {}) => {
      const response = await handler!(new Request(origin + "/functions/checkSubscription", {
        method, headers: { "Content-Type": "application/json", ...headers },
        ...(method === "POST" ? { body: JSON.stringify(body) } : {}),
      }));
      return { status: response.status, value: await response.json() };
    };
    const trusted = {
      "Base44-App-Id": appID,
      "Base44-Service-Authorization": "Bearer fixture-service-context",
      Authorization: "Bearer " + credential,
    };
    const fullShape = (value: any) => {
      for (const field of ["active", "tier", "protocol", "providers", "benefits", "expires_at", "checked_at", "apple_purchase_enabled"]) {
        assert(field in value, "Missing bridge field: " + field);
      }
      equal(typeof value.benefits.premium_avatars, "boolean");
      assert(Number.isFinite(Date.parse(value.checked_at)), "Missing verification time");
    };

    await t.step("unauthenticated calls cannot return active-only success", async () => {
      resetFixture();
      const response = await invoke({}, "POST", { access_token: credential });
      equal(response.status, 401);
      equal(response.value.status, "unauthenticated");
      equal(response.value.tier, null);
      equal(fixture.calls, []);
    });
    await t.step("wrong app context fails before SDK or data reads", async () => {
      resetFixture();
      equal((await invoke({ ...trusted, "Base44-App-Id": "wrong-app" })).status, 401);
      equal(fixture.calls, []);
    });
    await t.step("trusted runtime context still requires a verified user session", async () => {
      resetFixture();
      equal((await invoke({ ...trusted, Authorization: "" }, "POST", { access_token: credential })).status, 401);
      equal(fixture.calls, ["createClient", "auth.me"]);
    });
    await t.step("malformed user fails closed", async () => {
      resetFixture({ user: { id: "fixture-base44-user" } });
      equal((await invoke(trusted)).status, 401);
    });
    await t.step("GET is rejected", async () => {
      resetFixture();
      equal((await invoke(trusted, "GET")).status, 405);
      equal(fixture.calls, []);
    });
    await t.step("verified FREE response satisfies the real bridge and permits configured purchase", async () => {
      resetFixture({ quota: [{ generations_used: 2 }, { generations_used: 1 }] });
      const response = await invoke(trusted);
      equal(response.status, 200);
      fullShape(response.value);
      equal(response.value.active, false);
      equal(response.value.tier, "free");
      equal(response.value.protocol, "limitless");
      equal(response.value.benefits.premium_avatars, false);
      equal(response.value.apple_purchase_enabled, true);
      equal(response.value.ai_remaining, 7);
      equal(response.value.provider_sync.stripe, "not_required");
      equal((await bridgeResult(response.value)).result, response.value);
    });
    await t.step("rollout purchase gate remains authoritative", async () => {
      resetFixture();
      settings.SPYCLASH_LIMITLESS_APPLE_PURCHASE_ENABLED = "false";
      try { equal((await invoke(trusted)).value.apple_purchase_enabled, false); }
      finally { settings.SPYCLASH_LIMITLESS_APPLE_PURCHASE_ENABLED = "true"; }
    });
    const activeApple = { source_key: "apple:fixture-original-transaction", user_id: "fixture-base44-user", provider: "apple", product_id: "com.spyclash.ios.limitless.weekly", status: "active", expires_at: "2999-01-01T00:00:00Z" };
    await t.step("verified active Apple access satisfies bridge without duplicate purchase", async () => {
      resetFixture({ entitlements: [activeApple] });
      const response = await invoke(trusted);
      equal(response.status, 200);
      fullShape(response.value);
      equal(response.value.active, true);
      equal(response.value.tier, "limitless");
      equal(response.value.providers, ["apple"]);
      equal(response.value.apple_purchase_enabled, false);
      equal((await bridgeResult(response.value)).result, response.value);
    });
    await t.step("expired Apple access does not grant LIMITLESS", async () => {
      resetFixture({ entitlements: [{ ...activeApple, expires_at: "2000-01-01T00:00:00Z" }] });
      const response = await invoke(trusted);
      equal(response.status, 200);
      equal(response.value.tier, "free");
      equal(response.value.active, false);
    });
    for (const outage of ["entitlements", "grants"]) {
      await t.step(`${outage} uncertainty blocks purchase and does not classify FREE`, async () => {
        resetFixture({ errors: new Set([outage]) });
        const response = await invoke(trusted);
        equal(response.status, 503);
        equal(response.value.status, "unknown");
        equal(response.value.tier, null);
        equal(response.value.benefits, null);
        assert(response.value.apple_purchase_enabled !== true, "Unverified access must not permit purchase");
      });
    }
    await t.step("verified active source survives unrelated grant outage without enabling purchase", async () => {
      resetFixture({ entitlements: [activeApple], errors: new Set(["grants"]) });
      const response = await invoke(trusted);
      equal(response.status, 200);
      equal(response.value.active, true);
      equal(response.value.apple_purchase_enabled, false);
    });
    await t.step("verified grant retains LIMITLESS", async () => {
      resetFixture({ grants: [{ active: true }] });
      const response = await invoke(trusted);
      equal(response.status, 200);
      equal(response.value.providers, ["admin"]);
      equal(response.value.apple_purchase_enabled, false);
      await bridgeResult(response.value);
    });
    await t.step("quota outage cannot invent unlimited membership", async () => {
      resetFixture({ errors: new Set(["quota"]) });
      const response = await invoke(trusted);
      equal(response.status, 200);
      equal(response.value.tier, "free");
      equal(response.value.ai_remaining, null);
      equal(response.value.provider_sync.quota, "degraded");
    });
    for (const active of [false, true]) {
      await t.step(`real bridge rejects old active-only shape (${active})`, async () => {
        try { await bridgeResult({ active }); throw new Error("Old shape unexpectedly accepted"); }
        catch (error) {
          equal((error as any).code, "legacy_billing_response_invalid");
          equal((error as any).status, 502);
        }
      });
    }
    equal(externalRequests, 0, "Contract tests must never contact live services");
  } finally {
    Deno.serve = originalServe;
    Deno.env.get = originalGet;
    globalThis.fetch = originalFetch;
    console.error = originalError;
  }
});
