import { assert, assertEquals } from "jsr:@std/assert@1";
import { exportJWK, exportPKCS8, generateKeyPair } from "npm:jose@5.10.0";

const brokerURL = "https://spyclash.com/functions/appleAuthBroker";
const redirectURI =
  "https://app.base44.com/api/apps/69a0e57fa939f578082f8091/auth/sso/callback";
const sentinel = "INTERNAL-CONFIG-DETAIL-NEVER-EXPOSE";

function requests() {
  const get = (
    action: string,
    params: Record<string, string>,
    headers: Record<string, string> = {},
  ) => {
    const url = new URL(brokerURL);
    url.search = new URLSearchParams({ action, ...params }).toString();
    return new Request(url, { headers: { Accept: "text/html", ...headers } });
  };
  return [
    get("google-callback", { state: sentinel, code: sentinel }),
    get("confirm-google-transaction", { state: sentinel }),
    get("apple-callback", { state: sentinel, code: sentinel }),
    get("userinfo", {}, { Authorization: `Bearer ${sentinel}` }),
    new Request(`${brokerURL}?action=token`, {
      method: "POST",
      body: new URLSearchParams({
        client_id: "test-client",
        client_secret: sentinel,
        grant_type: "authorization_code",
        redirect_uri: redirectURI,
        code: sentinel,
      }),
    }),
    get("authorize", {
      client_id: "test-client",
      response_type: "code",
      redirect_uri: redirectURI,
      state: "test-oidc-state",
    }, { Cookie: `__Host-SpyClashNativeOIDC=${sentinel}` }),
  ];
}

for (const failure of ["missing-key-id", "invalid-public-jwk"] as const) {
  Deno.test(`actual broker preserves safe 500 for ${failure} across credential verification routes`, async () => {
    const keys = await generateKeyPair("ES256", { extractable: true });
    const config: Record<string, string> = {
      SPYCLASH_OIDC_KEY_ID: "ephemeral-test-key",
      SPYCLASH_OIDC_PRIVATE_KEY_PEM_B64: btoa(
        await exportPKCS8(keys.privateKey),
      ),
      SPYCLASH_OIDC_PUBLIC_JWK: JSON.stringify(await exportJWK(keys.publicKey)),
      sso_client_id: "test-client",
      sso_client_secret: sentinel,
    };
    if (failure === "missing-key-id") delete config.SPYCLASH_OIDC_KEY_ID;
    else config.SPYCLASH_OIDC_PUBLIC_JWK = sentinel;

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
      console.error = (...values: unknown[]) => logs.push(values);
      globalThis.fetch = (() => {
        providerCalls += 1;
        return Promise.reject(
          new Error("Unexpected network call in local test"),
        );
      }) as typeof fetch;
      // Fresh module state models a cold runtime with a failed broker-key load.
      await import(`./main.ts?server-error-test=${failure}`);
      assert(handler);

      for (const request of requests()) {
        const action = new URL(request.url).searchParams.get("action")!;
        const response = await handler(request);
        assertEquals(response.status, 500, action);
        assertEquals(await response.json(), {
          error: "server_configuration_error",
          error_description:
            "Authentication service is temporarily unavailable",
        }, action);
        assertEquals(response.headers.get("Cache-Control"), "no-store");
        assertEquals(response.headers.get("Referrer-Policy"), "no-referrer");
        assertEquals(response.headers.get("Location"), null);
      }

      assertEquals(providerCalls, 0);
      assertEquals(logs.length, 6);
      for (const [message, details] of logs) {
        assertEquals(message, "appleAuthBroker request failed");
        assertEquals(
          (details as { error_code: string }).error_code,
          "server_configuration_error",
        );
      }
      const logText = JSON.stringify(logs);
      assert(!logText.includes(sentinel));
      assert(!logText.includes("SPYCLASH_OIDC_"));
      assert(!logText.includes(config.SPYCLASH_OIDC_PRIVATE_KEY_PEM_B64));
      assert(!logText.includes("state_jwt_invalid"));
      assert(!logText.includes("state_jwt_expired"));
    } finally {
      Deno.serve = originalServe;
      Deno.env.get = originalEnvGet;
      globalThis.fetch = originalFetch;
      console.error = originalLog;
    }
  });
}
