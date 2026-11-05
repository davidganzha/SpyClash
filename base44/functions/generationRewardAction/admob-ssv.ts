/** Google SSV verification, independent of persistence. Never accepts client reward callbacks.
 * Signature input follows Google's URI.getQuery() example: percent-decode once,
 * retain parameter order and literal '+', and exclude signature/key_id.
 * https://developers.google.com/admob/ios/ssv */
export type VerifiedAdMobCallback = {
  transactionID: string;
  customData: string;
  userID: string;
  adUnit: string;
  rewardAmount: number;
  rewardItem: string;
  timestamp: number;
};
export class AdMobVerificationError extends Error {
  constructor(readonly code: string, readonly status = 400) {
    super(code);
  }
}
const KEYS_URL = "https://www.gstatic.com/admob/reward/verifier-keys.json";
function fail(): never {
  throw new AdMobVerificationError("invalid_reward_signature");
}
function bytes(value: string): Uint8Array<ArrayBuffer> {
  try {
    const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
    return Uint8Array.from(
      atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")),
      (c) => c.charCodeAt(0),
    );
  } catch {
    return fail();
  }
}
/** WebCrypto expects IEEE P1363; AdMob emits canonical ASN.1 DER. */
export function adMobDERToRaw(
  der: Uint8Array,
  width = 32,
): Uint8Array<ArrayBuffer> {
  if (
    der.length < 8 || der[0] !== 0x30 || der[1] !== der.length - 2 ||
    der[1] >= 128
  ) return fail();
  let offset = 2;
  const raw = new Uint8Array(width * 2);
  for (let coordinate = 0; coordinate < 2; coordinate++) {
    if (der[offset++] !== 2) return fail();
    const size = der[offset++];
    if (!size || size > width + 1 || offset + size > der.length) return fail();
    let value = der.slice(offset, offset + size);
    offset += size;
    if (value[0] & 0x80) return fail();
    if (value[0] === 0 && value.length > 1) {
      if (!(value[1] & 0x80)) return fail();
      value = value.slice(1);
    }
    if (value.length > width || value.every((b) => b === 0)) return fail();
    raw.set(value, (coordinate + 1) * width - value.length);
  }
  if (offset !== der.length) return fail();
  return raw;
}
export async function verifyAdMobCallback(
  url: string,
  fetcher: typeof fetch = fetch,
): Promise<VerifiedAdMobCallback> {
  let rawQuery: string;
  try {
    rawQuery = new URL(url).search.slice(1);
  } catch {
    return fail();
  }
  if (!rawQuery || rawQuery.length > 8192) return fail();
  const parts = rawQuery.split("&");
  if (
    parts.length < 9 || !parts.at(-2)?.startsWith("signature=") ||
    !parts.at(-1)?.startsWith("key_id=")
  ) return fail();
  const values = new Map<string, string>();
  for (const part of parts) {
    const equals = part.indexOf("=");
    if (equals < 1) return fail();
    const name = part.slice(0, equals);
    if (!/^[a-z_]+$/.test(name) || values.has(name)) return fail();
    let value: string;
    try {
      value = decodeURIComponent(part.slice(equals + 1));
    } catch {
      return fail();
    }
    // Our closed ASCII contract prevents ambiguity after the prescribed decode.
    if (/[&=\u0000-\u001f]/.test(value) && name !== "signature") return fail();
    values.set(name, value);
  }
  const required = (name: string) => {
    const value = values.get(name);
    if (!value) return fail();
    return value;
  };
  const keyID = required("key_id"), signature = required("signature");
  if (!/^\d{1,20}$/.test(keyID) || !/^[A-Za-z0-9_-]+={0,2}$/.test(signature)) {
    return fail();
  }
  let response: Response;
  try {
    response = await fetcher(KEYS_URL, {
      signal: AbortSignal.timeout(8000),
      redirect: "error",
    });
  } catch {
    throw new AdMobVerificationError("reward_keys_unavailable", 503);
  }
  if (!response.ok) {
    throw new AdMobVerificationError("reward_keys_unavailable", 503);
  }
  const text = await response.text();
  if (text.length > 65536) {
    throw new AdMobVerificationError("reward_keys_unavailable", 503);
  }
  let keys: any[];
  try {
    keys = JSON.parse(text).keys;
  } catch {
    throw new AdMobVerificationError("reward_keys_unavailable", 503);
  }
  if (!Array.isArray(keys)) {
    throw new AdMobVerificationError("reward_keys_unavailable", 503);
  }
  const matching = keys.filter((k) => String(k.keyId) === keyID);
  if (matching.length !== 1 || typeof matching[0].base64 !== "string") {
    return fail();
  }
  let verified = false;
  try {
    const key = await crypto.subtle.importKey(
      "spki",
      bytes(matching[0].base64),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
    const content = new TextEncoder().encode(
      decodeURIComponent(parts.slice(0, -2).join("&")),
    );
    verified = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      adMobDERToRaw(bytes(signature)),
      content,
    );
  } catch {
    return fail();
  }
  if (!verified) return fail();
  const transactionID = required("transaction_id"),
    customData = required("custom_data"),
    userID = required("user_id");
  const adUnit = required("ad_unit"), rewardItem = required("reward_item");
  const amount = required("reward_amount"),
    timestampText = required("timestamp");
  if (
    !/^[a-zA-Z0-9_-]{1,256}$/.test(transactionID) || customData.length > 256 ||
    userID.length > 128 || adUnit.length > 128 || rewardItem.length > 128 ||
    !/^\d+$/.test(amount) || !/^\d+$/.test(timestampText)
  ) return fail();
  const rewardAmount = Number(amount), timestamp = Number(timestampText);
  if (
    !Number.isSafeInteger(rewardAmount) || !Number.isSafeInteger(timestamp) ||
    timestamp <= 0
  ) return fail();
  return {
    transactionID,
    customData,
    userID,
    adUnit,
    rewardAmount,
    rewardItem,
    timestamp,
  };
}
