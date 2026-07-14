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
    const parsed = JSON.parse(rawState) as unknown;
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
