import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  exportJWK,
  exportPKCS8,
  generateKeyPair,
  SignJWT,
} from "npm:jose@5.10.0";

Deno.test("actual Apple bootstrap trusts only the signed version; invalid opt-in stops before Apple exchange", async () => {
  const keys = await generateKeyPair("ES256", { extractable: true });
  const config: Record<string, string> = {
    SPYCLASH_OIDC_KEY_ID: "apple-handoff-test",
    SPYCLASH_OIDC_PRIVATE_KEY_PEM_B64: btoa(await exportPKCS8(keys.privateKey)),
    SPYCLASH_OIDC_PUBLIC_JWK: JSON.stringify(await exportJWK(keys.publicKey)),
  };
  const originalServe = Deno.serve,
    originalGet = Deno.env.get,
    originalFetch = globalThis.fetch,
    originalError = console.error;
  let handler: ((request: Request) => Promise<Response>) | undefined;
  let externalCalls = 0;
  try {
    Deno.serve = ((callback: typeof handler) => {
      handler = callback;
      return {};
    }) as typeof Deno.serve;
    Deno.env.get = (name) => config[name];
    console.error = () => {};
    globalThis.fetch = (() => {
      externalCalls++;
      throw new Error("Unexpected external call");
    }) as typeof fetch;
    await import("./main.ts?native-handoff-test");
    assert(handler);
    const sign = (version: unknown) =>
      new SignJWT({
        token_use: "native_ticket",
        ...(version === undefined ? {} : { handoff_version: version }),
      })
        .setProtectedHeader({ alg: "ES256", kid: "apple-handoff-test" })
        .setIssuer("https://spyclash.com/functions/appleAuthBroker")
        .setAudience("spyclash:native-bootstrap")
        .setIssuedAt().setExpirationTime("2m").sign(keys.privateKey);
    for (const version of [undefined, "apple-native-v2"]) {
      const url = new URL(
        "https://spyclash.com/functions/appleAuthBroker?action=native-bootstrap",
      );
      url.searchParams.set("ticket", await sign(version));
      // Unsigned query parameters never upgrade or override the ticket.
      url.searchParams.set(
        "handoff_version",
        version ? "legacy" : "apple-native-v2",
      );
      url.searchParams.set("from_url", "https://attacker.example/");
      const response = await handler(new Request(url));
      assertEquals(response.status, 302);
      const redirect = new URL(response.headers.get("Location")!);
      assertEquals(redirect.origin, "https://spyclash.com");
      assertEquals(
        redirect.pathname,
        "/api/apps/69a0e57fa939f578082f8091/auth/sso/login",
      );
      assertEquals(
        redirect.searchParams.get("from_url"),
        version
          ? "https://spyclash.com/MobileAppleAuthCallback.html?auth_provider=apple"
          : "https://spyclash.com/api/apps/69a0e57fa939f578082f8091/functions/mobileAuthCallback",
      );
      assert(
        response.headers.get("Set-Cookie")?.includes(
          "HttpOnly; Secure; SameSite=Lax",
        ),
      );
      assertEquals(response.headers.get("Cache-Control"), "no-store");
    }
    const invalid = new URL(
      "https://spyclash.com/functions/appleAuthBroker?action=native-bootstrap",
    );
    invalid.searchParams.set("ticket", await sign("https://attacker.example/"));
    assertEquals((await handler(new Request(invalid))).status, 400);
    for (
      const handoff_version of [
        "",
        "APPLE-NATIVE-V2",
        "https://attacker.example/",
        ["apple-native-v2"],
        2,
      ]
    ) {
      const response = await handler(
        new Request(
          "https://spyclash.com/functions/appleAuthBroker?action=native-exchange",
          {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ handoff_version }),
          },
        ),
      );
      assertEquals(response.status, 400);
      assertEquals(
        (await response.json()).error,
        "invalid_native_handoff_version",
      );
    }
    assertEquals(externalCalls, 0);
  } finally {
    Deno.serve = originalServe;
    Deno.env.get = originalGet;
    globalThis.fetch = originalFetch;
    console.error = originalError;
  }
});
