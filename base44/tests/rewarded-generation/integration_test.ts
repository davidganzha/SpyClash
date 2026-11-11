import { entity, fixture, resetFixture } from "./sdk-stub.ts";
function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
type Handler = (request: Request) => Promise<Response>;
const captured: Handler[] = [];
const serve = Deno.serve;
Deno.serve = ((handler: Handler) => {
  captured.push(handler);
  return {};
}) as any;
try {
  await import("../../functions/generateWordPack/main.ts");
  await import("../../functions/generationRewardAction/main.ts");
} finally {
  Deno.serve = serve;
}
const headers = {
  "content-type": "application/json",
  "Base44-App-Id": "69a0e57fa939f578082f8091",
  "Base44-Service-Authorization": "Bearer fixture-service",
  Authorization: "Bearer fixture-user",
};
async function invoke(handler: Handler, body: any) {
  const response = await handler(
    new Request("https://example.test/function", {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    }),
  );
  return { status: response.status, value: await response.json() };
}
const generate = (requestID = crypto.randomUUID()) =>
  invoke(captured[0], {
    theme: "Fruit",
    count: 5,
    request_id: requestID,
    prefer_fresh: true,
  });
const reward = (body: any) => invoke(captured[1], body);
async function earnBonus(options: { beforeDelivery?: () => void; repeat?: number } = {}) {
  const prepared = await reward({
    action: "prepare",
    request_id: crypto.randomUUID(),
  });
  assert(prepared.status === 200, JSON.stringify(prepared));
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const encode = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));
  const publicKey = encode(
    new Uint8Array(await crypto.subtle.exportKey("spki", pair.publicKey)),
  );
  const query =
    `ad_network=1&ad_unit=1234567890&custom_data=${prepared.value.custom_data}&reward_amount=1&reward_item=generation&timestamp=${Date.now()}&transaction_id=${crypto.randomUUID()}&user_id=${fixture.user.id}`;
  const raw = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      pair.privateKey,
      new TextEncoder().encode(query),
    ),
  );
  const fields = [raw.slice(0, 32), raw.slice(32)].map((value) => {
    while (value.length > 1 && value[0] === 0) value = value.slice(1);
    if (value[0] & 128) value = new Uint8Array([0, ...value]);
    return [2, value.length, ...value];
  });
  const signature = encode(
    new Uint8Array([
      48,
      fields[0].length + fields[1].length,
      ...fields[0],
      ...fields[1],
    ]),
  ).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (() =>
    Promise.resolve(
      Response.json({ keys: [{ keyId: 123, base64: publicKey }] }),
    )) as typeof fetch;
  try {
    options.beforeDelivery?.();
    for (let i = 0; i < (options.repeat || 1); i++) {
      const result = await captured[1](
        new Request(
          `https://example.test/function?${query}&signature=${signature}&key_id=123`,
          // Google sends no user authentication or Base44 routing headers.
          {},
        ),
      );
      assert(result.status === 200, await result.text());
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
  return prepared.value;
}
function enabled() {
  resetFixture();
  entity("GenerationRewardEnrollment").rows.push({id: "enrollment-fixture", user_id: fixture.user.id, provider: "unity", client_build: 228, enrolled_at: new Date().toISOString()});
  Deno.env.set("SPYCLASH_REWARDED_GENERATION_ENABLED", "true");
  Deno.env.delete("SPYCLASH_REWARDED_GENERATION_TEST_USER_IDS");
  Deno.env.set(
    "ADMOB_REWARDED_AD_UNIT_ID",
    "ca-app-pub-1111111111111111/1234567890",
  );
  Deno.env.delete("SPYCLASH_OPENAI_API_KEY");
  Deno.env.delete("OPENAI_API_KEY");
}
Deno.test("complete Base44 route: three free, one signed reward, one extra generation, stable replay", async () => {
  enabled();
  for (let i = 0; i < 3; i++) {
    const result = await generate();
    assert(result.status === 200, JSON.stringify(result));
    assert(result.value.ai_remaining === 2 - i);
  }
  assert((await generate()).status === 429);
  assert(Number(fixture.calls) === 3);
  await earnBonus();
  const status = await reward({ action: "status" });
  assert(status.value.free_remaining === 0 && status.value.bonus_credits === 1);
  const requestID = crypto.randomUUID();
  assert((await generate(requestID)).status === 200);
  assert(Number(fixture.calls) === 4);
  assert((await generate(requestID)).status === 200);
  assert(Number(fixture.calls) === 4);
  assert((await reward({ action: "status" })).value.bonus_credits === 0);
  assert((await generate()).status === 429);
});
Deno.test("Base44 spends free allowance before an already earned bonus", async () => {
  enabled();
  for (let i = 0; i < 3; i++) assert((await generate()).status === 200);
  await earnBonus();
  entity("AiGenerationUsage").rows = []; // Next UTC day restores free allowance.
  assert((await generate()).status === 200);
  const status = await reward({ action: "status" });
  assert(status.value.free_remaining === 2 && status.value.bonus_credits === 1);
});
Deno.test("actual LIMITLESS stays unlimited while CASADA does not bypass activated AI quota", async () => {
  enabled();
  await entity("Entitlement").create({
    user_id: fixture.user.id,
    provider: "apple",
    source_key: "apple:fixture",
    status: "active",
    expires_at: new Date(Date.now() + 86400000).toISOString(),
  });
  for (let i = 0; i < 4; i++) assert((await generate()).status === 200);
  const status = await reward({ action: "status" });
  assert(
    status.value.unlimited && status.value.free_remaining === null &&
      !status.value.ad_available,
  );
  assert(
    (await reward({ action: "prepare", request_id: crypto.randomUUID() }))
      .status === 409,
  );
});
Deno.test("disabling rollout retains prior universal access without advertising", async () => {
  enabled();
  Deno.env.set("SPYCLASH_REWARDED_GENERATION_ENABLED", "false");
  for (let i = 0; i < 4; i++) assert((await generate()).status === 200);
  assert(!(await reward({ action: "status" })).value.enabled);
});
Deno.test("test allowlist belongs to authenticated exact owner, never request fields or email", async () => {
  enabled();
  Deno.env.set("SPYCLASH_REWARDED_GENERATION_ENABLED", "false");
  for (const value of ["", "*", "fixture", fixture.user.email, "FIXTURE-USER", "another-owner"]) {
    Deno.env.set("SPYCLASH_REWARDED_GENERATION_TEST_USER_IDS", value);
    const status = await reward({action: "status", user_id: value, test_ad_available: true, testUser: true});
    assert(status.status === 200 && !status.value.enabled && status.value.bonus_credits === 0);
    assert(!("test_ad_available" in status.value));
    const prepared = await reward({action: "prepare", request_id: crypto.randomUUID(), user_id: value, test_ad_available: true});
    assert(prepared.status === 503);
  }
  Deno.env.set("SPYCLASH_REWARDED_GENERATION_TEST_USER_IDS", " , " + fixture.user.id + " ,another-owner, ");
  const own = await reward({action: "status"});
  assert(own.value.test_ad_available === true && own.value.enabled === false && own.value.ad_available === false);
  fixture.user = {id: "non-target", email: "fixture@example.test", testUser: true};
  assert(!("test_ad_available" in (await reward({action: "status", user_id: "fixture-user"})).value));
  assert((await reward({action: "prepare", request_id: crypto.randomUUID(), user_id: "fixture-user"})).status === 503);
  assert(entity("GenerationReward").rows.length === 0);
});
Deno.test("target test ad earns one real credit while existing universal generation access stays unchanged", async () => {
  enabled();
  Deno.env.set("SPYCLASH_REWARDED_GENERATION_ENABLED", "false");
  Deno.env.set("SPYCLASH_REWARDED_GENERATION_TEST_USER_IDS", fixture.user.id);
  const before = await reward({action: "status"});
  assert(before.value.enabled === false && before.value.free_remaining === null && before.value.bonus_credits === 0);
  const prepared = await earnBonus({repeat: 3});
  const claim = await reward({action: "claim_status", attempt_id: prepared.attempt_id});
  assert(claim.value.state === "earned" && claim.value.bonus_credits === 1 && claim.value.enabled === false);
  assert(entity("GenerationReward").rows.length === 1);
  assert((await reward({action: "prepare", request_id: crypto.randomUUID()})).status === 200);
  for (let i = 0; i < 4; i++) {
    const generated = await generate();
    assert(generated.status === 200 && generated.value.ai_remaining === null);
  }
  assert((await reward({action: "status"})).value.bonus_credits === 1);
  assert(entity("GenerationReward").rows.find(row => row.attempt_id === prepared.attempt_id).state === "earned");
  fixture.user = {id: "non-target", email: "other@example.test"};
  for (let i = 0; i < 4; i++) assert((await generate()).status === 200);
  const other = await reward({action: "status"});
  assert(other.value.enabled === false && other.value.bonus_credits === 0 && !("test_ad_available" in other.value));
});
Deno.test("test offer preserves paid LIMITLESS and cannot bypass the normal activated offer rules", async () => {
  enabled();
  Deno.env.set("SPYCLASH_REWARDED_GENERATION_ENABLED", "false");
  Deno.env.set("SPYCLASH_REWARDED_GENERATION_TEST_USER_IDS", fixture.user.id);
  await entity("Entitlement").create({user_id: fixture.user.id, provider: "apple", source_key: "apple:fixture", status: "active", expires_at: new Date(Date.now() + 86400000).toISOString()});
  await earnBonus();
  const status = await reward({action: "status"});
  assert(status.value.unlimited && status.value.test_ad_available && status.value.bonus_credits === 1);
  assert((await generate()).value.ai_remaining === null);
  Deno.env.set("SPYCLASH_REWARDED_GENERATION_ENABLED", "true");
  const normal = await reward({action: "status"});
  assert(normal.value.enabled && !("test_ad_available" in normal.value));
  assert((await reward({action: "prepare", request_id: crypto.randomUUID()})).value.code === "reward_not_needed");
});
Deno.test("revoking test access blocks new offers but settles an already issued signed event once", async () => {
  enabled();
  Deno.env.set("SPYCLASH_REWARDED_GENERATION_ENABLED", "false");
  Deno.env.set("SPYCLASH_REWARDED_GENERATION_TEST_USER_IDS", fixture.user.id);
  const prepared = await earnBonus({beforeDelivery: () => Deno.env.delete("SPYCLASH_REWARDED_GENERATION_TEST_USER_IDS"), repeat: 2});
  assert((await reward({action: "prepare", request_id: crypto.randomUUID()})).status === 503);
  const hidden = await reward({action: "claim_status", attempt_id: prepared.attempt_id});
  assert(hidden.value.state === "earned" && hidden.value.bonus_credits === 0 && !("test_ad_available" in hidden.value));
  Deno.env.set("SPYCLASH_REWARDED_GENERATION_TEST_USER_IDS", fixture.user.id);
  assert((await reward({action: "status"})).value.bonus_credits === 1);
});
Deno.test("test mode still rejects unsigned grants, client claims and missing or demo ad configuration", async () => {
  enabled();
  Deno.env.set("SPYCLASH_REWARDED_GENERATION_ENABLED", "false");
  Deno.env.set("SPYCLASH_REWARDED_GENERATION_TEST_USER_IDS", fixture.user.id);
  assert((await reward({action: "claim", earned: true})).status === 400);
  assert((await captured[1](new Request("https://example.test/function?user_id=fixture-user&reward_amount=1"))).status === 400);
  for (const unit of ["", "invalid", "ca-app-pub-3940256099942544/1712485313"]) {
    Deno.env.set("ADMOB_REWARDED_AD_UNIT_ID", unit);
    assert((await reward({action: "status"})).value.test_ad_available === false);
    assert((await reward({action: "prepare", request_id: crypto.randomUUID()})).status === 503);
  }
  assert(entity("GenerationReward").rows.length === 0);
});
Deno.test("definitive AI quality failure restores reserved bonus exactly once", async () => {
  enabled();
  for (let i = 0; i < 3; i++) assert((await generate()).status === 200);
  await earnBonus();
  fixture.fail = "quality";
  assert((await generate()).status >= 400);
  assert((await reward({ action: "status" })).value.bonus_credits === 1);
  fixture.fail = null;
  assert((await generate()).status === 200);
  assert((await reward({ action: "status" })).value.bonus_credits === 0);
});
Deno.test("public Google demo unit cannot mint server credits", async () => {
  enabled();
  Deno.env.set(
    "ADMOB_REWARDED_AD_UNIT_ID",
    "ca-app-pub-3940256099942544/1712485313",
  );
  assert(!(await reward({ action: "status" })).value.ad_available);
  assert(
    (await reward({ action: "prepare", request_id: crypto.randomUUID() }))
      .status === 503,
  );
  assert(entity("GenerationReward").rows.length === 0);
});

Deno.test("ambiguous AI timeout holds bonus and replay does not spend or call provider again", async () => {
  enabled();
  for (let i = 0; i < 3; i++) assert((await generate()).status === 200);
  await earnBonus();
  fixture.fail = "timeout";
  const requestID = crypto.randomUUID();
  assert((await generate(requestID)).status >= 400);
  const callsAfterTimeout = fixture.calls;
  assert(entity("GenerationReward").rows[0].state === "reserved");
  fixture.fail = null;
  assert((await generate(requestID)).status >= 400);
  assert(fixture.calls === callsAfterTimeout);
  assert((await reward({ action: "status" })).value.bonus_credits === 0);
});

Deno.test("expired pending attempt unblocks UI without deleting late-reward evidence", async () => {
  enabled();
  const attemptID = crypto.randomUUID();
  for (let i = 0; i < 3; i++) assert((await generate()).status === 200);
  const prepared = await reward({ action: "prepare", request_id: attemptID });
  assert(prepared.status === 200);
  entity("GenerationReward").rows[0].issued_at = new Date(
    Date.now() - 86_700_001,
  ).toISOString();
  const status = await reward({
    action: "claim_status",
    attempt_id: attemptID,
  });
  assert(status.status === 200 && status.value.state === "expired");
  assert(entity("GenerationReward").rows[0].state === "pending");
});

Deno.test("prepare rechecks available free generation and earned credit before requesting ads", async () => {
  enabled();
  assert(
    (await reward({ action: "prepare", request_id: crypto.randomUUID() })).value
      .code === "reward_not_needed",
  );
  assert(entity("GenerationReward").rows.length === 0);
  for (let i = 0; i < 3; i++) assert((await generate()).status === 200);
  await earnBonus();
  assert(
    (await reward({ action: "prepare", request_id: crypto.randomUUID() })).value
      .code === "reward_not_needed",
  );
  assert(entity("GenerationReward").rows.length === 1);
});

Deno.test("quota denial preserves request identity so same request succeeds after a reward", async () => {
  enabled();
  for(let i=0;i<3;i++) assert((await generate()).status === 200);
  const requestID = crypto.randomUUID();
  assert((await generate(requestID)).status === 429);
  assert(!entity("AiWordPackOperation").rows.some(row => row.request_id === requestID));
  await earnBonus();
  const completed = await generate(requestID);
  assert(completed.status === 200, JSON.stringify(completed));
  const calls = fixture.calls;
  assert((await generate(requestID)).status === 200);
  assert(fixture.calls === calls);
  assert((await reward({action:"status"})).value.bonus_credits === 0);
});

Deno.test("direct provider wrapper's non-retryable unknown outcome preserves original bonus", async () => {
  enabled(); for(let i=0;i<3;i++) assert((await generate()).status === 200);
  await earnBonus();
  Deno.env.set("OPENAI_API_KEY", "fixture-key-never-sent");
  const originalFetch=globalThis.fetch;
  let directCalls=0;
  globalThis.fetch=(async()=>{ directCalls++; throw new TypeError("Failed to fetch"); }) as typeof fetch;
  const requestID=crypto.randomUUID();
  try {
    const result=await generate(requestID);
    assert(result.value.code === "generation_outcome_unknown",JSON.stringify(result));
    assert(result.value.retryable === false);
    assert(entity("GenerationReward").rows[0].state === "reserved");
    assert(directCalls===1);
    assert(fixture.calls===3); // No fallback after an ambiguous paid call.
    const replay=await generate(requestID);
    assert(replay.value.code === "generation_outcome_unknown");
    assert(directCalls===1);
  } finally { globalThis.fetch=originalFetch; Deno.env.delete("OPENAI_API_KEY"); }
});
