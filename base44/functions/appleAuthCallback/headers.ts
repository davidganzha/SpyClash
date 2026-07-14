const ALLOWED_COOKIE_NAMES = new Set([
  "__Host-SpyClashOAuthTransaction",
  "__Host-SpyClashNativeOIDC",
]);

const SKIPPED_HEADERS = new Set([
  "connection",
  "content-encoding",
  "content-length",
  "set-cookie",
  "transfer-encoding",
]);

function splitSetCookieHeader(value: string) {
  return value
    .split(/,(?=\s*[^;,=\s]+=)/)
    .map((cookie) => cookie.trim())
    .filter(Boolean);
}

function responseSetCookies(source: Headers) {
  const sourceWithCookies = source as Headers & {
    getSetCookie?: () => string[];
  };
  const direct = sourceWithCookies.getSetCookie?.() || [];
  const raw = direct.length > 0
    ? direct
    : (source.get("set-cookie") ? [source.get("set-cookie")!] : []);
  return raw.flatMap(splitSetCookieHeader);
}

export function copyResponseHeaders(source: Headers) {
  const headers = new Headers();
  // Fetch may transparently decode a response body. Let the runtime calculate
  // transport headers for the new response.
  for (const [name, value] of source) {
    if (!SKIPPED_HEADERS.has(name.toLowerCase())) headers.append(name, value);
  }

  // Only application-owned cookies may cross the callback proxy. Internal
  // worker cookies are invalid for spyclash.com and can corrupt folded headers.
  for (const cookie of responseSetCookies(source)) {
    const separator = cookie.indexOf("=");
    if (separator < 1) continue;
    if (ALLOWED_COOKIE_NAMES.has(cookie.slice(0, separator).trim())) {
      headers.append("Set-Cookie", cookie);
    }
  }
  return headers;
}
