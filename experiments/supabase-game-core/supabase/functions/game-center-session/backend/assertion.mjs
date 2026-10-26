import { Buffer } from 'node:buffer';
import 'reflect-metadata';
import { X509Certificate as ParsedCertificate, KeyUsageFlags } from '@peculiar/x509';
import { createHash } from 'node:crypto';
import { rootPEM, intermediatePEM } from './trusted-certificates.mjs';

export const gameCenterBundleID = 'com.spyclash.ios';
export class GameCenterError extends Error {
  constructor(code, message, status = 401, retryable = false) {
    super(message); this.code = code; this.status = status; this.retryable = retryable;
  }
}
const invalid = () => new GameCenterError('invalid_game_center_assertion', 'Game Center could not be verified. Use another sign-in method.');
export const unavailable = () => new GameCenterError('game_center_unavailable', 'Game Center sign-in is temporarily unavailable.', 503, true);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const allowedFields = new Set(['team_player_id', 'bundle_id', 'public_key_url', 'signature', 'salt', 'timestamp', 'display_name']);

export function validateCertificateURL(value) {
  if (typeof value !== 'string' || value.length > 256) throw invalid();
  let url;
  try { url = new URL(value); } catch { throw invalid(); }
  if (url.protocol !== 'https:' || url.hostname !== 'static.gc.apple.com' || url.port || url.username || url.password ||
      url.search || url.hash || !/^\/public-key\/gc-(prod|sb)-[0-9]+\.cer$/.test(url.pathname)) throw invalid();
  // Require a canonical URL: no escapes, path normalization, or implicit credentials.
  if (url.href !== value) throw invalid();
  return url;
}
function base64(value, min, max) {
  if (typeof value !== 'string' || value.length > Math.ceil(max / 3) * 4 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) throw invalid();
  const bytes = Buffer.from(value, 'base64');
  if (bytes.length < min || bytes.length > max || bytes.toString('base64') !== value) throw invalid();
  return bytes;
}
export function parseAssertion(body, now = Date.now()) {
  if (!body || typeof body !== 'object' || Array.isArray(body) || Object.keys(body).some(key => !allowedFields.has(key))) throw invalid();
  if (typeof body.team_player_id !== 'string' || !body.team_player_id || Buffer.byteLength(body.team_player_id, 'utf8') > 512 || /[\p{Cc}\p{Cf}]/u.test(body.team_player_id) || body.bundle_id !== gameCenterBundleID) throw invalid();
  if (!Number.isSafeInteger(body.timestamp) || body.timestamp <= 0 || now - body.timestamp > 300_000 || body.timestamp - now > 30_000) throw invalid();
  if (body.display_name !== undefined && (typeof body.display_name !== 'string' || body.display_name.length > 100)) throw invalid();
  const certificateURL = validateCertificateURL(body.public_key_url);
  const signature = base64(body.signature, 256, 1024);
  const salt = base64(body.salt, 1, 256);
  const timestamp = Buffer.alloc(8); timestamp.writeBigUInt64BE(BigInt(body.timestamp));
  const payload = Buffer.concat([Buffer.from(body.team_player_id, 'utf8'), Buffer.from(body.bundle_id, 'utf8'), timestamp, salt]);
  // Nicknames are unsigned and cosmetic only. Never match identities by nickname/email.
  const displayName = (body.display_name || 'Operative').replace(/[\p{Cc}\p{Cf}]/gu, '').trim().slice(0, 80) || 'Operative';
  return { certificateURL, signature, payload, displayName, timestamp: body.timestamp,
    identityKey: hash(Buffer.from('spyclash-game-center-v1\n' + body.bundle_id + '\n' + body.team_player_id)),
    replayKey: hash(Buffer.concat([payload, signature])) };
}
function validAt(cert, time) {
  return Number.isFinite(cert.notBefore.getTime()) && cert.notBefore.getTime() <= time && time <= cert.notAfter.getTime();
}
/** Verify the current Apple leaf against the pinned CA using WebCrypto, which
 * also works in the deployed Edge runtime (its Node X509 API is incomplete).
 * Test-only trust fixtures are passed explicitly by tests. */
