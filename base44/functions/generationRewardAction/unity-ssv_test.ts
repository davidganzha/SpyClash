import { createHmac } from "node:crypto";
import { isUnityCallback, unityAttemptFields, unityRewardUnit, verifyUnityCallback } from "./unity-ssv.ts";
const assert = (v: unknown, message = "assertion failed") => { if (!v) throw new Error(message); };
const config = { UNITY_ADS_GAME_ID: "800429660", UNITY_ADS_REWARDED_PLACEMENT_ID: "BP_Rewarded_iOS", UNITY_ADS_S2S_SECRET: "fixture-secret-only-not-live" };
const sid = "11111111-1111-4111-8111-111111111111.legacy." + "a".repeat(64);
function signed(overrides: Record<string, string> = {}) {
  const values = {provider: "unity", game_id: "800429660", placement_id: "BP_Rewarded_iOS", sid, oid: "offer_123", ...overrides};
  const canonical = Object.keys(values).sort().map(key => `${key}=${values[key as keyof typeof values]}`).join(",");
  const params = new URLSearchParams(values);
  params.set("hmac", createHmac("md5", config.UNITY_ADS_S2S_SECRET).update(canonical).digest("hex"));
  return "https://example.test/callback?" + params;
}
Deno.test("Unity HMAC authenticates provider, game, placement, complete SID and offer", () => {
  const result = verifyUnityCallback(signed(), config);
  assert(result.customData === sid && result.transactionID === "unity:800429660:offer_123");
  assert(result.adUnit === "unity:800429660:BP_Rewarded_iOS" && result.rewardAmount === 1);
  assert(isUnityCallback(signed()) && !isUnityCallback("https://example.test/?signature=abc"));
});
Deno.test("Unity callback signature uses alphabetical decoded values independent of URL parameter order", () => {
  const url = new URL(signed());
  const pairs = [...url.searchParams].reverse();
  url.search = new URLSearchParams(pairs).toString().replaceAll(".", "%2e");
  assert(verifyUnityCallback(url.href, config).customData === sid);
});
Deno.test("Unity signed callback fails closed for mutation, duplicate keys and ambiguous canonicalization", () => {
  const url = signed();
  const invalid = [url.replace("offer_123", "offer_124"), url.replace("legacy", "native"), url.replace("BP_Rewarded_iOS", "Other"),
    url + "&sid=" + sid, url + "&unexpected=value", url.replace("hmac=", "hmac=0"), signed({oid: "x,y=z"}), signed({game_id: "14850"}),
    signed({sid: "11111111-1111-4111-8111-111111111111.unknown." + "a".repeat(64)}), signed({oid: "x".repeat(181)})];
  for (const value of invalid) {
    let rejected = false;
    try { verifyUnityCallback(value, config); } catch { rejected = true; }
    assert(rejected, value);
  }
});
Deno.test("Unity requires owned project and support-issued server secret, without fallback", () => {
  for (const c of [{}, {...config, UNITY_ADS_S2S_SECRET: ""}, {...config, UNITY_ADS_GAME_ID: "14850"}, {...config, UNITY_ADS_REWARDED_PLACEMENT_ID: "bad:unit"}]) {
    assert(unityRewardUnit(c) === null);
    let rejected = false;
    try { verifyUnityCallback(signed(), c); } catch { rejected = true; }
    assert(rejected);
  }
  let rejected = false;
  try { verifyUnityCallback(signed(), {...config, UNITY_ADS_S2S_SECRET: "different-fixture-only-secret"}); } catch { rejected = true; }
  assert(rejected);
});
Deno.test("Unity attempt exposes only SDK placement/game/SID while preserving AdMob IDs", () => {
  const fields = unityAttemptFields("unity:800429660:BP_Rewarded_iOS", sid);
  assert(fields.provider === "unity" && fields.ad_unit_id === "BP_Rewarded_iOS" && fields.server_id === sid && fields.unity_game_id === "800429660");
  const google = unityAttemptFields("ca-app-pub-1111111111111111/1234567890", sid);
  assert(google.provider === "admob" && google.ad_unit_id.startsWith("ca-app-pub-") && !("server_id" in google));
});
