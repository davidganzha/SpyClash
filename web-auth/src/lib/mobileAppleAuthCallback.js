const CALLBACK_URL = "https://spyclash.com/MobileAppleAuthCallback.html";
const FAILURE_CODES = Object.freeze({ invalid_url: "01", fragment: "02", query: "03", duplicate: "04", provider: "05", payload: "06", cleanup: "07" });

export function isMobileAppleAuthCallbackRoute(location) {
  return location.pathname === "/MobileAppleAuthCallback.html";
}

function rejected(reason) { return { nativeURL: null, reason }; }

function validValue(value, maximum) {
  return value.length > 0 && new TextEncoder().encode(value).length <= maximum &&
    value === value.trim() && !/[\p{Cc}\p{Cf}]/u.test(value);
}

export function parseMobileAppleAuthCallbackURL(source) {
  return parseCallback(source).nativeURL;
}

function parseCallback(source) {
  if (typeof source !== "string" || /[\p{Cc}\p{Cf}]/u.test(source)) return rejected("invalid_url");
  let url;
  try { url = new URL(source); } catch (_) { return rejected("invalid_url"); }
  const fragmentIndex = source.indexOf("#");
  if (fragmentIndex !== -1 && !["#", "#_", "#_=_"].includes(source.slice(fragmentIndex))) return rejected("fragment");
  if (url.origin !== "https://spyclash.com" || !isMobileAppleAuthCallbackRoute(url) ||
      url.username !== "" || url.password !== "" || url.port !== "" ||
      !(source === CALLBACK_URL || source.startsWith(CALLBACK_URL + "?"))) return rejected("invalid_url");

  // Match URLComponents query semantics: percent decoding preserves literal +.
  // Every query item is validated, even when it will not be forwarded.
  const parameters = new Map();
  for (const pair of url.search.slice(1).split("&")) {
    const equals = pair.indexOf("=");
    if (equals < 0) return rejected("query");
    let name, value;
    try {
      name = decodeURIComponent(pair.slice(0, equals));
      value = decodeURIComponent(pair.slice(equals + 1));
    } catch (_) { return rejected("query"); }
    if (!validValue(name, 128) || !validValue(value, 20000)) return rejected("query");
    if (parameters.has(name)) return rejected("duplicate");
    parameters.set(name, value);
  }
  if (parameters.get("auth_provider") !== "apple") return rejected("provider");
  const hasToken = parameters.has("access_token"), hasError = parameters.has("error");
  if (hasToken === hasError || (hasToken && parameters.has("error_description"))) return rejected("payload");

  let field = "access_token", value = parameters.get("access_token");
  if (hasError) {
    const safeErrors = {
      access_denied: "access_denied", user_cancelled: "access_denied", user_canceled: "access_denied",
      cancelled: "access_denied", canceled: "access_denied", invalid_state: "invalid_state",
      state_expired: "session_expired", expired_state: "session_expired", session_expired: "session_expired",
      temporarily_unavailable: "temporarily_unavailable", server_error: "temporarily_unavailable",
      service_unavailable: "temporarily_unavailable"
    };
    field = "error";
    const error = parameters.get("error");
    value = Object.prototype.hasOwnProperty.call(safeErrors, error) ? safeErrors[error] : "authentication_failed";
  }
  return { nativeURL: "spyclash://auth?auth_provider=apple&" + field + "=" + encodeURIComponent(value), reason: null };
}

export function mountMobileAppleAuthCallback(document, window) {
  const source = window.location.href;
  let cleaned = false;
  try {
    window.history.replaceState(null, "", window.location.origin + window.location.pathname);
    cleaned = true;
  } catch (_) {
    // Never forward a credential if the address could not be cleared.
  }
  const result = cleaned ? parseCallback(source) : rejected("cleanup");
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
  message.textContent = russian ? "Закройте это окно и снова нажмите вход через Apple в SpyClash."
    : "Close this window and start Apple sign-in again in SpyClash.";
  const diagnostic = document.createElement("p");
  diagnostic.id = "diagnostic";
  diagnostic.style.cssText = "color:#bcbcc4;font-size:13px;line-height:1.5";
  diagnostic.hidden = result.nativeURL !== null;
  if (result.reason) diagnostic.textContent = (russian ? "Код для поддержки: " : "Support code: ") + "SCA-WEB1-" + FAILURE_CODES[result.reason];
  const openApp = document.createElement("a");
  openApp.id = "open-app";
  openApp.rel = "noreferrer";
  openApp.hidden = true;
  openApp.textContent = russian ? "Открыть SpyClash" : "Open SpyClash";
  openApp.style.cssText = "margin-top:24px;padding:16px;border-radius:12px;background:#dc2626;color:#fff;text-align:center;text-decoration:none;font-weight:700";
  main.append(title, message, diagnostic, openApp);
  (document.getElementById("root") || document.body).replaceChildren(main);
  if (!result.nativeURL) return;
  title.textContent = russian ? "Вернитесь в SpyClash" : "Return to SpyClash";
  message.textContent = russian ? "Если приложение не открылось автоматически, нажмите кнопку ниже."
    : "If the app did not open automatically, use the button below.";
  openApp.href = result.nativeURL;
  openApp.hidden = false;
  openApp.style.display = "block";
  try { window.location.replace(result.nativeURL); } catch (_) {
    // A normal link remains available when the browser requires a gesture.
  }
}
