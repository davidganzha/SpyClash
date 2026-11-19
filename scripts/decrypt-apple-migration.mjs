#!/usr/bin/env node
// Offline recipient for the temporary, administrator-authorized encrypted export.
// Never prints configuration values or accepts a caller-selected output location.
import {createDecipheriv, createPrivateKey, privateDecrypt, randomBytes, constants} from 'node:crypto';
import {readFileSync, writeFileSync, mkdirSync, lstatSync, chmodSync, existsSync} from 'node:fs';
import {homedir} from 'node:os';
import {join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

const context = 'spyclash-apple-supabase-247:69a0e57fa939f578082f8091';
const names = ['SPYCLASH_PSEUDONYM_KEY','APPLE_KEY_ID','APPLE_TEAM_ID','APPLE_PRIVATE_KEY_P8_B64'];
const bytes = (value, max) => {
  if (typeof value !== 'string' || value.length > max * 2 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) throw Error('Invalid encrypted envelope');
  const result = Buffer.from(value,'base64');
  if (!result.length || result.length > max || result.toString('base64') !== value) throw Error('Invalid encrypted envelope');
  return result;
};

export function decryptMigrationEnvelope(envelope, privateKey, now = Date.now()) {
  if (envelope?.version !== 1 || envelope.context !== context || envelope.algorithm !== 'RSA-OAEP-256+A256GCM') throw Error('Wrong migration envelope');
  const iv = bytes(envelope.iv,12);
  const ciphertext = bytes(envelope.ciphertext,100000);
  if (iv.length !== 12 || ciphertext.length < 17) throw Error('Invalid encrypted envelope');
  const key = privateDecrypt({key:privateKey,oaepHash:'sha256',padding:constants.RSA_PKCS1_OAEP_PADDING},bytes(envelope.wrapped_key,1024));
  let plaintext;
  try {
    if (key.length !== 32) throw Error('Invalid encryption key');
    const cipher = createDecipheriv('aes-256-gcm',key,iv);
    cipher.setAAD(Buffer.from(context));
    cipher.setAuthTag(ciphertext.subarray(-16));
    plaintext = Buffer.concat([cipher.update(ciphertext.subarray(0,-16)),cipher.final()]);
    const result = JSON.parse(plaintext.toString('utf8'));
    const issued = Date.parse(result.issued_at);
    if (result.version !== 1 || result.app_id !== '69a0e57fa939f578082f8091' || !Number.isFinite(issued) || issued > now + 300000 || issued < now - 86400000) throw Error('Wrong or stale export');
    const secrets = result.secrets;
    if (!secrets || Object.keys(secrets).sort().join(',') !== [...names].sort().join(',')) throw Error('Unexpected configuration fields');
    for (const name of names) {
      if (typeof secrets[name] !== 'string' || !secrets[name].trim() || secrets[name].length > 16000 || secrets[name].includes('********')) throw Error('Missing source configuration');
    }
    if (secrets.APPLE_TEAM_ID.trim() !== '3Z64QKNL54' || !/^[A-Z0-9]{10}$/.test(secrets.APPLE_KEY_ID.trim())) throw Error('Wrong Apple configuration');
    const appleKey = createPrivateKey(Buffer.from(secrets.APPLE_PRIVATE_KEY_P8_B64.trim(),'base64'));
    if (appleKey.asymmetricKeyType !== 'ec' || appleKey.asymmetricKeyDetails?.namedCurve !== 'prime256v1') throw Error('Wrong Apple key type');
    return secrets;
  } finally { key.fill(0); plaintext?.fill(0); }
}

export function savePrivateConfiguration(secrets, directory) {
  mkdirSync(directory,{recursive:true,mode:0o700});
  const directoryStat = lstatSync(directory);
  if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink()) throw Error('Unsafe output directory');
  chmodSync(directory,0o700);
  const target = join(directory,'supabase-apple-configuration.json');
  if (existsSync(target)) {
    const info = lstatSync(target);
    if (!info.isFile() || info.isSymbolicLink() || (info.mode & 0o077)) throw Error('Unsafe existing configuration');
    const previous = JSON.parse(readFileSync(target,'utf8'));
    if (!names.every(name => previous[name] === secrets[name]) || !/^[a-f0-9]{64}$/.test(previous.APPLE_GRANT_ENCRYPTION_KEY ?? '')) throw Error('Existing configuration differs; preserve encryption key');
    return {created:false,field_count:Object.keys(previous).length};
  }
  const configuration = {...secrets,APPLE_GRANT_ENCRYPTION_KEY:randomBytes(32).toString('hex')};
  writeFileSync(target,JSON.stringify(configuration,null,2)+'\n',{flag:'wx',mode:0o600});
  return {created:true,field_count:Object.keys(configuration).length};
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    if (process.argv.length !== 3) throw Error('Expected one encrypted-envelope JSON file');
    const directory = join(homedir(),'.local/share/SpyClashSigning/apple-supabase-247');
    const keyPath = join(directory,'migration-recipient.pem');
    const keyStat = lstatSync(keyPath);
    if (!keyStat.isFile() || keyStat.isSymbolicLink() || (keyStat.mode & 0o077)) throw Error('Unsafe private recipient key');
    const envelope = JSON.parse(readFileSync(process.argv[2],'utf8'));
    const secrets = decryptMigrationEnvelope(envelope,readFileSync(keyPath));
    console.log(JSON.stringify({ok:true,...savePrivateConfiguration(secrets,directory),values_displayed:false}));
  } catch {
    console.error('Migration envelope could not be safely decrypted and saved; no configuration values displayed.');
    process.exitCode = 1;
  }
}
