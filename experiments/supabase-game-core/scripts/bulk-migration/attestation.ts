/** Private, offline proof verifier. It emits SQL but never executes it or calls
 * either provider. A fresh matching proof is still not an atomic cross-provider
 * transaction; the runbook must also check source drift after application. */
import { canonical, digest } from '../../supabase/functions/app-services/integration-crypto.ts';
import { ENTITIES, SOURCE } from './source-export.ts';
import { SCHEMA_ENDPOINT } from './schema-inventory.ts';

type Row = Record<string, any>;
export type AttestationInput = {
  payload: Row; operatorJob: Row; freshSnapshot: Row; freshSchemaEvidence: Row;
  freshSchemasFirst: Row; freshSchemasSecond: Row; now?: Date;
};
const fail = (code: string): never => { throw new Error('attestation_' + code); };
const hash = (value: unknown) => digest(canonical(value));
const hex = (value: unknown): value is string => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const same = (a: unknown, b: unknown) => canonical(a) === canonical(b);
function timestamp(value: unknown, label: string): number {
  if (typeof value !== 'string' || !Number.isFinite(Date.parse(value))) fail('invalid_' + label);
  return Date.parse(value as string);
}
function names(value: unknown, label: string): string[] {
  if (!Array.isArray(value) || value.some(v => typeof v !== 'string' || !/^[A-Za-z][A-Za-z0-9]*$/.test(v)) || new Set(value).size !== value.length) fail('invalid_' + label);
  return [...value as string[]].sort();
}
async function checkSnapshot(snapshot: Row): Promise<string[]> {
  if (snapshot?.version !== 1 || !same(snapshot.source, SOURCE) || !hex(snapshot.digest) || !snapshot.entities || !Array.isArray(snapshot.inventory)) fail('invalid_snapshot');
  const { digest: expected, ...value } = snapshot;
  if (await hash(value) !== expected) fail('snapshot_digest_mismatch');
  if (!same(names(Object.keys(snapshot.entities), 'entity_names'), [...ENTITIES].sort())) fail('incomplete_entity_inventory');
  if (!same(names(snapshot.inventory.map((r: Row) => r.entity), 'inventory_names'), [...ENTITIES].sort())) fail('incomplete_entity_inventory');
  const captured = timestamp(snapshot.capturedAt, 'capture_time'), verified = timestamp(snapshot.verifiedAt, 'verification_time');
  if (verified < captured) fail('invalid_snapshot_time_order');
  for (const item of snapshot.inventory) {
    const rows = snapshot.entities[item.entity];
    if (!Array.isArray(rows) || item.count !== rows.length || !['deployed', 'confirmed_schema_absent'].includes(item.sourceAvailability)) fail('invalid_entity_inventory');
    if (item.sourceAvailability === 'confirmed_schema_absent' && rows.length) fail('absent_entity_contains_rows');
    const ids = rows.map((r: Row) => r?.id);
    if (ids.some((id: unknown) => typeof id !== 'string' || !id) || new Set(ids).size !== ids.length) fail('invalid_source_ids');
    const actual = await hash(rows);
    if (item.firstPassDigest !== actual || item.verifiedDigest !== actual) fail('unverified_source_entity');
  }
  return snapshot.inventory.filter((r: Row) => r.sourceAvailability === 'deployed').map((r: Row) => r.entity).sort();
}
function checkEvidence(evidence: Row, snapshot: Row, deployed: string[]) {
  if (evidence?.source_app !== SOURCE.appID || evidence.source_snapshot_digest !== snapshot.digest || evidence.method !== 'GET'
    || evidence.endpoint !== SCHEMA_ENDPOINT
    || evidence.two_complete_schema_reads_match !== true || evidence.all_remote_entities_exported !== true
    || !Array.isArray(evidence.unknown_remote_entities) || evidence.unknown_remote_entities.length || !hex(evidence.schema_inventory_digest)
    || evidence.remote_total !== deployed.length || !same(names(evidence.remote_entity_names, 'remote_schema_names'), deployed)) fail('invalid_schema_evidence');
  const absent = snapshot.inventory.filter((r: Row) => r.sourceAvailability === 'confirmed_schema_absent').map((r: Row) => r.entity).sort();
  if (!same(names(evidence.tracked_but_absent, 'absent_schema_names'), absent)) fail('invalid_absent_schema_evidence');
  timestamp(evidence.checked_at, 'schema_verification_time');
}
function checkRawSchemas(raw: Row, deployed: string[]) {
  if (!raw || !Array.isArray(raw.schemas) || raw.total !== raw.schemas.length || raw.total !== deployed.length) fail('invalid_raw_schema_inventory');
  if (!same(names(raw.schemas.map((r: Row) => r.entity_name), 'raw_schema_names'), deployed)) fail('raw_schema_inventory_mismatch');
  if (raw.schemas.some((r: Row) => !r.entity_schema || typeof r.entity_schema !== 'object' || Array.isArray(r.entity_schema))) fail('invalid_raw_schema');
}

