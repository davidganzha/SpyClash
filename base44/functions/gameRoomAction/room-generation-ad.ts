// Room-wide ad offers coordinate presentation only. They never mint or claim a reward.
const SESSION = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export const ROOM_GENERATION_AD_TTL_MS = 180_000;
const clean = (value: unknown): string => String(value ?? "").trim().toLowerCase();
function reject(message: string, code: string, status = 409): never {
  throw Object.assign(new Error(message), { code, status });
}

export function roomGenerationAdPatch(room: Record<string, any>, actor: Record<string, any>, body: Record<string, any>, now: number): Record<string, any> {
  const email = clean(actor.email);
  if (!email || email !== clean(room.host_email)) reject("Only the host can offer a room ad.", "room_ad_host_required", 403);
  if (!Array.isArray(room.players) || !room.players.some((player: any) => clean(player.email) === email)) reject("The host is no longer in this room.", "room_ad_membership_required", 403);
  const id = clean(body.generation_ad_session_id);
  if (!SESSION.test(id)) reject("Invalid room ad session.", "invalid_room_ad_session", 400);
  if (!["presenting", "ended"].includes(body.generation_ad_state)) reject("Invalid room ad state.", "invalid_room_ad_state", 400);
  if (body.generation_ad_state === "ended") {
    // A delayed completion from A must never dismiss a newer offer B.
    return clean(room.room_generation_ad?.id) === id ? { room_generation_ad: null } : {};
  }
  if (clean(room.status || "waiting") !== "waiting") reject("Room ads are offered in the lobby.", "room_ad_lobby_required");
  if (!Number.isFinite(now)) reject("Invalid server time.", "invalid_server_time", 500);
  if (clean(room.room_generation_ad?.id) === id) return {};
  return { room_generation_ad: { id, host_email: email, started_at: new Date(now).toISOString(), expires_at: new Date(now + ROOM_GENERATION_AD_TTL_MS).toISOString() } };
}

export function projectedRoomGenerationAd(room: Record<string, any>): Record<string, string> | null {
  const ad = room.room_generation_ad;
  if (clean(room.status || "waiting") !== "waiting" || !ad || !SESSION.test(clean(ad.id)) || clean(ad.host_email) !== clean(room.host_email)) return null;
  const started = Date.parse(ad.started_at), expires = Date.parse(ad.expires_at);
  if (!Number.isFinite(started) || !Number.isFinite(expires) || expires <= started || expires - started > ROOM_GENERATION_AD_TTL_MS) return null;
  // Only public presentation metadata crosses the room boundary, never host SID/token/attempt.
  return { id: clean(ad.id), host_email: clean(ad.host_email), started_at: new Date(started).toISOString(), expires_at: new Date(expires).toISOString() };
}
