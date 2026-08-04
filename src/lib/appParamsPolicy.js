const OFFICIAL_PRODUCTION_HOSTS = new Set([
  "spyclash.com",
  "www.spyclash.com",
  "spy-game-zone.base44.app",
]);

// Public, non-secret Base44 application identity. Keep this in tracked source
// so a clean release build cannot silently depend on a developer's ignored
// .env.local file.
export const SPYCLASH_BASE44_APP_ID = "69a0e57fa939f578082f8091";

function clean(value) {
  const normalized = String(value ?? "").trim();
  return normalized || null;
}

function cleanHttpOrigin(value) {
  const normalized = clean(value);
  if (!normalized) return null;

  try {
    const url = new URL(normalized);
    if (!['http:', 'https:'].includes(url.protocol)) return null;
    if (url.username || url.password) return null;
    return url.origin;
  } catch {
    return null;
  }
}

export function isProductionAppOrigin(locationLike) {
  const protocol = String(locationLike?.protocol ?? "").toLowerCase();
  const hostname = String(locationLike?.hostname ?? "").toLowerCase();
  if (protocol !== "https:" || !hostname) return false;
  return OFFICIAL_PRODUCTION_HOSTS.has(hostname);
}

/**
 * Resolve the Base44 application identity without allowing a stale browser or
 * a crafted production URL to redirect SpyClash to another Base44 app.
 */
export function resolveAppId({
  urlValue,
  environmentValue,
  storedValue,
  productionOrigin,
}) {
  const explicit = clean(urlValue);
  const configured = clean(environmentValue);
  const stored = clean(storedValue);

  if (productionOrigin) {
    return {
      value: SPYCLASH_BASE44_APP_ID,
      persist: false,
      clearStored: Boolean(stored && stored !== SPYCLASH_BASE44_APP_ID),
    };
  }

  const value = explicit || configured;
  return {
    value,
    persist: false,
    clearStored: Boolean(stored),
  };
}

/**
 * Base44 auth routes are same-origin in Production. Never allow a public URL
 * or persisted browser value to replace that origin and create an auth
 * redirect to another host.
 */
export function resolveAppBaseUrl({
  urlValue,
  environmentValue,
  storedValue,
  productionOrigin,
}) {
  const stored = clean(storedValue);

  if (productionOrigin) {
    return {
      value: null,
      persist: false,
      clearStored: Boolean(stored),
    };
  }

  return {
    value: cleanHttpOrigin(urlValue) || cleanHttpOrigin(environmentValue),
    persist: false,
    clearStored: Boolean(stored),
  };
}

/**
 * A preview function version may be used when it is explicitly present in the
 * current URL. A value left in localStorage by an older preview must never pin
 * the public site to stale backend code.
 */
export function resolveFunctionsVersion({
  urlValue,
  environmentValue,
  storedValue,
  productionOrigin,
}) {
  const explicit = clean(urlValue);
  const configured = clean(environmentValue);
  const stored = clean(storedValue);

  if (productionOrigin) {
    return {
      value: null,
      persist: false,
      clearStored: Boolean(stored),
    };
  }

  if (explicit) {
    return {
      value: explicit,
      persist: true,
      clearStored: false,
    };
  }

  if (configured) {
    return {
      value: configured,
      persist: true,
      clearStored: false,
    };
  }

  return {
    value: stored,
    persist: false,
    clearStored: false,
  };
}
