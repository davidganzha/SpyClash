import { compensateUntrackedAppleRefreshToken } from "./apple-token-compensation.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

Deno.test("untracked Apple token releases only on documented HTTP 200", async () => {
  for (const status of [200, 204, 400, 401, 403, 404, 408, 429, 500, 503]) {
    let requestChecked = false;
    const disposition = await compensateUntrackedAppleRefreshToken({
      refreshToken: "untracked-refresh-token",
      clientID: "com.spyclash.ios",
      createClientSecret: async (clientID) => {
        assert(clientID === "com.spyclash.ios", "wrong client was signed");
        return "signed-client-secret";
      },
      fetcher: async (url, init) => {
        assert(
          url === "https://appleid.apple.com/auth/revoke",
          "wrong revocation endpoint",
        );
        assert(init?.method === "POST", "revocation was not POST");
        assert(init?.redirect === "error", "redirects were not rejected");
        assert(
          init?.signal instanceof AbortSignal,
          "timeout signal is missing",
        );
        const body = init?.body as URLSearchParams;
        assert(body.get("client_id") === "com.spyclash.ios", "wrong client id");
        assert(
          body.get("client_secret") === "signed-client-secret",
          "wrong client secret",
        );
        assert(
          body.get("token") === "untracked-refresh-token",
          "wrong refresh token",
        );
        assert(
          body.get("token_type_hint") === "refresh_token",
          "wrong token hint",
        );
        requestChecked = true;
        return new Response(null, { status });
      },
    });
    assert(requestChecked, `HTTP ${status} request was not made`);
    assert(
      disposition === (status === 200 ? "release" : "retain"),
      `HTTP ${status} produced an unsafe disposition`,
    );
  }
});

Deno.test("untracked Apple token retains boundary on transport or signer failure", async () => {
  const transport = await compensateUntrackedAppleRefreshToken({
    refreshToken: "untracked-refresh-token",
    clientID: "com.spyclash.ios",
    createClientSecret: async () => "signed-client-secret",
    fetcher: async () => {
      throw new TypeError("network response lost");
    },
  });
  assert(transport === "retain", "transport failure released the boundary");

  let fetchCalled = false;
  const signer = await compensateUntrackedAppleRefreshToken({
    refreshToken: "untracked-refresh-token",
    clientID: "com.spyclash.ios",
    createClientSecret: async () => {
      throw new Error("signer unavailable");
    },
    fetcher: async () => {
      fetchCalled = true;
      return new Response(null, { status: 200 });
    },
  });
  assert(signer === "retain", "signer failure released the boundary");
  assert(!fetchCalled, "request ran without a client secret");
});
