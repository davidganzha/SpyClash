import { fixture, resetFixture } from "./sdk-stub.ts";
import {
  appleCredentialIdentityKey,
  persistPendingAppleSignInCredential,
} from "../../../../base44/functions/autoRegisterUser/apple-sign-in-credential.ts";
import { acquireBillingDeletionMarker } from "../../../../base44/functions/autoRegisterUser/billing-identity-lifecycle.ts";

function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
  }

}

const appID = "69a0e57fa939f578082f8091";
const trusted = { "Base44-App-Id": appID, "Base44-Service-Authorization": "Bearer fixture-service-token" };
const secrets: Record<string, string> = { SPYCLASH_PSEUDONYM_KEY: "p".repeat(32), PUSH_TOKEN_ENCRYPTION_KEY: "11".repeat(32) };
const body = { access_token: "fixture-user-token", apple_binding_ticket: "fixture-binding-ticket" };
type Handler = (req: Request) => Promise<Response>;

async function seedCredential(email = fixture.user.email) {
  return await persistPendingAppleSignInCredential({
    store: fixture.credentials, lifecycleStore: fixture.lifecycle,
    email, subject: "synthetic-apple-subject", clientID: "com.spyclash.ios",
    refreshToken: "synthetic-refresh-token-not-a-credential", randomTicket: () => body.apple_binding_ticket,
  });
}

