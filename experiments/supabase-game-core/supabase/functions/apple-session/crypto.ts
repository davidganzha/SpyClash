import {unavailable, issuer} from './contracts.ts';
const encoder = new TextEncoder();
const bytes = (value: Uint8Array) => new Uint8Array(value).buffer;
const hex = (value: ArrayBuffer) => [...new Uint8Array(value)].map(b => b.toString(16).padStart(2, '0')).join('');
const b64 = (value: Uint8Array) => btoa(String.fromCharCode(...value)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
const unb64 = (value: string) => Uint8Array.from(atob(value.replaceAll('-', '+').replaceAll('_', '/')), c => c.charCodeAt(0));
export const digest = async (value: string) => hex(await crypto.subtle.digest('SHA-256', encoder.encode(value)));
export function same(left: string, right: string) {
  const a = encoder.encode(left), b = encoder.encode(right); let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a[i] || 0) ^ (b[i] || 0);
  return diff === 0;
}
// This byte-for-byte legacy namespace permits migration without retaining raw sub.
export async function subjectIdentity(subject: string, secret: string) {
  // Historical requireValue trims the Apple subject before pseudonymization.
  // ID-token comparison itself still compares the two signed subjects exactly.
  subject=subject.trim();
  if (!subject || subject.length>512) throw unavailable();
  if (encoder.encode(secret.trim()).length < 32) throw unavailable();
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret.trim()), {name: 'HMAC', hash: 'SHA-256'}, false, ['sign']);
  const subjectKey = 'apple-subject:' + hex(await crypto.subtle.sign('HMAC', key, encoder.encode('spyclash-apple-refresh-token-v1:subject:' + subject)));
  return {subjectKey, identityKey: await digest(issuer + '\n' + subjectKey)};
}
export const grantVersion = 'apple-session-grant-v1';
export const grantBinding = (id: string, userID: string, clientID: string) => [grantVersion, id, userID, clientID].join(':');
async function encryptionKey(secret: string) {
  let material: Uint8Array;
  try { material = /^[0-9a-f]{64}$/i.test(secret) ? Uint8Array.from(secret.match(/../g)!, pair => parseInt(pair,16)) : unb64(secret); } catch { throw unavailable(); }
  if (material.length !== 32) throw unavailable();
  const master = await crypto.subtle.importKey('raw', bytes(material), 'HKDF', false, ['deriveKey']);
  return await crypto.subtle.deriveKey({name:'HKDF', hash:'SHA-256', salt:encoder.encode(grantVersion), info:encoder.encode('apple-refresh-token-encryption')}, master, {name:'AES-GCM',length:256}, false, ['encrypt','decrypt']);
}
export async function encryptGrant(token: string, binding: string, secret: string) {
  if (!token || token.length > 20_000) throw unavailable();
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:encoder.encode(binding)}, await encryptionKey(secret), encoder.encode(token));
  return {ciphertext:b64(new Uint8Array(ciphertext)),iv:b64(iv),encryption_version:grantVersion,binding};
}
export async function decryptGrant(grant: {ciphertext:string;iv:string;encryption_version:string;binding:string;id:string;user_id:string;client_id:string}, secret: string) {
  if (grant.encryption_version !== grantVersion || grant.binding !== grantBinding(grant.id,grant.user_id,grant.client_id) || grant.ciphertext.length > 40_000) throw unavailable();
  try {
    const plaintext = await crypto.subtle.decrypt({name:'AES-GCM',iv:bytes(unb64(grant.iv)),additionalData:encoder.encode(grant.binding)}, await encryptionKey(secret), bytes(unb64(grant.ciphertext)));
    return new TextDecoder('utf-8',{fatal:true}).decode(plaintext);
  } catch { throw unavailable(); }
}
