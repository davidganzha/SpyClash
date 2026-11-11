import {createHmac} from "node:crypto";
import {entity, fixture, resetFixture} from "./sdk-stub.ts";
function assert(v: unknown, message = "assertion failed"): asserts v {if (!v) throw new Error(message);}
type Handler = (request: Request) => Promise<Response>;
const captured: Handler[] = [];
const serve = Deno.serve;
Deno.serve = ((handler: Handler) => {captured.push(handler); return {};}) as any;
try {
  await import("../../functions/generateWordPack/main.ts");
  await import("../../functions/generationRewardAction/main.ts");
} finally {Deno.serve = serve;}
const headers = {"content-type": "application/json", "Base44-App-Id": "69a0e57fa939f578082f8091", "Base44-Service-Authorization": "Bearer fixture-service", Authorization: "Bearer fixture-user"};
async function invoke(handler: Handler, body: any) {
  const response = await handler(new Request("https://example.test/function", {method: "POST", headers, body: JSON.stringify(body)}));
  return {status: response.status, value: await response.json()};
}
const reward = (body: any) => invoke(captured[1], body);
const generate = (requestID = crypto.randomUUID()) => invoke(captured[0], {theme: "Fruit", count: 5, request_id: requestID, prefer_fresh: true});
const secret = "fixture-secret-only-not-live";
function enabled() {
  resetFixture();
  entity("GenerationRewardEnrollment").rows.push({id: "enrollment-fixture", user_id: fixture.user.id, provider: "unity", client_build: 228, enrolled_at: new Date().toISOString()});
  for (const [key, value] of Object.entries({SPYCLASH_REWARDED_GENERATION_ENABLED: "true", SPYCLASH_REWARDED_AD_PROVIDER: "unity", UNITY_ADS_GAME_ID: "800429660", UNITY_ADS_REWARDED_PLACEMENT_ID: "BP_Rewarded_iOS", UNITY_ADS_S2S_SECRET: secret})) Deno.env.set(key, value);
  for (const key of ["SPYCLASH_REWARDED_GENERATION_TEST_USER_IDS", "SPYCLASH_OPENAI_API_KEY", "OPENAI_API_KEY"]) Deno.env.delete(key);
}
function signed(token: string, oid = crypto.randomUUID(), extra: Record<string, string> = {}) {
  const fields = {provider: "unity", game_id: "800429660", placement_id: "BP_Rewarded_iOS", sid: token, oid, ...extra};
  const canonical = Object.keys(fields).sort().map(key => `${key}=${fields[key as keyof typeof fields]}`).join(",");
  const query = new URLSearchParams(fields);
  query.set("hmac", createHmac("md5", secret).update(canonical).digest("hex"));
  return "https://example.test/function?" + query;
}
async function exhaust() {for (let i = 0; i < 3; i++) assert((await generate()).status === 200);}
async function prepare() {
  const result = await reward({action: "prepare", request_id: crypto.randomUUID()});
  assert(result.status === 200, JSON.stringify(result));
  return result.value;
}
Deno.test("Unity real handler route: 3 free, verified callback, +1, replay and exactly one spend", async () => {
  enabled(); await exhaust(); assert((await generate()).status === 429);
  const attempt = await prepare();
  assert(attempt.provider === "unity" && attempt.unity_game_id === "800429660" && attempt.ad_unit_id === "BP_Rewarded_iOS");
  assert(attempt.server_id === attempt.custom_data && attempt.server_id.includes(".legacy."));
  assert(entity("GenerationReward").rows[0].ad_unit_id === "unity:800429660:BP_Rewarded_iOS");
  const url = signed(attempt.server_id);
  for (let i = 0; i < 3; i++) {const response = await captured[1](new Request(url)); assert(response.status === 200 && await response.text() === "1");}
  assert((await reward({action: "status"})).value.bonus_credits === 1);
  const requestID = crypto.randomUUID();
  assert((await generate(requestID)).status === 200 && (await generate(requestID)).status === 200);
  assert(fixture.calls === 4 && (await reward({action: "status"})).value.bonus_credits === 0);
  assert((await generate()).status === 429);
});
Deno.test("Unity no client completion, invalid signature, wrong placement or unknown SID can issue credit", async () => {
  enabled(); await exhaust(); const attempt = await prepare();
  assert((await reward({action: "earned", attempt_id: attempt.attempt_id})).status === 400);
  const invalid = [signed(attempt.server_id).replace("hmac=", "hmac=0"), signed(attempt.server_id, crypto.randomUUID(), {placement_id: "Other"}),
    signed(attempt.server_id.replace("legacy", "native")), signed(attempt.server_id.replace(/a$/, "b")) + "&oid=extra"];
  for (const url of invalid) assert((await captured[1](new Request(url))).status === 400);
  assert((await reward({action: "status"})).value.bonus_credits === 0);
});
Deno.test("Unity LIMITLESS is unlimited and never offers or prepares an ad", async () => {
  enabled();
  await entity("Entitlement").create({user_id: fixture.user.id, provider: "apple", source_key: "apple:fixture", status: "active", expires_at: new Date(Date.now() + 86400000).toISOString()});
  for (let i = 0; i < 5; i++) assert((await generate()).status === 200);
  const status = (await reward({action: "status"})).value;
  assert(status.unlimited && status.free_remaining === null && !status.ad_available);
  assert((await reward({action: "prepare", request_id: crypto.randomUUID()})).value.code === "reward_not_needed");
});
Deno.test("Unity missing support secret disables offer and rejects callback without a client fallback", async () => {
  enabled(); await exhaust(); const attempt = await prepare(); Deno.env.delete("UNITY_ADS_S2S_SECRET");
  assert(!(await reward({action: "status"})).value.ad_available);
  assert((await reward({action: "prepare", request_id: crypto.randomUUID()})).status === 503);
  assert((await captured[1](new Request(signed(attempt.server_id)))).status === 503);
  assert(entity("GenerationReward").rows[0].state === "pending");
});
Deno.test("Unity already issued callback survives rollout disable, duplicate after expiry is harmless", async () => {
  enabled(); await exhaust(); const attempt = await prepare(); const url = signed(attempt.server_id);
  Deno.env.set("SPYCLASH_REWARDED_GENERATION_ENABLED", "false");
  assert((await captured[1](new Request(url))).status === 200);
  entity("GenerationReward").rows[0].issued_at = new Date(Date.now() - 172800000).toISOString();
  assert((await captured[1](new Request(url))).status === 200);
  assert(entity("GenerationReward").rows.length === 1 && entity("GenerationReward").rows[0].state === "earned");
});
Deno.test("Unity expiry and deleted attempt never recreate a credit; owner comes from the ledger", async () => {
  enabled(); await exhaust(); const attempt = await prepare(); const url = signed(attempt.server_id);
  fixture.user = {id: "someone-else", email: "other@example.test"};
  assert((await reward({action: "claim_status", attempt_id: attempt.attempt_id})).status === 404);
  entity("GenerationReward").rows[0].issued_at = new Date(Date.now() - 172800000).toISOString();
  assert((await captured[1](new Request(url))).status === 400);
  entity("GenerationReward").rows = [];
  assert((await captured[1](new Request(url))).status === 400);
  assert(entity("GenerationReward").rows.length === 0);
});
Deno.test("older Base44 client keeps legacy access and no ad offer until supported status enrollment", async () => {
  enabled(); entity("GenerationRewardEnrollment").rows = [];
  for (let i=0;i<4;i++) assert((await generate()).status===200);
  for(const fields of [{},{supported_reward_provider:"unity",client_build:227},{supported_reward_provider:"admob",client_build:228},{supported_reward_provider:"unity",client_build:"228"}]) {
    const result=await reward({action:"status",...fields});assert(result.status===200&&!result.value.enabled&&!result.value.ad_available);
  }
  assert(entity("GenerationRewardEnrollment").rows.length===0);
});
Deno.test("supported Base44 status enrolls once; capability removal or downgrade never restores legacy access",async()=>{
  enabled(); entity("GenerationRewardEnrollment").rows=[];
  const body={action:"status",supported_reward_provider:"unity",client_build:228,user_id:"victim-account"};
  assert((await reward(body)).value.enabled);assert((await reward(body)).value.enabled);
  assert(entity("GenerationRewardEnrollment").rows.length===1&&entity("GenerationRewardEnrollment").rows[0].user_id===fixture.user.id);
  for(const fields of [{},{supported_reward_provider:"admob",client_build:200},{supported_reward_provider:"unity",client_build:1}])assert((await reward({action:"status",...fields})).value.enabled);
  await exhaust();assert((await generate()).status===429);
  assert((await reward({action:"status"})).value.free_remaining===0);
  await entity("Entitlement").create({user_id:fixture.user.id,provider:"apple",source_key:"apple:fixture",status:"active",expires_at:new Date(Date.now()+86400000).toISOString()});
  assert((await generate()).status===200);assert((await reward({action:"status"})).value.unlimited);
});
Deno.test("Base44 supported capability cannot enroll before rollout and secure callback configuration",async()=>{
  for(const change of [()=>Deno.env.set("SPYCLASH_REWARDED_GENERATION_ENABLED","false"),()=>Deno.env.delete("UNITY_ADS_S2S_SECRET")]) {
    enabled();entity("GenerationRewardEnrollment").rows=[];change();
    assert(!(await reward({action:"status",supported_reward_provider:"unity",client_build:228})).value.enabled);
    assert(entity("GenerationRewardEnrollment").rows.length===0);
  }
});
Deno.test("Base44 enrollment reconciles lost persistence acknowledgement and remains one row", async () => {
  enabled();entity("GenerationRewardEnrollment").rows=[];
  const store=entity("GenerationRewardEnrollment"),create=store.create.bind(store);let interrupted=true;
  store.create=async(data:any)=>{const saved=await create(data);if(interrupted){interrupted=false;throw Error("fixture lost ack");}return saved;};
  try {
    const body={action:"status",supported_reward_provider:"unity",client_build:228};
    assert((await reward(body)).value.enabled);assert((await reward(body)).value.enabled);
    assert(store.rows.length===1);
  } finally {store.create=create;}
});
Deno.test("Base44 deleted account tombstone rejects late enrollment without recreating policy", async () => {
  enabled();entity("GenerationRewardEnrollment").rows=[];
  const {billingIdentitySubjectKey}=await import("../../functions/generationRewardAction/billing-identity-lifecycle.ts");
  await entity("BillingIdentityLifecycle").create({subject_key:await billingIdentitySubjectKey(fixture.user.id),state:"deleting",revision:crypto.randomUUID(),lease_until:"9999-12-31T23:59:59.999Z",lease_token:crypto.randomUUID()});
  const response=await reward({action:"status",supported_reward_provider:"unity",client_build:228});
  assert(response.status>=400&&entity("GenerationRewardEnrollment").rows.length===0);
});
