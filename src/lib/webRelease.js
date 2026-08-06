const ENTRY_SCRIPT_SELECTOR = 'script[type="module"][src*="/assets/index-"]';
const UPDATE_QUERY_KEY = "_sc_update";

export const WEB_RELEASE_CHECK_INTERVAL_MILLISECONDS = 60_000;

export function entryScriptPathFromDocument(documentLike, baseURL) {
  const script = documentLike?.querySelector?.(ENTRY_SCRIPT_SELECTOR);
  const source = script?.getAttribute?.("src");
  if (!source) return null;

  try {
    return new URL(source, baseURL || documentLike?.baseURI).pathname;
  } catch {
    return null;
  }
}

export function webReleaseHasChanged(currentEntryPath, latestEntryPath) {
  return Boolean(
    currentEntryPath
    && latestEntryPath
    && currentEntryPath !== latestEntryPath
  );
}

export async function checkForWebRelease(options = {}) {
  const documentLike = options.documentLike ?? globalThis.document;
  const locationLike = options.locationLike ?? globalThis.location;
  const fetchImpl = options.fetchImpl ?? globalThis.fetch;
  const DOMParserImpl = options.DOMParserImpl ?? globalThis.DOMParser;
  const now = options.now ?? Date.now;
  const currentEntryPath = entryScriptPathFromDocument(
    documentLike,
    locationLike?.href,
  );
  // Vite development pages load /src/main.jsx instead of a hashed entry.
  if (!currentEntryPath) return false;

  try {
    if (!locationLike?.origin || !fetchImpl || !DOMParserImpl) return false;
    const indexURL = new URL("/", locationLike.origin);
    indexURL.searchParams.set(UPDATE_QUERY_KEY, String(now()));
    const response = await fetchImpl(indexURL.href, {
      cache: "no-store",
      credentials: "same-origin",
      headers: { Accept: "text/html" },
    });
    if (!response.ok) return false;

    const latestDocument = new DOMParserImpl().parseFromString(
      await response.text(),
      "text/html",
    );
    const latestEntryPath = entryScriptPathFromDocument(
      latestDocument,
      locationLike.origin,
    );
    return webReleaseHasChanged(currentEntryPath, latestEntryPath);
  } catch {
    return false;
  }
}

export function reloadForWebRelease(options = {}) {
  const locationLike = options.locationLike ?? globalThis.location;
  const now = options.now ?? Date.now;
  if (!locationLike?.href || typeof locationLike.replace !== "function") return;
  const reloadURL = new URL(locationLike.href);
  reloadURL.searchParams.set(UPDATE_QUERY_KEY, String(now()));
  locationLike.replace(reloadURL.href);
}