export async function createSourceAttestation(input: AttestationInput) {
  const { payload, operatorJob: job, freshSnapshot: fresh, freshSchemaEvidence: evidence } = input;
  const now = input.now?.getTime() ?? Date.now();
  if (!Number.isFinite(now)) fail('invalid_current_time');
  if (!job || job.project !== 'bbkfsgnordtdiblgdzkg' || typeof job.id !== 'string' || !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(job.id)
    || !hex(job.planDigest) || !hex(job.sourceDigest) || !hex(job.sourceContentDigest)) fail('invalid_operator_job');
  if (await hash(payload) !== job.planDigest) fail('sealed_payload_mismatch');
  const original = payload.snapshot, originalNames = await checkSnapshot(original), freshNames = await checkSnapshot(fresh);
  if (job.sourceDigest !== original.digest) fail('job_source_mismatch');
  checkEvidence(payload.remoteSchemaEvidence, original, originalNames);
  checkEvidence(evidence, fresh, freshNames);
  if (!same(originalNames, freshNames)) fail('source_schema_inventory_changed');
  checkRawSchemas(input.freshSchemasFirst, freshNames); checkRawSchemas(input.freshSchemasSecond, freshNames);
  const firstSchemaDigest = await hash(input.freshSchemasFirst), secondSchemaDigest = await hash(input.freshSchemasSecond);
  if (firstSchemaDigest !== secondSchemaDigest || firstSchemaDigest !== evidence.schema_inventory_digest) fail('fresh_schema_reads_mismatch');
  if (firstSchemaDigest !== payload.remoteSchemaEvidence.schema_inventory_digest) fail('source_schema_changed');
  const content = (snapshot: Row) => ({ source: snapshot.source, entities: snapshot.entities, schemas: snapshot.sourceSchemas });
  const contentDigest = await hash(content(original));
  if (contentDigest !== job.sourceContentDigest) fail('sealed_source_content_mismatch');
  if (await hash(content(fresh)) !== contentDigest) fail('source_content_changed');
  const captureAt = timestamp(fresh.capturedAt, 'capture_time'), verifiedAt = timestamp(fresh.verifiedAt, 'verification_time'), schemaAt = timestamp(evidence.checked_at, 'schema_verification_time');
  if (captureAt < timestamp(original.verifiedAt, 'original_verification_time') || schemaAt < captureAt) fail('fresh_proof_precedes_capture');
  if (captureAt > now || verifiedAt > now || schemaAt > now) fail('future_proof');
  if (verifiedAt - captureAt > 5 * 60_000) fail('capture_window_too_long');
  const proofAt = Math.min(verifiedAt, schemaAt);
  if (now - proofAt >= 60_000) fail('proof_expired');
  const proofTime = new Date(proofAt).toISOString(), captureTime = new Date(captureAt).toISOString();
  // Job.updated_at must precede the NEW capture: this makes an attestation
  // captured before the final provisioning step fail at SQL application time.
  // Literal proof time prevents delayed/replayed SQL from renewing old evidence.
  const sql = `update app_private.bulk_migration_jobs
set source_attested_digest='${contentDigest}', source_attested_at='${proofTime}'::timestamptz, updated_at=clock_timestamp()
where id='${job.id}'::uuid
  and source_digest='${job.sourceDigest}' and source_content_digest='${contentDigest}' and plan_digest='${job.planDigest}'
  and status in ('reserved','provisioning') and token_expires_at>clock_timestamp()
  and (lease_until is null or lease_until<=clock_timestamp())
  and updated_at<='${captureTime}'::timestamptz
  and '${proofTime}'::timestamptz<=clock_timestamp()
  and '${proofTime}'::timestamptz>clock_timestamp()-interval '60 seconds'
  and not exists (select 1 from jsonb_array_elements(payload->'core'->'accounts') a
    left join auth.users u on u.id=(a->>'user_id')::uuid where u.id is null)
returning id,status,source_attested_at;
`;
  return { sql, summary: { ready: true, production_mutations: false, source_content_digest: contentDigest,
    proof_at: proofTime, fresh_capture_at: captureTime, source_rows: fresh.inventory.reduce((n: number, r: Row) => n + r.count, 0), remote_entities: freshNames.length,
    expires_at: new Date(proofAt + 60_000).toISOString(), note: 'Apply only after explicit production approval; require exactly one returned row. This is not a cross-provider atomic snapshot.' } };
}

async function privatePath(path: string) {
  const real = await Deno.realPath(path);
  if (!real.includes('/.local/')) fail('private_input_path_required');
  return real;
}
if (import.meta.main) {
  try {
    const jobFolder = await privatePath(Deno.args[0] || '.local/bulk-migration');
    const freshFolder = await privatePath(Deno.args[1] || '.local/bulk-migration/fresh');
    const read = async (folder: string, name: string) => JSON.parse(await Deno.readTextFile(await privatePath(folder + '/' + name)));
    const result = await createSourceAttestation({ payload: await read(jobFolder, 'job-payload.json'), operatorJob: await read(jobFolder, 'operator-job.json'),
      freshSnapshot: await read(freshFolder, 'source-snapshot.json'), freshSchemaEvidence: await read(freshFolder, 'remote-schema-inventory.json'),
      freshSchemasFirst: await read(freshFolder, 'remote-entity-inventory.json'), freshSchemasSecond: await read(freshFolder, 'remote-entity-inventory-verified.json') });
    const output = freshFolder + '/source-attestation.sql';
    await Deno.writeTextFile(output, result.sql, { createNew: true, mode: 0o600 });
    await Deno.chmod(output, 0o600);
    console.log(JSON.stringify({ ...result.summary, sql_path: output }));
  } catch (error) {
    const code = error instanceof Error && /^attestation_[a-z_]+$/.test(error.message) ? error.message : 'attestation_failed';
    console.error(JSON.stringify({ ready: false, code, production_mutations: false }));
    Deno.exit(1);
  }
}