export async function validateCertificateChain(bytes, now = Date.now(), trust = {rootPEM, intermediatePEM}) {
  let leaf, intermediate, root;
  try { leaf = new ParsedCertificate(bytes); intermediate = new ParsedCertificate(trust.intermediatePEM); root = new ParsedCertificate(trust.rootPEM); } catch { throw invalid(); }
  if (!validAt(leaf, now) || !validAt(intermediate, now) || !validAt(root, now) ||
      leaf.getExtension('2.5.29.19')?.ca !== false || intermediate.getExtension('2.5.29.19')?.ca !== true || root.getExtension('2.5.29.19')?.ca !== true ||
      leaf.issuer !== intermediate.subject || intermediate.issuer !== root.subject || root.issuer !== root.subject ||
      !leaf.subjectName.getField('O').includes('Apple Inc.') || !leaf.subjectName.getField('CN').includes('Apple Inc.') ||
      !leaf.getExtension('2.5.29.37')?.usages?.includes('1.3.6.1.5.5.7.3.3') ||
      !(leaf.getExtension('2.5.29.15')?.usages & KeyUsageFlags.digitalSignature) ||
      leaf.publicKey.algorithm.name !== 'RSASSA-PKCS1-v1_5' || (leaf.publicKey.algorithm.modulusLength ?? 0) < 2048) throw invalid();
  const date = new Date(now);
  if (!await leaf.verify({publicKey: intermediate.publicKey, date}, globalThis.crypto) ||
      !await intermediate.verify({publicKey: root.publicKey, date}, globalThis.crypto) ||
      !await root.verify({publicKey: root.publicKey, date}, globalThis.crypto)) throw invalid();
  return leaf;
}
async function boundedBytes(response, limit) {
  if (Number(response.headers.get('content-length')) > limit) throw invalid();
  if (!response.body) throw invalid();
  const reader = response.body.getReader(); const chunks = []; let total = 0;
  try {
    while (true) {
      const {value, done} = await reader.read(); if (done) break;
      total += value.byteLength; if (total > limit) throw invalid(); chunks.push(value);
    }
  } finally { await reader.cancel().catch(() => {}); }
  return Buffer.concat(chunks);
}
export async function readJSON(request, limit = 8192) {
  if (!request.headers.get('content-type')?.toLowerCase().startsWith('application/json')) throw new GameCenterError('invalid_request', 'JSON required.', 415);
  let bytes;
  try { bytes = await boundedBytes(request, limit); }
  catch { throw new GameCenterError('invalid_request', 'Request body is too large.', 413); }
  try { return JSON.parse(bytes.toString('utf8')); } catch { throw new GameCenterError('invalid_request', 'Invalid JSON.', 400); }
}
/** The cache honors a bounded HTTP max-age and certificate expiry. URLs are
 * checked before cache lookup; redirects never run, even to another Apple host. */
export function createCertificateLoader({fetcher = fetch, now = Date.now, trust} = {}) {
  const cache = new Map();
  return async url => {
    validateCertificateURL(String(url));
    const key = String(url), current = now();
    const cached = cache.get(key);
    if (cached && current < cached.until) return validateCertificateChain(cached.bytes, current, trust);
    let response;
    try { response = await fetcher(key, {redirect: 'error', signal: AbortSignal.timeout(5000), headers: {Accept: 'application/pkix-cert'}}); }
    catch { throw unavailable(); }
    if (!response.ok) throw unavailable();
    const bytes = await boundedBytes(response, 16_384);
    const cert = await validateCertificateChain(bytes, current, trust);
    const control = response.headers.get('cache-control') || '';
    const maxAge = /(?:^|,)\s*max-age=(\d+)(?:,|$)/i.exec(control)?.[1];
    const age = Number(response.headers.get('age') || '0');
    const ttl = /no-store|no-cache/i.test(control) ? 0 : Math.max(0, Math.min(3600, Number(maxAge || 0) - (Number.isFinite(age) ? age : 0))) * 1000;
    if (ttl > 0) {
      if (cache.size >= 16) cache.delete(cache.keys().next().value);
      cache.set(key, {bytes, until: Math.min(current + ttl, cert.notAfter.getTime())});
    }
    return cert;
  };
}
export function createAssertionVerifier({loadCertificate = createCertificateLoader(), now = Date.now} = {}) {
  return async body => {
    const parsed = parseAssertion(body, now());
    let certificate;
    try { certificate = await loadCertificate(parsed.certificateURL); }
    catch (error) { console.error('game_center_verification_error', 'certificate', error?.name || 'Error'); throw error; }
    let valid;
    try {
      const key = await certificate.publicKey.export({name:'RSASSA-PKCS1-v1_5',hash:'SHA-256'},['verify'],globalThis.crypto);
      valid = await globalThis.crypto.subtle.verify('RSASSA-PKCS1-v1_5',key,parsed.signature,parsed.payload);
    }
    catch (error) { console.error('game_center_verification_error', 'signature', error?.name || 'Error'); throw unavailable(); }
    if (!valid) throw invalid();
    // Downloading a certificate must not extend the assertion freshness window.
    parseAssertion(body, now());
    return parsed;
  };
}
