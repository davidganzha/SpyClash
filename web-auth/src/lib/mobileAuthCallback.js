const CALLBACK_URL = "https://spyclash.com/MobileAuthCallback.html";
let mountCount = 0;
const FAILURE_CODES = Object.freeze({
  invalid_url: "01",
  fragment: "02",
  duplicate_parameter: "03",
  empty_query: "04",
  missing_provider: "05",
  wrong_provider: "06",
  missing_payload: "07",
  mixed_payload: "08",
  invalid_token: "09",
  invalid_error: "10",
  history_cleanup_failed: "11"
});

function rejected(reason) {
  return { nativeURL: null, reason };
}

export function isMobileAuthCallbackRoute(location) {
  return location.pathname === "/MobileAuthCallback.html";
}

// This helper deliberately has no imports or browser-storage dependencies.
// Only the fresh response URL can supply a credential; no caller controls the
// native destination. The native app verifies the token before saving it.
export function parseMobileAuthCallbackURL(source) {
  return parseMobileAuthCallbackResult(source).nativeURL;
}

function parseMobileAuthCallbackResult(source) {
  if (typeof source !== "string") return rejected("invalid_url");
  let url;
  try {
    url = new URL(source);
  } catch (_) {
    return rejected("invalid_url");
  }
  // Redirects can preserve an empty fragment or an inert OAuth marker. Read
  // the raw suffix: URL.hash cannot distinguish no fragment from an empty #.
  // Credentials still come only from the query; never decode or merge a hash.
  const fragmentIndex = source.indexOf("#");
  if (fragmentIndex !== -1 && !["#", "#_", "#_=_"].includes(source.slice(fragmentIndex))) {
    return rejected("fragment");
  }
  if (
    url.origin !== "https://spyclash.com" ||
    !isMobileAuthCallbackRoute(url) ||
    url.username !== "" || url.password !== "" || url.port !== "" ||
    !(source === CALLBACK_URL || source.startsWith(CALLBACK_URL + "?"))
  ) return rejected("invalid_url");

  const parameters = url.searchParams;
  const names = Array.from(parameters.keys());
  if (new Set(names).size !== names.length) return rejected("duplicate_parameter");
  if (names.length === 0) return rejected("empty_query");
  if (!parameters.has("auth_provider")) return rejected("missing_provider");
  if (parameters.get("auth_provider") !== "google") return rejected("wrong_provider");

  const hasToken = parameters.has("access_token");
  const hasError = parameters.has("error");
  if (hasToken && (hasError || parameters.has("error_description"))) return rejected("mixed_payload");

  let field;
  let value;
  if (hasToken) {
    const token = parameters.get("access_token");
    // Base44 tokens are ASCII. The UTF-16 bound is also conservative for other
    // input; Cc/Cf matches Foundation's control-character rejection.
    if (!token || token.length > 20000 || token !== token.trim() || /[\p{Cc}\p{Cf}]/u.test(token)) return rejected("invalid_token");
    field = "access_token";
    value = token;
  } else if (hasError) {
    const error = parameters.get("error");
    if (!error || error.length > 128 || error !== error.trim() || /[\p{Cc}\p{Cf}]/u.test(error)) return rejected("invalid_error");
    const safeErrors = {
      access_denied: "access_denied",
      user_cancelled: "access_denied",
      user_canceled: "access_denied",
      cancelled: "access_denied",
      canceled: "access_denied",
      invalid_state: "invalid_state",
      state_expired: "session_expired",
      expired_state: "session_expired",
      session_expired: "session_expired",
      temporarily_unavailable: "temporarily_unavailable",
      server_error: "temporarily_unavailable",
      service_unavailable: "temporarily_unavailable"
    };
    field = "error";
    const normalized = error.toLowerCase();
    value = Object.prototype.hasOwnProperty.call(safeErrors, normalized)
      ? safeErrors[normalized]
      : "authentication_failed";
  } else {
    return rejected("missing_payload");
  }

  // Descriptions and unrelated query parameters never leave this page.
  return { nativeURL: "spyclash://auth?" + field + "=" + encodeURIComponent(value), reason: null };
}

function navigationKind(window) {
  try {
    const kind = window.performance?.getEntriesByType("navigation")?.[0]?.type;
    if (["navigate", "reload", "back_forward"].includes(kind)) return kind;
  } catch (_) {
    // Diagnostics never depend on timing support or an exception's message.
  }
  return "unknown";
}

export function mountMobileAuthCallback(document, window) {
  // Per-module memory only: a document reload starts over, repeated mounts do not.
  mountCount = Math.min(2, mountCount + 1);
  // Capture this response only, then remove credentials before any UI work.
  const source = window.location.href;
  let cleaned = false;
  try {
    window.history.replaceState(null, "", window.location.origin + window.location.pathname);
    cleaned = true;
  } catch (_) {
    // If the address cannot be cleaned, never process or forward a credential.
  }
  const result = cleaned
    ? parseMobileAuthCallbackResult(source)
    : rejected("history_cleanup_failed");

  const russian = (window.navigator.language || "").toLowerCase().startsWith("ru");
  document.documentElement.lang = russian ? "ru" : "en";
  document.title = russian ? "Вход в SpyClash" : "SpyClash sign-in";
  document.body.style.cssText = "margin:0;background:#080808;color:#f4f4f5;font:17px -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;color-scheme:dark";
  const main = document.createElement("main");
  main.style.cssText = "max-width:420px;margin:12vh auto;padding:24px";
  const title = document.createElement("h1");
  title.id = "title";
  title.style.cssText = "font-size:28px;line-height:1.2";
  title.textContent = russian ? "Не удалось завершить вход" : "Sign-in could not be completed";
  const message = document.createElement("p");
  message.id = "message";
  message.style.cssText = "color:#bcbcc4;line-height:1.5";
  message.textContent = russian
    ? "Закройте это окно и снова нажмите вход через Google в SpyClash."
    : "Close this window and start Google sign-in again in SpyClash.";
  const diagnostic = document.createElement("p");
  diagnostic.id = "diagnostic";
  diagnostic.style.cssText = "color:#bcbcc4;font-size:13px;line-height:1.5";
  diagnostic.hidden = result.nativeURL !== null;
  if (result.reason) {
    // Only fixed codes and an allowlisted navigation kind reach the UI.
    const code = "SCG175-" + FAILURE_CODES[result.reason] + " · " + navigationKind(window) +
      " · " + (mountCount === 1 ? "m1" : "m2+");
    diagnostic.textContent = (russian ? "Код для поддержки: " : "Support code: ") + code;
  }
  const openApp = document.createElement("a");
  openApp.id = "open-app";
  openApp.rel = "noreferrer";
  openApp.hidden = true;
  openApp.textContent = russian ? "Открыть SpyClash" : "Open SpyClash";
  openApp.style.cssText = "margin-top:24px;padding:16px;border-radius:12px;background:#dc2626;color:#fff;text-align:center;text-decoration:none;font-weight:700";
  main.append(title, message, diagnostic, openApp);
  const root = document.getElementById("root") || document.body;
  root.replaceChildren(main);

  const nativeURL = result.nativeURL;
  if (!nativeURL) return;
  title.textContent = russian ? "Вернитесь в SpyClash" : "Return to SpyClash";
  message.textContent = russian
    ? "Если приложение не открылось автоматически, нажмите кнопку ниже."
    : "If the app did not open automatically, use the button below.";
  openApp.href = nativeURL;
  openApp.hidden = false;
  openApp.style.display = "block";
  try {
    window.location.replace(nativeURL);
  } catch (_) {
    // The normal link remains available for a browser requiring a gesture.
  }
}
