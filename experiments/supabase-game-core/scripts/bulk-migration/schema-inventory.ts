/** Read-only independent live schema capture. Uses the authenticated entity-schemas
 * API route identified in installed Base44 CLI core/resources/entity/api.ts.
 * No SDK function invocation, eject, deploy, or provider mutation is performed. */
import { canonical, digest, ENTITIES, SOURCE, type SourceSnapshot } from './source-export.ts';

type Row = Record<string, any>;
export const SCHEMA_ENDPOINT = 'https://app.base44.com/api/apps/' + SOURCE.appID + '/entity-schemas';
const fail = (code: string): never => { throw new Error('schema_inventory_' + code); };
function validateRaw(raw: Row): string[] {
  if (!raw || !Array.isArray(raw.schemas) || raw.total !== raw.schemas.length) fail('invalid_response');
  const names = raw.schemas.map((r: Row) => r?.entity_name);
  if (names.some((n: unknown) => typeof n !== 'string' || !/^[A-Za-z][A-Za-z0-9]*$/.test(n)) || new Set(names).size !== names.length
    || raw.schemas.some((r: Row) => !r.entity_schema || typeof r.entity_schema !== 'object' || Array.isArray(r.entity_schema))) fail('invalid_response');
  return names.sort();
}

export async function captureSchemaInventory(snapshot: SourceSnapshot, read: () => Promise<Row>, now: () => Date = () => new Date()) {
  const { digest: expected, ...body } = snapshot;
  if (snapshot.version !== 1 || canonical(snapshot.source) !== canonical(SOURCE) || await digest(body) !== expected
    || canonical(Object.keys(snapshot.entities).sort()) !== canonical([...ENTITIES].sort())
    || canonical(snapshot.inventory.map(r => r.entity).sort()) !== canonical([...ENTITIES].sort())) fail('invalid_snapshot');
  const start = now().getTime(), verified = Date.parse(snapshot.verifiedAt);
  if (!Number.isFinite(start) || !Number.isFinite(verified) || verified > start || start - verified > 5 * 60_000) fail('snapshot_not_fresh');
  const deployed = snapshot.inventory.filter(r => r.sourceAvailability === 'deployed').map(r => r.entity).sort();
  const absent = snapshot.inventory.filter(r => r.sourceAvailability === 'confirmed_schema_absent').map(r => r.entity).sort();
  let first: Row, second: Row;
  try { first = await read(); second = await read(); } catch { fail('read_failed'); }
  const firstNames = validateRaw(first!), secondNames = validateRaw(second!);
  if (canonical(firstNames) !== canonical(deployed) || canonical(secondNames) !== canonical(deployed)) fail('remote_entity_inventory_changed');
  const firstDigest = await digest(first!), secondDigest = await digest(second!);
  if (firstDigest !== secondDigest) fail('schemas_changed_repeat_capture');
  const checked = now();
  if (!Number.isFinite(checked.getTime()) || checked.getTime() < start || checked.getTime() - start > 60_000) fail('capture_window_invalid');
  return { first: first!, second: second!, evidence: {
    checked_at: checked.toISOString(), source_app: SOURCE.appID, source_snapshot_digest: snapshot.digest,
    endpoint: SCHEMA_ENDPOINT, method: 'GET', endpoint_evidence: 'Installed Base44 CLI core/resources/entity/api.ts entity-schemas API route; GET only',
    remote_total: first!.total, remote_entity_names: firstNames, two_complete_schema_reads_match: true,
    schema_inventory_digest: firstDigest, all_remote_entities_exported: true, unknown_remote_entities: [], tracked_but_absent: absent,
    production_mutations: false,
  } };
}

async function boundedJSON(response: Response): Promise<Row> {
  if (!response.ok || !response.body) fail('read_failed');
  const reader = response.body!.getReader(), parts: Uint8Array[] = []; let length = 0;
  try {
    while (true) {
      const next = await reader.read(); if (next.done) break;
      length += next.value.length;
      if (length > 4 * 1024 * 1024) { await reader.cancel(); fail('response_too_large'); }
      parts.push(next.value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(length); let offset = 0;
  for (const part of parts) { bytes.set(part, offset); offset += part.length; }
  return JSON.parse(new TextDecoder().decode(bytes));
}

if (import.meta.main) {
  try {
    const folder = await Deno.realPath(Deno.args[0] || '.local/bulk-migration/fresh');
    if (!folder.includes('/.local/')) fail('private_output_path_required');
    const outputs = ['remote-entity-inventory.json', 'remote-entity-inventory-verified.json', 'remote-schema-inventory.json'];
    for (const name of outputs) {
      try { await Deno.lstat(folder + '/' + name); fail('output_already_exists'); }
      catch (error) { if (!(error instanceof Deno.errors.NotFound)) throw error; }
    }
    const snapshot = JSON.parse(await Deno.readTextFile(folder + '/source-snapshot.json'));
    const auth = JSON.parse(await Deno.readTextFile((Deno.env.get('HOME') || '') + '/.base44/auth/auth.json'));
    if (typeof auth.accessToken !== 'string' || !auth.accessToken || /[\r\n]/.test(auth.accessToken)) fail('cli_auth_required');
    const result = await captureSchemaInventory(snapshot, async () => boundedJSON(await fetch(SCHEMA_ENDPOINT, {
      method: 'GET', redirect: 'error', signal: AbortSignal.timeout(20_000),
      headers: { Authorization: 'Bearer ' + auth.accessToken, Accept: 'application/json', 'User-Agent': 'Base44 CLI source inventory audit' },
    })));
    await Deno.chmod(folder, 0o700);
    for (const [index, value] of [result.first, result.second, result.evidence].entries()) {
      const path = folder + '/' + outputs[index];
      await Deno.writeTextFile(path, JSON.stringify(value) + '\n', { createNew: true, mode: 0o600 });
      await Deno.chmod(path, 0o600);
    }
    console.log(JSON.stringify({ captured: true, remote_entities: result.evidence.remote_total, schema_inventory_digest: result.evidence.schema_inventory_digest,
      source_snapshot_digest: snapshot.digest, checked_at: result.evidence.checked_at, production_mutations: false }));
  } catch (error) {
    const code = error instanceof Error && /^schema_inventory_[a-z_]+$/.test(error.message) ? error.message : 'schema_inventory_failed';
    console.error(JSON.stringify({ captured: false, code, production_mutations: false })); Deno.exit(1);
  }
}
