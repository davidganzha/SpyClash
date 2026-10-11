const CALLBACK_URL = "https://spyclash.com/MobileAuthCallback.html";

export function isMobileAuthCallbackRoute(location) {
  return location.pathname === "/MobileAuthCallback.html";
}

// This helper deliberately has no imports or browser-storage dependencies.
// Only the fresh response URL can supply a credential; no caller controls the
// native destination. The native app verifies the token before saving it.
export function parseMobileAuthCallbackURL(source) {
  if (typeof source !== "string") return null;
  let url;
  try {
    url = new URL(source);
  } catch (_) {
    return null;
  }
  if (
    url.origin !== "https://spyclash.com" ||
    !isMobileAuthCallbackRoute(url) ||
    url.username !== "" || url.password !== "" || url.port !== "" ||
    source.includes("#") ||
    !(source === CALLBACK_URL || source.startsWith(CALLBACK_URL + "?"))
  ) return null;

  const parameters = url.searchParams;
  const names = Array.from(parameters.keys());
  if (new Set(names).size !== names.length) return null;
  if (parameters.get("auth_provider") !== "google") return null;

  const hasToken = parameters.has("access_token");
  const hasError = parameters.has("error");
  if (hasToken && (hasError || parameters.has("error_description"))) return null;

  let field;
  let value;
  if (hasToken) {
    const token = parameters.get("access_token");
    // Base44 tokens are ASCII. The UTF-16 bound is also conservative for other
    // input; Cc/Cf matches Foundation's control-character rejection.
    if (!token || token.length > 20000 || token !== token.trim() || /[\p{Cc}\p{Cf}]/u.test(token)) return null;
    field = "access_token";
    value = token;
  } else if (hasError) {
    const error = parameters.get("error");
    if (!error || error.length > 128 || error !== error.trim() || /[\p{Cc}\p{Cf}]/u.test(error)) return null;
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
    return null;
  }

  // Descriptions and unrelated query parameters never leave this page.
  return "spyclash://auth?" + field + "=" + encodeURIComponent(value);
}

export function mountMobileAuthCallback(document, window) {
  // Capture this response only, then remove credentials before any UI work.
  const source = window.location.href;
  let cleaned = false;
  try {
    window.history.replaceState(null, "", window.location.origin + window.location.pathname);
    cleaned = true;
  } catch (_) {
    // If the address cannot be cleaned, never process or forward a credential.
  }

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
  const openApp = document.createElement("a");
  openApp.id = "open-app";
  openApp.rel = "noreferrer";
  openApp.hidden = true;
  openApp.textContent = russian ? "Открыть SpyClash" : "Open SpyClash";
  openApp.style.cssText = "margin-top:24px;padding:16px;border-radius:12px;background:#dc2626;color:#fff;text-align:center;text-decoration:none;font-weight:700";
  main.append(title, message, openApp);
  const root = document.getElementById("root") || document.body;
  root.replaceChildren(main);

  const nativeURL = cleaned ? parseMobileAuthCallbackURL(source) : null;
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
