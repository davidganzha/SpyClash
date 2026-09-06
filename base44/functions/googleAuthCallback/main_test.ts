import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

// Exercise the actual proxy handler with a local fetch stub; no OAuth tokens,
// network requests, persistent fixtures or live Base44 calls are involved.
Deno.test("Google callback forwards request negotiation and cookies while preserving the fixed broker action", async () => {
  const originalServe = Deno.serve;
  const originalFetch = globalThis.fetch;
  let handler: ((request: Request) => Promise<Response>) | undefined;
  try {
    Deno.serve = ((callback: typeof handler) => {
      handler = callback;
      return {};
    }) as typeof Deno.serve;
    await import("./main.ts");
    let observed: {
      url: URL;
      headers: Headers;
      redirect: RequestRedirect | undefined;
    } | undefined;
    globalThis.fetch = ((_input: RequestInfo | URL, init?: RequestInit) => {
      observed = {
        url: new URL(String(_input)),
        headers: new Headers(init?.headers),
        redirect: init?.redirect,
      };
      return Promise.resolve(
        new Response("recovery page", {
          status: 400,
          headers: { "Content-Type": "text/html", "Cache-Control": "no-store" },
        }),
      );
    }) as typeof fetch;
    for (
      const accept of [
        undefined,
        "application/json",
        "text/html,application/xhtml+xml",
      ]
    ) {
      const headers = new Headers({
        Cookie: "transaction=test-only",
        "Accept-Language": "ru-RU",
        Authorization: "must-not-forward",
      });
      if (accept) headers.set("Accept", accept);
      const result = await handler!(
        new Request(
          "https://spyclash.com/functions/googleAuthCallback?action=token&state=test-only",
          { headers },
        ),
      );
      assertEquals(result.status, 400);
      assertEquals(await result.text(), "recovery page");
      assertStringIncludes(result.headers.get("Content-Type")!, "text/html");
      assertEquals(observed!.url.origin, "https://spyclash.com");
      assertEquals(observed!.url.pathname, "/functions/appleAuthBroker");
      assertEquals(observed!.url.searchParams.getAll("action"), [
        "google-callback",
      ]);
      assertEquals(observed!.url.searchParams.get("state"), "test-only");
      assertEquals(
        observed!.headers.get("Accept"),
        accept || "application/json",
      );
      assertEquals(observed!.headers.get("Accept-Language"), "ru-RU");
      assertEquals(observed!.headers.get("Cookie"), "transaction=test-only");
      assertEquals(observed!.headers.get("Authorization"), null);
      assertEquals(observed!.redirect, "manual");
    }
  } finally {
    Deno.serve = originalServe;
    globalThis.fetch = originalFetch;
  }
});
