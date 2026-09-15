import { normalizeActionFailure } from "./gameRoomTransport.js";

/**
 * A regeneration click owns one immutable request ID. A lifecycle conflict can
 * occur after provider work but before result persistence, so the transport
 * must not automatically start another generation on that response.
 */
export async function dispatchWordPackGeneration({
  theme,
  count,
  excludedWords = [],
  invoke,
  makeRequestID = () => `web-${globalThis.crypto.randomUUID()}`,
}) {
  const payload = {
    theme,
    count,
    exclude_words: [...excludedWords],
    request_id: makeRequestID(),
    // Preserve explicit Regenerate behavior while allowing same-request replay.
    prefer_fresh: true,
  };
  try {
    const response = await invoke(payload);
    return response?.data ?? response ?? {};
  } catch (failure) {
    throw normalizeActionFailure(failure);
  }
}
