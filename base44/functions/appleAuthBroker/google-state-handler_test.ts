import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import {
  exportJWK,
  exportPKCS8,
  generateKeyPair,
  SignJWT,
} from "npm:jose@5.10.0";
import { createUpstreamTransaction } from "./transaction.ts";

Deno.test("actual broker distinguishes expired browser state while refusing invalid signatures and missing cookies before exchange", async () => {
  const keys = await generateKeyPair("ES256", { extractable: true });
  const config: Record<string, string> = {
    SPYCLASH_OIDC_KEY_ID: "ephemeral-test-key",
    SPYCLASH_OIDC_PRIVATE_KEY_PEM_B64: btoa(await exportPKCS8(keys.privateKey)),
    SPYCLASH_OIDC_PUBLIC_JWK: JSON.stringify(await exportJWK(keys.publicKey)),
    sso_client_id: "test-client",
  };
  const originalServe = Deno.serve;
  const originalEnvGet = Deno.env.get;
  const originalFetch = globalThis.fetch;
  const originalLog = console.error;
  const logs: unknown[][] = [];
  let providerCalls = 0;
  let handler: ((request: Request) => Promise<Response>) | undefined;
  try {
    Deno.serve = ((callback: typeof handler) => {
      handler = callback;
      return {};
    }) as typeof Deno.serve;
    Deno.env.get = (name: string) => config[name];
    console.error = (...values: unknown[]) => {
      logs.push(values);
    };
    globalThis.fetch = (() => {
      providerCalls += 1;
      return Promise.reject(new Error("Unexpected network call in local test"));
    }) as typeof fetch;
    await import("./main.ts");
    const transaction = await createUpstreamTransaction();
    const sign = (expiresAt: number) =>
      new SignJWT({
        token_use: "google_state",
        flow: "oidc",
        upstream_provider: "google",
        client_id: "test-client",
        redirect_uri:
          "https://app.base44.com/api/apps/69a0e57fa939f578082f8091/auth/sso/callback",
        oidc_state: "UNTRUSTED-OLD-STATE-NEVER-REFLECT",
        google_nonce: "test-nonce",
        browser_transaction_hash: transaction.secretHash,
        browser_transaction_channel: "primary",
      }).setProtectedHeader({ alg: "ES256", kid: "ephemeral-test-key" })
        .setIssuer("https://spyclash.com/functions/appleAuthBroker")
        .setAudience("spyclash:google-callback")
        .setExpirationTime(expiresAt)
        .sign(keys.privateKey);
    const expired = await sign(Math.floor(Date.now() / 1000) - 6 * 60 * 60);
    const fresh = await sign(Math.floor(Date.now() / 1000) + 300);
    const invoke = (
      state: string,
      accept: string,
      action = "google-callback",
    ) => {
      const url = new URL("https://spyclash.com/functions/appleAuthBroker");
      url.searchParams.set("action", action);
      url.searchParams.set("state", state);
      url.searchParams.set("code", "NEVER-EXCHANGE-THIS-TEST-CODE");
      return handler!(new Request(url, { headers: { Accept: accept } }));
    };
    for (const action of ["google-callback", "confirm-google-transaction"]) {
      const result = await invoke(expired, "text/html", action);
      assertEquals(result.status, 400);
      assertStringIncludes(
        await result.text(),
        "This sign-in session has expired",
      );
      assertEquals(result.headers.getSetCookie().length, 2);
    }
    const api = await invoke(expired, "application/json");
    assertEquals(api.status, 400);
    assertEquals(await api.json(), {
      error: "invalid_state",
      error_description: "invalid state",
    });
    const parts = expired.split(".");
    parts[2] = (parts[2][0] === "A" ? "B" : "A") + parts[2].slice(1);
    for (const action of ["google-callback", "confirm-google-transaction"]) {
      const badSignature = await invoke(parts.join("."), "text/html", action);
      assertEquals(badSignature.status, 400);
      assertStringIncludes(
        await badSignature.text(),
        "This sign-in could not be verified",
      );
    }
    const missingCookie = await invoke(fresh, "text/html");
    assertEquals(missingCookie.status, 400);
    const body = await missingCookie.text();
    assertStringIncludes(body, "This sign-in could not be verified");
    assert(!body.includes("UNTRUSTED-OLD-STATE"));
    assertEquals(providerCalls, 0);
    const safeLogs = JSON.stringify(logs);
    assertStringIncludes(safeLogs, "state_jwt_expired");
    assertStringIncludes(safeLogs, "state_jwt_invalid");
    assertStringIncludes(safeLogs, "transaction_cookie_missing");
    assert(!safeLogs.includes(expired));
    assert(!safeLogs.includes(fresh));
    assert(!safeLogs.includes(transaction.secret));
    assert(!safeLogs.includes("UNTRUSTED-OLD-STATE"));
    assert(!safeLogs.includes("NEVER-EXCHANGE-THIS-TEST-CODE"));
  } finally {
    Deno.serve = originalServe;
    Deno.env.get = originalEnvGet;
    globalThis.fetch = originalFetch;
    console.error = originalLog;
  }
});
