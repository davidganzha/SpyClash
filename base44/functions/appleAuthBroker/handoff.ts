import { randomBase64Url } from "./transaction.ts";

const BASE_HEADERS = {
  "Cache-Control": "no-store",
  "Content-Type": "text/html; charset=utf-8",
  Pragma: "no-cache",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
};

function scriptLiteral(value: string) {
  return JSON.stringify(value)
    .replaceAll("<", "\\u003c")
    .replaceAll(">", "\\u003e")
    .replaceAll("&", "\\u0026")
    .replaceAll("\u2028", "\\u2028")
    .replaceAll("\u2029", "\\u2029");
}

function handoffResponse(script: string, cookie?: string) {
  const nonce = randomBase64Url(18);
  const headers = new Headers({
    ...BASE_HEADERS,
    "Content-Security-Policy":
      `default-src 'none'; script-src 'nonce-${nonce}'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'`,
  });
  if (cookie) headers.append("Set-Cookie", cookie);

  const body =
    `<!doctype html><html><head><meta charset="utf-8"><meta name="referrer" content="no-referrer"><title>SpyClash</title></head><body><script nonce="${nonce}">${script}</script></body></html>`;
  return new Response(body, { status: 200, headers });
}

export function primaryGoogleTransactionHandoff(
  confirmationURL: string,
  primaryCookie: string,
) {
  return handoffResponse(
    `window.location.replace(${scriptLiteral(confirmationURL)});`,
    primaryCookie,
  );
}

export function fallbackGoogleTransactionHandoff(
  confirmationURL: string,
  fallbackCookie: string,
) {
  return handoffResponse(
    `document.cookie=${scriptLiteral(fallbackCookie)};window.location.replace(${
      scriptLiteral(confirmationURL)
    });`,
  );
}