Deno.test("actual versioned registration preserves Apple identity and deletion boundaries", async (t) => {
  const originalServe = Deno.serve;
  const originalGet = Deno.env.get;
  const originalFetch = globalThis.fetch;
  const originalError = console.error;
  let captured: Handler | undefined;
  let externalRequests = 0;
  try {
    Deno.serve = ((handler: Handler) => { captured = handler; return {}; }) as typeof Deno.serve;
    Deno.env.get = (name) => secrets[name];
    globalThis.fetch = (() => { externalRequests++; throw new Error("External network forbidden"); }) as typeof fetch;
    console.error = () => {};
    await import("../../../../base44/functions/autoRegisterUser/main.ts");
    const handler = captured;
    assert(handler, "Actual modern handler was not captured");
    const invoke = async (payload: unknown = body, headers: Record<string, string> = trusted, method = "POST", implementation = handler) => {
      const response = await implementation(new Request("https://spyclash.com/functions/autoRegisterUserV2", {
        method, headers: { "Content-Type": "application/json", ...headers },
        ...(method === "POST" ? { body: JSON.stringify(payload) } : {}),
      }));
      equal(response.headers.get("Cache-Control"), "no-store");
      return { status: response.status, value: await response.json() };
    };

    await t.step("GET returns405 without SDK access", async () => {
      resetFixture(); equal((await invoke({}, {}, "GET")).status, 405); equal(fixture.clients.length, 0);
    });
    await t.step("no service context rejects before identity verification", async () => {
      resetFixture(); equal((await invoke(body, {})).status, 401); equal(fixture.clients.length, 0);
    });
    await t.step("foreign app context rejects", async () => {
      resetFixture(); equal((await invoke(body, { ...trusted, "Base44-App-Id": "foreign-app" })).status, 401); equal(fixture.clients.length, 0);
    });
    await t.step("missing body token rejects even with bearer", async () => {
      resetFixture(); equal((await invoke({}, { ...trusted, Authorization: "Bearer fixture-user-token" })).status, 401); equal(fixture.clients.length, 0);
    });
    await t.step("invalid identity token cannot invite or bind", async () => {
      resetFixture({ rejectUserToken: true }); await seedCredential();
      equal((await invoke()).status, 401); equal(fixture.invites.length, 0); equal(fixture.credentials.records[0].state, "pending");
    });
    await t.step("existing verified user binds exact owner and ignores body identity and endpoint", async () => {
      resetFixture(); await seedCredential();
      const response = await invoke({ ...body, user_id: "attacker", email: "attacker@example.test", server_url: "https://invalid.test" }, { ...trusted, "Base44-Api-Url": "https://invalid.test" });
      equal(response.status, 200); equal(response.value.user.id, fixture.user.id);
      equal(fixture.credentials.records[0].state, "bound"); equal(fixture.credentials.records[0].user_id, fixture.user.id);
      equal(fixture.invites.length, 0);
    });
    await t.step("new verified identity validates ticket then provisions and binds", async () => {
      resetFixture({ registered: false }); await seedCredential();
      const response = await invoke({ ...body, email: "attacker@example.test" });
      equal(response.status, 200); equal(fixture.invites, [{ email: fixture.user.email, role: "user" }]);
      equal(response.value.user.id, fixture.user.id); equal(fixture.credentials.records[0].user_id, fixture.user.id); equal(fixture.credentials.records[0].state, "bound");
    });
    await t.step("invalid ticket prevents creation of a new account", async () => {
      resetFixture({ registered: false }); await seedCredential();
      equal((await invoke({ ...body, apple_binding_ticket: "invalid-ticket" })).status, 401);
      equal(fixture.invites.length, 0); equal(fixture.credentials.records[0].state, "pending");
    });
    await t.step("expired ticket prevents new account invitation", async () => {
      resetFixture({ registered: false }); await seedCredential(); fixture.credentials.records[0].binding_ticket_expires_at = new Date(Date.now() - 1000).toISOString();
      equal((await invoke()).status, 401); equal(fixture.invites.length, 0);
    });
    await t.step("other identity ticket prevents invitation", async () => {
      resetFixture({ registered: false }); await seedCredential("foreign@example.test");
      equal((await invoke()).status, 401); equal(fixture.invites.length, 0); equal(fixture.credentials.records[0].state, "pending");
    });
    await t.step("already bound foreign owner is not reassigned", async () => {
      resetFixture(); await seedCredential(); fixture.credentials.records[0].state = "bound"; fixture.credentials.records[0].user_id = "foreign-owner";
      equal((await invoke()).status, 409); equal(fixture.credentials.records[0].user_id, "foreign-owner");
    });
    await t.step("same-owner retry is idempotent", async () => {
      resetFixture(); await seedCredential(); equal((await invoke()).status, 200); equal((await invoke()).status, 200);
      equal(fixture.credentials.records.length, 1); equal(fixture.credentials.records[0].user_id, fixture.user.id); equal(fixture.invites.length, 0);
    });
    await t.step("active user deletion marker blocks binding", async () => {
      resetFixture(); await seedCredential(); await acquireBillingDeletionMarker(fixture.lifecycle, fixture.user.id);
      equal((await invoke()).status, 503); equal(fixture.credentials.records[0].state, "pending");
    });
    await t.step("active Apple identity deletion marker blocks new provisioning", async () => {
      resetFixture({ registered: false }); await seedCredential();
      const identity = await appleCredentialIdentityKey(fixture.user.email);
      await acquireBillingDeletionMarker(fixture.lifecycle, `spyclash-apple-refresh-token-v1:identity-lifecycle:${identity}`);
      equal((await invoke()).status, 503); equal(fixture.invites.length, 0);
    });
    await t.step("credential persistence uncertainty fails closed", async () => {
      resetFixture(); await seedCredential(); fixture.credentials.failUpdates = true;
      equal((await invoke()).status, 503); equal(fixture.credentials.records[0].state, "pending");
    });
    await t.step("non-Apple registration remains verified and does not bind", async () => {
      resetFixture(); await seedCredential(); const response = await invoke({ access_token: body.access_token });
      equal(response.status, 200); equal(response.value.user.id, fixture.user.id); equal(fixture.credentials.records[0].state, "pending");
    });
    await t.step("served legacy source demonstrates the missing binding boundary", async () => {
      await import("./legacy-runtime-fixture.js");
      const legacyHandler = captured;
      assert(legacyHandler && legacyHandler !== handler);
      resetFixture({ registered: false }); await seedCredential();
      const invalid = { ...body, apple_binding_ticket: "invalid-ticket" };
      const legacy = await invoke(invalid, trusted, "POST", legacyHandler);
      equal(legacy.status, 200); equal(fixture.invites.length, 1); equal(fixture.credentials.records[0].state, "pending");
      assert(!("user" in legacy.value), "Legacy behavior unexpectedly changed");
      resetFixture({ registered: false }); await seedCredential();
      equal((await invoke(invalid)).status, 401); equal(fixture.invites.length, 0);
    });
    equal(externalRequests, 0);
  } finally {
    Deno.serve = originalServe; Deno.env.get = originalGet; globalThis.fetch = originalFetch; console.error = originalError;
  }
});
