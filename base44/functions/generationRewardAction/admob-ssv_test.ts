import { adMobDERToRaw, verifyAdMobCallback } from "./admob-ssv.ts";
function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
async function rejects(operation: () => Promise<unknown>) {
  try {
    await operation();
  } catch {
    return;
  }
  throw new Error("Expected rejection");
}
const encode = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));
function rawToDER(raw: Uint8Array) {
  const fields = [raw.slice(0, 32), raw.slice(32)].map((value) => {
    while (value.length > 1 && value[0] === 0) value = value.slice(1);
    if (value[0] & 128) value = new Uint8Array([0, ...value]);
    return new Uint8Array([2, value.length, ...value]);
  });
  return new Uint8Array([
    48,
    fields[0].length + fields[1].length,
    ...fields[0],
    ...fields[1],
  ]);
}
async function fixture(query?: string) {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const publicKey = encode(
    new Uint8Array(await crypto.subtle.exportKey("spki", pair.publicKey)),
  );
  const content = query ||
    "ad_network=1&ad_unit=1234567890&custom_data=hello%2Bworld&reward_amount=1&reward_item=generation&timestamp=1793923200000&transaction_id=0123456789abcdef&user_id=user-1";
  const rawSignature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      pair.privateKey,
      new TextEncoder().encode(decodeURIComponent(content)),
    ),
  );
  const signature = encode(rawToDER(rawSignature)).replace(/\+/g, "-").replace(
    /\//g,
    "_",
  ).replace(/=+$/, "");
  const fetcher = (() =>
    Promise.resolve(
      Response.json({ keys: [{ keyId: 123, base64: publicKey }] }),
    )) as typeof fetch;
  return {
    url:
      `https://example.test/reward?${content}&signature=${signature}&key_id=123`,
    fetcher,
  };
}
Deno.test("SSV verifies DER signature and decodes percent escaping once without losing plus", async () => {
  const f = await fixture();
  const value = await verifyAdMobCallback(f.url, f.fetcher);
  assert(value.customData === "hello+world");
  assert(value.rewardAmount === 1);
  assert(value.userID === "user-1");
});
Deno.test("SSV rejects tampered reward, wrong key and reordered signed content", async () => {
  const f = await fixture();
  await rejects(() =>
    verifyAdMobCallback(
      f.url.replace("reward_amount=1", "reward_amount=99"),
      f.fetcher,
    )
  );
  await rejects(() =>
    verifyAdMobCallback(f.url.replace("key_id=123", "key_id=999"), f.fetcher)
  );
  await rejects(() =>
    verifyAdMobCallback(
      f.url.replace(
        "ad_network=1&ad_unit=1234567890",
        "ad_unit=1234567890&ad_network=1",
      ),
      f.fetcher,
    )
  );
});
Deno.test("SSV rejects duplicate fields, appended unsigned fields and decoded delimiters", async () => {
  const f = await fixture();
  await rejects(() =>
    verifyAdMobCallback(f.url + "&user_id=another", f.fetcher)
  );
  await rejects(() =>
    verifyAdMobCallback(
      f.url.replace("user_id=user-1", "user_id=user-1&user_id=another"),
      f.fetcher,
    )
  );
  const delimiter = await fixture(
    "ad_network=1&ad_unit=1234567890&custom_data=a%26user_id%3Db&reward_amount=1&reward_item=generation&timestamp=1793923200000&transaction_id=0123456789abcdef&user_id=user-1",
  );
  await rejects(() => verifyAdMobCallback(delimiter.url, delimiter.fetcher));
});
Deno.test("SSV rejects malformed DER and never accepts raw WebCrypto signatures as DER", async () => {
  let rejected = false;
  try {
    adMobDERToRaw(new Uint8Array(64).fill(1));
  } catch {
    rejected = true;
  }
  assert(rejected);
  const f = await fixture();
  await rejects(() =>
    verifyAdMobCallback(
      f.url.replace(/signature=[^&]+/, "signature=AA"),
      f.fetcher,
    )
  );
});
Deno.test("SSV key-service failure is retryable and cannot grant a reward", async () => {
  const f = await fixture();
  let status = 0;
  try {
    await verifyAdMobCallback(
      f.url,
      (() =>
        Promise.resolve(new Response("", { status: 503 }))) as typeof fetch,
    );
  } catch (error) {
    status = (error as any).status;
  }
  assert(status === 503);
});
