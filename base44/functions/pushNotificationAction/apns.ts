import { importPKCS8, SignJWT } from "npm:jose@5.10.0";
import { clean, SPYCLASH_BUNDLE_ID } from "./contracts.ts";

export type APNsResult = {
  delivered: boolean;
  retryable: boolean;
  invalidateToken: boolean;
  reason: string;
};

let cachedJWT: { value: string; expiresAt: number; identity: string } | null =
  null;
export const APNS_MAX_PAYLOAD_BYTES = 4096;
const encoder = new TextEncoder();

/**
 * Push transport is the final boundary before an APNs payload leaves our
 * service. Keep notifications silent even if a future event builder (or a
 * retried stored payload) accidentally includes `aps.sound`.
 *
 * The JSON round-trip intentionally mirrors APNs serialization and guarantees
 * that the caller-owned payload is never mutated.
 */
export function withoutNotificationSound(
  payload: Record<string, unknown>,
): Record<string, unknown> {
  const sanitized = JSON.parse(JSON.stringify(payload ?? {})) as Record<
    string,
    unknown
  >;
  if (
    sanitized.aps && typeof sanitized.aps === "object" &&
    !Array.isArray(sanitized.aps)
  ) {
    delete (sanitized.aps as Record<string, unknown>).sound;
  }
  return sanitized;
}

export type SerializedAPNsPayload = {
  payload: Record<string, unknown>;
  json: string;
  byteLength: number;
};

function serialized(
  payload: Record<string, unknown>,
): SerializedAPNsPayload | null {
  try {
    const json = JSON.stringify(payload);
    return { payload, json, byteLength: encoder.encode(json).byteLength };
  } catch {
    return null;
  }
}

function truncateAlertField(
  payload: Record<string, unknown>,
  alert: Record<string, unknown>,
  field: "body" | "title",
): SerializedAPNsPayload | null {
  const original = Array.from(String(alert[field] ?? ""));
  let low = 0;
  let high = original.length;
  let best: SerializedAPNsPayload | null = null;
  let bestValue = "";
  while (low <= high) {
    const count = Math.floor((low + high) / 2);
    alert[field] = count === original.length
      ? original.join("")
      : count === 0
      ? ""
      : `${original.slice(0, count).join("")}…`;
    const candidate = serialized(payload);
    if (candidate && candidate.byteLength <= APNS_MAX_PAYLOAD_BYTES) {
      best = candidate;
      bestValue = String(alert[field]);
      low = count + 1;
    } else {
      high = count - 1;
    }
  }
  if (best) {
    alert[field] = bestValue;
    best = serialized(payload);
  } else {
    alert[field] = "";
  }
  return best;
}

/** Serialize the exact bytes sent to APNs, truncating only visible alert copy. */
export function serializeAlertPayload(
  value: Record<string, unknown>,
): SerializedAPNsPayload | null {
  const payload = withoutNotificationSound(value);
  let result = serialized(payload);
  if (!result || result.byteLength <= APNS_MAX_PAYLOAD_BYTES) return result;
  const aps = payload.aps;
  if (!aps || typeof aps !== "object" || Array.isArray(aps)) return null;
  const apsRecord = aps as Record<string, unknown>;
  if (typeof apsRecord.alert === "string") {
    apsRecord.alert = { body: apsRecord.alert };
  }
  const alert = apsRecord.alert;
  if (!alert || typeof alert !== "object" || Array.isArray(alert)) return null;
  const alertRecord = alert as Record<string, unknown>;
  for (const field of ["body", "title"] as const) {
    if (!(field in alertRecord)) continue;
    result = truncateAlertField(payload, alertRecord, field);
    if (result) return result;
  }
  return null;
}

export function serializeExactPayload(
  value: Record<string, unknown>,
): SerializedAPNsPayload | null {
  const result = serialized(withoutNotificationSound(value));
  return result && result.byteLength <= APNS_MAX_PAYLOAD_BYTES ? result : null;
}

async function providerJWT(now = new Date()): Promise<string> {
  const keyID = clean(Deno.env.get("APNS_KEY_ID"));
  const teamID = clean(Deno.env.get("APNS_TEAM_ID"));
  const privateKey = clean(Deno.env.get("APNS_PRIVATE_KEY")).replaceAll(
    "\\n",
    "\n",
  );
  if (!keyID || !teamID || !privateKey) {
    throw new Error("apns_not_configured");
  }
  const identity = `${teamID}:${keyID}`;
  if (
    cachedJWT && cachedJWT.identity === identity &&
    cachedJWT.expiresAt > now.getTime()
  ) {
    return cachedJWT.value;
  }
  const key = await importPKCS8(privateKey, "ES256");
  const issuedAt = Math.floor(now.getTime() / 1_000);
  const value = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyID })
    .setIssuer(teamID)
    .setIssuedAt(issuedAt)
    .sign(key);
  cachedJWT = {
    value,
    identity,
    expiresAt: now.getTime() + 45 * 60 * 1_000,
  };
  return value;
}

