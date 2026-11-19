const SECRET_NAMES = Object.freeze(['SPYCLASH_PSEUDONYM_KEY', 'APPLE_KEY_ID', 'APPLE_TEAM_ID', 'APPLE_PRIVATE_KEY_P8_B64']);
const encoder = new TextEncoder();
const base64 = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes)));
const decode = value => Uint8Array.from(atob(value), c => c.charCodeAt(0));

export function canonicalAdministratorRequest(request) {
  // The SDK otherwise accepts app/API/service-role routing from HTTP headers.
  // Only the caller's bearer survives; authentication always targets this app.
  const headers = new Headers({
    'Base44-App-Id':'69a0e57fa939f578082f8091',
    'Base44-Api-Url':'https://base44.app',
  });
  const bearer=request.headers.get('authorization');
  if (bearer) headers.set('Authorization',bearer);
  return new Request('https://base44.app/api/apps/69a0e57fa939f578082f8091/functions/exportAppleSupabaseMigration247',{method:'POST',headers});
}

/** Temporary, administrator-only export to one reviewed recipient. No HTTP
 * parameter can select a secret, destination, public key, or user identity. */
export function createMigrationExportHandler({authenticate, readSecret, recipientSPKI, expiresAt, now = Date.now}) {
  return async request => {
    const headers = {'Content-Type':'application/json', 'Cache-Control':'no-store'};
    const fail = (status, code) => Response.json({code}, {status, headers});
    if (request.method !== 'POST') return fail(405, 'method_not_allowed');
    if (!Number.isFinite(expiresAt) || now() >= expiresAt) return fail(410, 'migration_export_expired');
    let user;
    try { user = await authenticate(canonicalAdministratorRequest(request)); } catch { return fail(401, 'authentication_required'); }
    if (!user?.id || user.role !== 'admin') return fail(403, 'administrator_required');
    let body;
    try {
      const raw = await request.text();
      if (raw.length > 128) return fail(400, 'invalid_request');
      body = JSON.parse(raw);
    } catch { return fail(400, 'invalid_request'); }
    if (!body || Array.isArray(body) || Object.keys(body).length !== 1 || body.action !== 'export') return fail(400, 'invalid_request');
    try {
      const secrets = {};
      for (const name of SECRET_NAMES) {
        const value = readSecret(name);
        if (typeof value !== 'string' || !value || value.length > 16000 || value.includes('********')) return fail(503, 'source_configuration_unavailable');
        secrets[name] = value;
      }
      const recipient = await crypto.subtle.importKey('spki', decode(recipientSPKI), {name:'RSA-OAEP', hash:'SHA-256'}, false, ['encrypt']);
      const aes = await crypto.subtle.generateKey({name:'AES-GCM', length:256}, true, ['encrypt']);
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const context = 'spyclash-apple-supabase-247:69a0e57fa939f578082f8091';
      const plaintext = encoder.encode(JSON.stringify({version:1, app_id:'69a0e57fa939f578082f8091', issued_at:new Date(now()).toISOString(), secrets}));
      const ciphertext = await crypto.subtle.encrypt({name:'AES-GCM', iv, additionalData:encoder.encode(context)}, aes, plaintext);
      plaintext.fill(0);
      const rawKey = new Uint8Array(await crypto.subtle.exportKey('raw', aes));
      const wrappedKey = await crypto.subtle.encrypt({name:'RSA-OAEP'}, recipient, rawKey);
      rawKey.fill(0);
      return Response.json({version:1, context, algorithm:'RSA-OAEP-256+A256GCM', wrapped_key:base64(wrappedKey), iv:base64(iv), ciphertext:base64(ciphertext)}, {headers});
    } catch { return fail(503, 'migration_export_unavailable'); }
  };
}
