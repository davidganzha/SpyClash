import {execFileSync} from 'node:child_process';
import {mkdtempSync, writeFileSync, readFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomBytes, sign, constants, X509Certificate} from 'node:crypto';
import {gameCenterBundleID, parseAssertion} from '../../supabase/functions/game-center-session/backend/assertion.mjs';

export function createFixtureCertificates() {
  const dir = mkdtempSync(join(tmpdir(), 'spyclash-gc-main-'));
  const run = args => execFileSync('openssl', args, {cwd: dir, stdio: ['ignore', 'pipe', 'pipe']});
  run(['req','-x509','-newkey','rsa:2048','-nodes','-keyout','root.key','-out','root.pem','-days','2','-subj','/CN=GC Main Test Root/O=Test Only','-addext','basicConstraints=critical,CA:TRUE']);
  run(['req','-new','-newkey','rsa:2048','-nodes','-keyout','intermediate.key','-out','intermediate.csr','-subj','/CN=GC Main Test Intermediate/O=Test Only']);
  writeFileSync(join(dir,'intermediate.ext'),'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n');
  run(['x509','-req','-in','intermediate.csr','-CA','root.pem','-CAkey','root.key','-CAcreateserial','-out','intermediate.pem','-days','2','-extfile','intermediate.ext']);
  run(['req','-new','-newkey','rsa:2048','-nodes','-keyout','leaf.key','-out','leaf.csr','-subj','/CN=Apple Inc./O=Apple Inc.']);
  writeFileSync(join(dir,'leaf.ext'),'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n');
  run(['x509','-req','-in','leaf.csr','-CA','intermediate.pem','-CAkey','intermediate.key','-CAcreateserial','-out','leaf.pem','-days','2','-extfile','leaf.ext']);
  const trust = {rootPEM:readFileSync(join(dir,'root.pem'),'utf8'),intermediatePEM:readFileSync(join(dir,'intermediate.pem'),'utf8')};
  const key = readFileSync(join(dir,'leaf.key'),'utf8');
  const leaf = new X509Certificate(readFileSync(join(dir,'leaf.pem')));
  return {trust, leaf, cleanup:()=>rmSync(dir,{recursive:true,force:true}), assertion(overrides={}) {
    const body = {team_player_id:'T:_synthetic_'+randomBytes(8).toString('hex'),bundle_id:gameCenterBundleID,
      public_key_url:'https://static.gc.apple.com/public-key/gc-prod-99.cer',signature:Buffer.alloc(256).toString('base64'),
      salt:randomBytes(32).toString('base64'),timestamp:Date.now(),display_name:'Local test player',...overrides};
    const parsed = parseAssertion(body,body.timestamp);
    return {...body,signature:sign('RSA-SHA256',parsed.payload,{key,padding:constants.RSA_PKCS1_PADDING}).toString('base64')};
  }};
}