export async function sendAlertPush(input: {
  token: string;
  environment: "sandbox" | "production";
  bundleID: string;
  collapseID: string;
  expiration: number;
  payload: Record<string, unknown>;
  fetcher?: typeof fetch;
}): Promise<APNsResult> {
  if (
    input.bundleID !== (clean(Deno.env.get("APNS_TOPIC")) || SPYCLASH_BUNDLE_ID)
  ) {
    return {
      delivered: false,
      retryable: true,
      invalidateToken: false,
      reason: "topic_mismatch",
    };
  }
  const serializedPayload = serializeAlertPayload(input.payload);
  if (!serializedPayload) {
    return {
      delivered: false,
      retryable: false,
      invalidateToken: false,
      reason: "payload_too_large",
    };
  }
  let jwt: string;
  try {
    jwt = await providerJWT();
  } catch {
    return {
      delivered: false,
      retryable: true,
      invalidateToken: false,
      reason: "apns_not_configured",
    };
  }
  const host = input.environment === "production"
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com";
  let response: Response;
  try {
    response = await (input.fetcher || fetch)(
      `${host}/3/device/${input.token}`,
      {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": input.bundleID,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "apns-expiration": String(input.expiration),
          "apns-collapse-id": input.collapseID.slice(0, 64),
          "content-type": "application/json",
        },
        signal: AbortSignal.timeout(8_000),
        body: serializedPayload.json,
      },
    );
  } catch {
    return {
      delivered: false,
      retryable: true,
      invalidateToken: false,
      reason: "network_error",
    };
  }
  if (response.status === 200) {
    return {
      delivered: true,
      retryable: false,
      invalidateToken: false,
      reason: "ok",
    };
  }
  let reason = `http_${response.status}`;
  try {
    const body = await response.json();
    reason = clean(body?.reason) || reason;
  } catch {
    // HTTP status remains the sanitized diagnostic.
  }
  if (["ExpiredProviderToken", "InvalidProviderToken"].includes(reason)) {
    cachedJWT = null;
  }
  const invalidReasons = new Set([
    "BadDeviceToken",
    "DeviceTokenNotForTopic",
    "Unregistered",
  ]);
  return {
    delivered: false,
    // Provider credentials are server configuration, never a device-token
    // invalidation. Retry after clearing the cached JWT above.
    retryable: response.status === 429 || response.status >= 500 ||
      reason === "TooManyRequests" || reason === "InternalServerError" ||
      reason === "ServiceUnavailable" || reason === "ExpiredProviderToken" ||
      reason === "InvalidProviderToken",
    invalidateToken: response.status === 410 || invalidReasons.has(reason),
    reason: reason.slice(0, 80),
  };
}

export async function sendLiveActivityPush(input: {
  token: string;
  environment: "sandbox" | "production";
  bundleID: string;
  collapseID: string;
  expiration: number;
  payload: Record<string, unknown>;
  fetcher?: typeof fetch;
}): Promise<APNsResult> {
  if (
    input.bundleID !== (clean(Deno.env.get("APNS_TOPIC")) || SPYCLASH_BUNDLE_ID)
  ) {
    return {
      delivered: false,
      retryable: true,
      invalidateToken: false,
      reason: "topic_mismatch",
    };
  }
  const serializedPayload = serializeExactPayload(input.payload);
  if (!serializedPayload) {
    return {
      delivered: false,
      retryable: false,
      invalidateToken: false,
      reason: "payload_too_large",
    };
  }
  let jwt: string;
  try {
    jwt = await providerJWT();
  } catch {
    return {
      delivered: false,
      retryable: true,
      invalidateToken: false,
      reason: "apns_not_configured",
    };
  }
  const host = input.environment === "production"
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com";
  try {
    const response = await (input.fetcher || fetch)(
      `${host}/3/device/${input.token}`,
      {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": `${input.bundleID}.push-type.liveactivity`,
          "apns-push-type": "liveactivity",
          "apns-priority": "10",
          "apns-expiration": String(input.expiration),
          "apns-collapse-id": input.collapseID.slice(0, 64),
          "content-type": "application/json",
        },
        signal: AbortSignal.timeout(8_000),
        body: serializedPayload.json,
      },
    );
    if (response.status === 200) {
      return {
        delivered: true,
        retryable: false,
        invalidateToken: false,
        reason: "ok",
      };
    }
    let reason = `http_${response.status}`;
    try {
      const body = await response.json();
      reason = clean(body?.reason) || reason;
    } catch {
      // Keep the status-only diagnostic.
    }
    if (["ExpiredProviderToken", "InvalidProviderToken"].includes(reason)) {
      cachedJWT = null;
    }
    const invalid = response.status === 410 || [
      "BadDeviceToken",
      "DeviceTokenNotForTopic",
      "Unregistered",
    ].includes(reason);
    return {
      delivered: false,
      retryable: response.status === 429 || response.status >= 500 ||
        reason === "ExpiredProviderToken" || reason === "InvalidProviderToken",
      invalidateToken: invalid,
      reason: reason.slice(0, 80),
    };
  } catch {
    return {
      delivered: false,
      retryable: true,
      invalidateToken: false,
      reason: "network_error",
    };
  }
}
