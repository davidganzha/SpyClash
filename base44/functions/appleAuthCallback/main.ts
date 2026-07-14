import { copyResponseHeaders } from "./headers.ts";

const BROKER_CALLBACK_URL =
  "https://spyclash.com/functions/appleAuthBroker?action=apple-callback";
const MAX_CALLBACK_BODY_BYTES = 64 * 1024;
const CLEAR_TRANSACTION_COOKIE =
  "__Host-SpyClashOAuthTransaction=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=None";

function jsonError(status: number, error: string) {
  return Response.json(
    { error },
    {
      status,
      headers: {
        "Cache-Control": "no-store",
        "Set-Cookie": CLEAR_TRANSACTION_COOKIE,
        "X-Content-Type-Options": "nosniff",
      },
    },
  );
}

Deno.serve(async (req) => {
  if (req.method !== "POST" && req.method !== "GET") {
    return jsonError(405, "method_not_allowed");
  }

  try {
    const brokerURL = new URL(BROKER_CALLBACK_URL);
    const incomingURL = new URL(req.url);
    for (const [key, value] of incomingURL.searchParams) {
      if (key !== "action") brokerURL.searchParams.append(key, value);
    }

    let body: ArrayBuffer | undefined;
    const headers = new Headers({ Accept: "text/html,application/json" });
    const cookie = req.headers.get("cookie");
    if (cookie) headers.set("Cookie", cookie);

    if (req.method === "POST") {
      const declaredLength = Number(req.headers.get("content-length") || "0");
      if (
        Number.isFinite(declaredLength) &&
        declaredLength > MAX_CALLBACK_BODY_BYTES
      ) {
        return jsonError(413, "callback_too_large");
      }

      body = await req.arrayBuffer();
      if (body.byteLength > MAX_CALLBACK_BODY_BYTES) {
        return jsonError(413, "callback_too_large");
      }

      headers.set(
        "Content-Type",
        req.headers.get("content-type") || "application/x-www-form-urlencoded",
      );
    }

    const upstream = await fetch(brokerURL, {
      method: req.method,
      headers,
      body,
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
