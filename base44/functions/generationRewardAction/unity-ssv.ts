import { createHmac, timingSafeEqual } from "node:crypto";

/** Unity's provider protocol uses HMAC-MD5 (not a client assertion).
 * https://docs.unity.com/en-us/grow/ads/mediation/s2s-redeem-callbacks
 * The support-issued secret exists only on the server. */
export type UnityRewardConfig = Record<string, string | undefined>;
export class UnityVerificationError extends Error {
  constructor(readonly code: string, readonly status = 400) { super(code); }
}
export function unityRewardUnit(config: UnityRewardConfig): string | null {
  const game = config.UNITY_ADS_GAME_ID?.trim() || "";
  const placement = config.UNITY_ADS_REWARDED_PLACEMENT_ID?.trim() || "";
  const secret = config.UNITY_ADS_S2S_SECRET || "";
  return /^[1-9][0-9]{0,15}$/.test(game) && game !== "14850" &&
      /^[A-Za-z0-9_-]{1,80}$/.test(placement) && secret.length >= 16
    ? `unity:${game}:${placement}` : null;
}
export function unityAttemptFields(unit: string, token: string) {
  const match = /^unity:([1-9][0-9]{0,15}):([A-Za-z0-9_-]{1,80})$/.exec(unit);
  return match ? { provider: "unity", unity_game_id: match[1], ad_unit_id: match[2], server_id: token }
    : { provider: "admob", ad_unit_id: unit };
}
export function isUnityCallback(url: string): boolean {
  const params = new URL(url).searchParams;
  return params.get("provider") === "unity" || params.has("hmac") || params.has("sid");
}
export function verifyUnityCallback(url: string, config: UnityRewardConfig) {
  const configured = unityRewardUnit(config);
  if (!configured) throw new UnityVerificationError("unity_reward_unconfigured", 503);
  const fail = (): never => { throw new UnityVerificationError("invalid_reward_signature"); };
  const query = new URL(url).search;
  if (!query || query.length > 4096) return fail();
  const params = new URLSearchParams(query);
  const values = new Map<string, string>();
  for (const [name, value] of params) {
    // Closed contract prevents ambiguous comma/equal concatenation and duplicate keys.
    if (!/^[a-z_]+$/.test(name) || values.has(name) || /[,=\u0000-\u0020]/.test(value)) return fail();
    values.set(name, value);
  }
  const allowed = ["provider", "game_id", "placement_id", "sid", "oid", "hmac"];
  if (values.size !== allowed.length || allowed.some(key => !values.get(key))) return fail();
  if (values.get("provider") !== "unity" ||
      `unity:${values.get("game_id")}:${values.get("placement_id")}` !== configured) return fail();
  const sid = values.get("sid")!, oid = values.get("oid")!, signature = values.get("hmac")!;
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(legacy|native)\.[0-9a-f]{64}$/.test(sid) ||
      !/^[A-Za-z0-9_-]{1,180}$/.test(oid) || !/^[0-9a-fA-F]{32}$/.test(signature)) return fail();
  const canonical = [...values.keys()].filter(key => key !== "hmac").sort()
    .map(key => `${key}=${values.get(key)}`).join(",");
  const expected = createHmac("md5", config.UNITY_ADS_S2S_SECRET!).update(canonical).digest();
  const supplied = Uint8Array.from(signature.match(/../g)!, pair => Number.parseInt(pair, 16));
  if (!timingSafeEqual(expected, supplied)) return fail();
  return { transactionID: `unity:${values.get("game_id")}:${oid}`, customData: sid,
    adUnit: configured, rewardAmount: 1, rewardItem: "generation" };
}
