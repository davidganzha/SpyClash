import { AppServiceError } from './contracts.ts';

export function canonical(value: unknown): string {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value && typeof value === 'object') return '{' + Object.keys(value).sort().map(k => JSON.stringify(k)+':'+canonical((value as Record<string,unknown>)[k])).join(',') + '}';
  return JSON.stringify(value);
}
export async function digest(value: string): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)))].map(v => v.toString(16).padStart(2,'0')).join('');
}
const encode = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));
const decode = (value: string) => Uint8Array.from(atob(value), c => c.charCodeAt(0));
async function encryptionKey(secret: string | undefined) {
  if (!secret || !/^[a-f0-9]{64}$/i.test(secret)) throw new AppServiceError('push_encryption_unconfigured','Push token encryption is not configured.',503);
  const bytes = Uint8Array.from(secret.match(/.{2}/g)!, h => parseInt(h,16));
  return crypto.subtle.importKey('raw',bytes,'AES-GCM',false,['encrypt','decrypt']);
}
export async function encryptToken(token: string, secret: string | undefined, binding: string) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const bytes = new TextEncoder();
  const encrypted = await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:bytes.encode(binding)},await encryptionKey(secret),bytes.encode(token));
  return {v:1,iv:encode(iv),ciphertext:encode(new Uint8Array(encrypted))};
}
export async function decryptToken(value: {v:number,iv:string,ciphertext:string}, secret: string | undefined, binding: string) {
  if (value.v !== 1) throw new AppServiceError('invalid_push_ciphertext','Push token unavailable.',503);
  const bytes = await crypto.subtle.decrypt({name:'AES-GCM',iv:decode(value.iv),additionalData:new TextEncoder().encode(binding)},await encryptionKey(secret),decode(value.ciphertext));
  return new TextDecoder().decode(bytes);
}
