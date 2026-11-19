export class AppleSessionError extends Error {
  constructor(public code: string, public status = 401, public retryable = false) {
    super(code);
  }
}
export const unavailable = () => new AppleSessionError('apple_session_unavailable', 503, true);
export const mismatch = () => new AppleSessionError('apple_identity_mismatch', 409);
export const uuid = (value: unknown): value is string => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
export const clientID = 'com.spyclash.ios';
export const issuer = 'https://appleid.apple.com';
export type AppleRequest = {identity_token: string; authorization_code: string; raw_nonce: string; request_id: string; given_name?: string; family_name?: string};
export type Assertion = {subjectKey: string; identityKey: string; subject: string; nonceHash: string; codeHash: string; requestID: string; displayName: string};
export type AppleConfig = {
  origin: string; databaseURL: string; local: boolean; anonKey: string; serviceRoleKey: string;
  pseudonymKey: string; encryptionKey: string; teamID: string; keyID: string; privateKeyPEM: string;
  newAccountsEnabled: boolean; migrationCoverageVerified: boolean;
};
export function parseRequest(value: unknown): AppleRequest {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new AppleSessionError('invalid_request', 400);
  const body = value as Record<string, unknown>;
  const allowed = ['identity_token', 'authorization_code', 'raw_nonce', 'request_id', 'given_name', 'family_name'];
  if (Object.keys(body).some(key => !allowed.includes(key)) || !uuid(body.request_id)) throw new AppleSessionError('invalid_request', 400);
  for (const [key, min, max] of [['identity_token', 20, 20_000], ['authorization_code', 1, 4096], ['raw_nonce', 32, 512]] as const) {
    if (typeof body[key] !== 'string' || body[key].length < min || body[key].length > max || /[\u0000-\u0020\u007f]/.test(body[key])) throw new AppleSessionError('invalid_request', 400);
  }
  for (const key of ['given_name', 'family_name']) if (body[key] !== undefined && (typeof body[key] !== 'string' || body[key].length > 120)) throw new AppleSessionError('invalid_request', 400);
  return body as AppleRequest;
}
export async function boundedText(response: Response | Request, maximum: number, tooLarge:AppleSessionError=unavailable()) {
  if (Number(response.headers.get('content-length')) > maximum) throw tooLarge;
  const reader = response.body?.getReader();
  if (!reader) return '';
  const chunks: Uint8Array[] = []; let size = 0;
  try {
    while (true) {
      const {done, value} = await reader.read(); if (done) break;
      size += value.length;
      if (size > maximum) throw tooLarge;
      chunks.push(value);
    }
  } finally { await reader.cancel().catch(() => {}); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return new TextDecoder('utf-8', {fatal: true}).decode(bytes);
}
