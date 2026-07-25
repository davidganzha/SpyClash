import { clean, PushContractError } from "./contracts.ts";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function hex(bytes: ArrayBuffer | Uint8Array): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  return [...view].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function bytesToBase64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(
    /=+$/g,
    "",
  );
}

function base64URLToBytes(value: string): Uint8Array {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  const padding = "=".repeat((4 - normalized.length % 4) % 4);
  const binary = atob(normalized + padding);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function ownedBuffer(bytes: Uint8Array): ArrayBuffer {
  return Uint8Array.from(bytes).buffer;
}

function keyBytes(value: string): Uint8Array {
  const secret = clean(value);
  if (/^[0-9a-fA-F]{64}$/.test(secret)) {
    return Uint8Array.from(
      secret.match(/.{2}/g) || [],
      (pair) => parseInt(pair, 16),
    );
  }
  try {
    const decoded = base64URLToBytes(secret);
    if (decoded.length === 32) return decoded;
  } catch {
    // Fall through to the fail-closed error below.
  }
  throw new PushContractError(
    "Push token encryption is unavailable.",
    503,
    "push_encryption_unavailable",
  );
}

export async function importTokenEncryptionKey(
  secret: string,
): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "raw",
    ownedBuffer(keyBytes(secret)),
    "AES-GCM",
    false,
    ["encrypt", "decrypt"],
  );
}

async function configuredKey(): Promise<CryptoKey> {
  return await importTokenEncryptionKey(
    Deno.env.get("PUSH_TOKEN_ENCRYPTION_KEY") || "",
  );
}

export async function digest(
  value: string,
  namespace: string,
): Promise<string> {
  const hash = await crypto.subtle.digest(
    "SHA-256",
    encoder.encode(`spyclash:${namespace}:${value}`),
  );
  return hex(hash);
}

export async function encryptPushToken(
  token: string,
  binding: string,
  key?: CryptoKey,
): Promise<{ ciphertext: string; iv: string }> {
  const encryptionKey = key || await configuredKey();
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: encoder.encode(binding) },
    encryptionKey,
    encoder.encode(token),
  );
  return {
    ciphertext: bytesToBase64URL(new Uint8Array(encrypted)),
    iv: bytesToBase64URL(iv),
  };
}

export async function decryptPushToken(
  ciphertext: string,
  iv: string,
  binding: string,
  key?: CryptoKey,
): Promise<string> {
  const encryptionKey = key || await configuredKey();
  try {
    const decrypted = await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv: ownedBuffer(base64URLToBytes(iv)),
        additionalData: encoder.encode(binding),
      },
      encryptionKey,
      ownedBuffer(base64URLToBytes(ciphertext)),
    );
    return decoder.decode(decrypted);
  } catch {
    throw new PushContractError(
      "Stored push credentials could not be decrypted.",
      503,
      "push_credential_unavailable",
    );
  }
}

export function tokenBinding(record: {
  user_id?: unknown;
  token_hash?: unknown;
  token_kind?: unknown;
}): string {
  return [
    "spyclash-push-token-v1",
    clean(record.user_id),
    clean(record.token_kind) || "alert",
    clean(record.token_hash),
  ].join(":");
}
