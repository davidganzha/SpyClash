import { copyResponseHeaders } from "./headers.ts";

const BROKER_CALLBACK_URL =
  "https://spyclash.com/functions/appleAuthBroker?action=google-callback";
const CLEAR_TRANSACTION_COOKIE =
  "__Host-SpyClashOAuthTransaction=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=None";
const CLEAR_FALLBACK_TRANSACTION_COOKIE =
  "__Secure-SpyClashOAuthTransactionFallback=; Max-Age=0; Path=/functions/; Secure; SameSite=None";

function jsonError(status: number, error: string) {
  const headers = new Headers({
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  });
  headers.append("Set-Cookie", CLEAR_TRANSACTION_COOKIE);
  headers.append("Set-Cookie", CLEAR_FALLBACK_TRANSACTION_COOKIE);
  return Response.json(
    { error },
    {
      status,
      headers,
    },
  );
}

Deno.serve(async (req) => {
  if (req.method !== "GET") {
    return jsonError(405, "method_not_allowed");
  }

  try {
    const brokerURL = new URL(BROKER_CALLBACK_URL);
    const incomingURL = new URL(req.url);
    for (const [key, value] of incomingURL.searchParams) {
      if (key !== "action") brokerURL.searchParams.append(key, value);
    }

    // Preserve content negotiation so API callers keep JSON errors while the
    // browser can render the broker's recoverable sign-in failure page.
    const headers = new Headers({
      Accept: req.headers.get("accept") || "application/json",
    });
    const language = req.headers.get("accept-language");
    if (language) headers.set("Accept-Language", language);
    const cookie = req.headers.get("cookie");
    if (cookie) headers.set("Cookie", cookie);

    const upstream = await fetch(brokerURL, {
      method: "GET",
      headers,
      redirect: "manual",
    });

    return new Response(upstream.body, {
      status: upstream.status,
      statusText: upstream.statusText,
      headers: copyResponseHeaders(upstream.headers),
    });
  } catch {
    return jsonError(502, "broker_unavailable");
  }
});
