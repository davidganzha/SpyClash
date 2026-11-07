export type UpstreamAuthProvider = "apple" | "google";

type Base44State = {
  app_id?: unknown;
  from_url?: unknown;
};

/**
 * Base44 creates the OIDC state value and embeds the eventual return URL in
 * `from_url`. Provider selection is deliberately read only from that state;
 * query parameters sent directly to the broker cannot switch providers.
 */
export function upstreamProviderFromBase44State(
  rawState: string,
  appId: string,
  publicOrigin: string,
): UpstreamAuthProvider {
  if (!rawState || rawState.length > 4096) return "apple";

  let state: Base44State;
  try {
    let stateJSON = rawState;
    if (!rawState.trimStart().startsWith("{")) {
      // Base44 also sends the same JSON as Base64URL, optionally padded.
      if (
        !/^(?:[A-Za-z0-9_-]{4})*(?:[A-Za-z0-9_-]{2}(?:==)?|[A-Za-z0-9_-]{3}=?)?$/
          .test(rawState)
      ) {
        return "apple";
      }
      const binary = atob(rawState.replace(/-/g, "+").replace(/_/g, "/"));
      const canonical = btoa(binary).replace(/\+/g, "-").replace(/\//g, "_")
        .replace(/=+$/, "");
      if (canonical !== rawState.replace(/=+$/, "")) return "apple";
      stateJSON = new TextDecoder("utf-8", { fatal: true }).decode(
        Uint8Array.from(binary, (character) => character.charCodeAt(0)),
      );
    }
    const parsed = JSON.parse(stateJSON) as unknown;
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return "apple";
    }
    state = parsed as Base44State;
  } catch {
    return "apple";
  }

  if (state.app_id !== appId || typeof state.from_url !== "string") {
    return "apple";
  }
  if (!state.from_url || state.from_url.length > 2048) return "apple";

  try {
    const expectedOrigin = new URL(publicOrigin);
    const fromURL = new URL(state.from_url);
    const providerMarkers = fromURL.searchParams.getAll("auth_provider");
    const isValidatedReturnURL = expectedOrigin.protocol === "https:" &&
      fromURL.protocol === expectedOrigin.protocol &&
      fromURL.hostname === expectedOrigin.hostname &&
      fromURL.port === expectedOrigin.port &&
      fromURL.username === "" &&
      fromURL.password === "" &&
      fromURL.hash === "";

    if (
      isValidatedReturnURL &&
      providerMarkers.length === 1 &&
      providerMarkers[0] === "google"
    ) {
      return "google";
    }
  } catch {
    // Invalid or non-HTTPS return URLs cannot opt into another provider.
  }

  return "apple";
}
