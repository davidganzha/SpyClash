const ROOM_CODE_PATTERN = /^[A-Z0-9]{4,12}$/;
const ROOM_QUERY_KEYS = ["join", "code", "room"];

export function normalizeRoomCode(value) {
  const code = String(value ?? "").trim().toUpperCase();
  return ROOM_CODE_PATTERN.test(code) ? code : null;
}

function codeFromParams(params) {
  for (const key of ROOM_QUERY_KEYS) {
    const code = normalizeRoomCode(params.get(key));
    if (code) return code;
  }
  return null;
}

function isAllowedWebHost(hostname, currentOrigin) {
  const host = hostname.toLowerCase();
  if (host === "spyclash.com" || host === "www.spyclash.com" || host.endsWith(".base44.app")) {
    return true;
  }

  if (!currentOrigin) return false;
  try {
    return host === new URL(currentOrigin).hostname.toLowerCase();
  } catch {
    return false;
  }
}

function codeFromFragment(fragment) {
  if (!fragment) return null;
  const withoutHash = fragment.startsWith("#") ? fragment.slice(1) : fragment;
  const queryStart = withoutHash.indexOf("?");
  const query = queryStart >= 0
    ? withoutHash.slice(queryStart + 1)
    : withoutHash.startsWith("?")
      ? withoutHash.slice(1)
      : "";

  return query ? codeFromParams(new URLSearchParams(query)) : null;
}

export function roomCodeFromPayload(payload, { currentOrigin = null } = {}) {
  const trimmed = String(payload ?? "").trim();
  const rawCode = normalizeRoomCode(trimmed);
  if (rawCode) return rawCode;

  let url;
  try {
    url = new URL(trimmed);
  } catch {
    return null;
  }

  if (url.protocol === "spyclash:") {
    const host = url.hostname.toLowerCase();
    if (host !== "join" && host !== "room") return null;

    const queryCode = codeFromParams(url.searchParams);
    if (queryCode) return queryCode;

    const pathCode = url.pathname.split("/").filter(Boolean)[0];
    return normalizeRoomCode(pathCode);
  }

  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  if (!isAllowedWebHost(url.hostname, currentOrigin)) return null;

  const queryCode = codeFromParams(url.searchParams);
  if (queryCode) return queryCode;

  const fragmentCode = codeFromFragment(url.hash);
  if (fragmentCode) return fragmentCode;

  const pathParts = url.pathname.split("/").filter(Boolean);
  if (pathParts[0]?.toLowerCase() === "join") {
    return normalizeRoomCode(pathParts[1]);
  }

  return null;
}
