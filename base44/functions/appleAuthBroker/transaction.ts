export const UPSTREAM_TRANSACTION_COOKIE = "__Host-SpyClashOAuthTransaction";
export const UPSTREAM_FALLBACK_TRANSACTION_COOKIE =
  "__Secure-SpyClashOAuthTransactionFallback";

export type TransactionSameSite = "Lax" | "None";

const MAX_TRANSACTION_COOKIE_AGE_SECONDS = 300;
const FALLBACK_TRANSACTION_COOKIE_PATH = "/functions/";
const TRANSACTION_SECRET_BYTES = 32;
const TRANSACTION_VALUE_PATTERN = /^[A-Za-z0-9_-]{43}$/;

export function randomBase64Url(bytes = TRANSACTION_SECRET_BYTES) {
  const value = crypto.getRandomValues(new Uint8Array(bytes));
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(
    /=+$/,
    "",
  );
}

export async function sha256Base64Url(value: string) {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
  );
  let binary = "";
  for (const byte of digest) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(
    /=+$/,
    "",
  );
}

export async function secureEqual(left: string, right: string) {
  const encoder = new TextEncoder();
  const [leftHash, rightHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(left)),
    crypto.subtle.digest("SHA-256", encoder.encode(right)),
  ]);
  const a = new Uint8Array(leftHash);
  const b = new Uint8Array(rightHash);
  let difference = 0;
  for (let index = 0; index < a.length; index += 1) {
    difference |= a[index] ^ b[index];
  }
  return difference === 0;
}

export function cookieValue(cookieHeader: string | null, name: string) {
  for (const part of (cookieHeader || "").split(";")) {
    const index = part.indexOf("=");
    if (index < 0) continue;
    if (part.slice(0, index).trim() === name) {
      return part.slice(index + 1).trim();
    }
  }
  return null;
}

export async function createUpstreamTransaction() {
  const secret = randomBase64Url();
  return { secret, secretHash: await sha256Base64Url(secret) };
}

export function upstreamTransactionCookie(
  secret: string,
  stateTtlSeconds: number,
  sameSite: TransactionSameSite = "None",
) {
  if (!TRANSACTION_VALUE_PATTERN.test(secret)) {
    throw new Error("invalid transaction secret");
  }
  if (!Number.isFinite(stateTtlSeconds) || stateTtlSeconds <= 0) {
    throw new Error("invalid transaction TTL");
  }
  const maxAge = Math.min(
    Math.floor(stateTtlSeconds),
    MAX_TRANSACTION_COOKIE_AGE_SECONDS,
  );
  return `${UPSTREAM_TRANSACTION_COOKIE}=${secret}; Max-Age=${maxAge}; Path=/; HttpOnly; Secure; SameSite=${sameSite}`;
}

export function upstreamFallbackTransactionCookie(
  secret: string,
  stateTtlSeconds: number,
) {
  if (!TRANSACTION_VALUE_PATTERN.test(secret)) {
    throw new Error("invalid transaction secret");
  }
  if (!Number.isFinite(stateTtlSeconds) || stateTtlSeconds <= 0) {
    throw new Error("invalid transaction TTL");
  }
  const maxAge = Math.min(
    Math.floor(stateTtlSeconds),
    MAX_TRANSACTION_COOKIE_AGE_SECONDS,
  );
  return `${UPSTREAM_FALLBACK_TRANSACTION_COOKIE}=${secret}; Max-Age=${maxAge}; Path=${FALLBACK_TRANSACTION_COOKIE_PATH}; Secure; SameSite=None`;
}

export function clearUpstreamTransactionCookie(
  sameSite: TransactionSameSite = "None",
) {
  return `${UPSTREAM_TRANSACTION_COOKIE}=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=${sameSite}`;
}

export function clearUpstreamFallbackTransactionCookie() {
  return `${UPSTREAM_FALLBACK_TRANSACTION_COOKIE}=; Max-Age=0; Path=${FALLBACK_TRANSACTION_COOKIE_PATH}; Secure; SameSite=None`;
}

export async function upstreamTransactionMatches(
  cookieHeader: string | null,
  expectedSecretHash: string,
) {
  if (!TRANSACTION_VALUE_PATTERN.test(expectedSecretHash)) return false;
  const secret = cookieValue(cookieHeader, UPSTREAM_TRANSACTION_COOKIE);
  if (!secret || !TRANSACTION_VALUE_PATTERN.test(secret)) return false;
  const actualSecretHash = await sha256Base64Url(secret);
  return secureEqual(actualSecretHash, expectedSecretHash);
}

export async function upstreamFallbackTransactionMatches(
  cookieHeader: string | null,
  expectedSecretHash: string,
) {
  if (!TRANSACTION_VALUE_PATTERN.test(expectedSecretHash)) return false;
  const secret = cookieValue(
    cookieHeader,
    UPSTREAM_FALLBACK_TRANSACTION_COOKIE,
  );
  if (!secret || !TRANSACTION_VALUE_PATTERN.test(secret)) return false;
  const actualSecretHash = await sha256Base64Url(secret);
  return secureEqual(actualSecretHash, expectedSecretHash);
}
