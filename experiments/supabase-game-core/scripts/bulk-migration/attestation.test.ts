import { createSourceAttestation, type AttestationInput } from './attestation.ts';
import { captureSourceSnapshot, ENTITIES, SOURCE } from './source-export.ts';
import { canonical, digest } from '../../supabase/functions/app-services/integration-crypto.ts';

type Row = Record<string, any>;
const hash = (value: unknown) => digest(canonical(value));
function assert(value: unknown, message = 'assertion failed'): asserts value { if (!value) throw new Error(message); }
async function rejects(input: AttestationInput, code: string) {
  try { await createSourceAttestation(input); } catch (error) {
    assert(error instanceof Error && error.message === 'attestation_' + code, 'wrong bounded error: ' + (error instanceof Error ? error.message : 'unknown')); return;
  }
  throw new Error('expected rejection');
}
async function resignSnapshot(snapshot: Row) {
  for (const item of snapshot.inventory) {
    item.count = snapshot.entities[item.entity].length;
    item.firstPassDigest = item.verifiedDigest = await hash(snapshot.entities[item.entity]);
  }
  const { digest: _, ...body } = snapshot; snapshot.digest = await hash(body);
}
async function bindFresh(input: AttestationInput) {
  await resignSnapshot(input.freshSnapshot);
  input.freshSchemaEvidence.source_snapshot_digest = input.freshSnapshot.digest;
}
async function fixture(): Promise<AttestationInput> {
  const data: Row = Object.fromEntries(ENTITIES.map(name => [name, []]));
  data.User = [{ id: 'private-user-id', email: 'private@example.test', spy_id: '123-456', progress: 42 }];
  const schemas = Object.fromEntries(ENTITIES.map(name => [name, { name, type: 'object' }]));
  let clock = 0;
  const snapshot = await captureSourceSnapshot((name) => Promise.resolve(name === 'AccountDeletionReceipt' ? { confirmedSchemaAbsent: name } : data[name]),
    { schemas, now: () => new Date(clock++ === 0 ? '2026-10-19T11:00:00Z' : '2026-10-19T11:00:10Z') });
  const deployed = ENTITIES.filter(name => name !== 'AccountDeletionReceipt').sort();
  const raw = { schemas: deployed.map(name => ({ entity_name: name, entity_schema: schemas[name] })), total: deployed.length };
  const evidence = { source_app: SOURCE.appID, source_snapshot_digest: snapshot.digest, checked_at: '2026-10-19T11:00:11Z',
    endpoint: 'https://app.base44.com/api/apps/' + SOURCE.appID + '/entity-schemas', method: 'GET',
    remote_total: deployed.length, remote_entity_names: deployed, two_complete_schema_reads_match: true,
    schema_inventory_digest: await hash(raw), all_remote_entities_exported: true, unknown_remote_entities: [], tracked_but_absent: ['AccountDeletionReceipt'] };
  const payload = { snapshot, remoteSchemaEvidence: evidence, core: { accounts: [{ user_id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }] } };
  const operatorJob = { id: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', project: 'bbkfsgnordtdiblgdzkg', token: 'private-capability-token',
    sourceDigest: snapshot.digest, sourceContentDigest: await hash({ source: snapshot.source, entities: snapshot.entities, schemas: snapshot.sourceSchemas }), planDigest: await hash(payload) };
  const freshSnapshot = structuredClone(snapshot);
  freshSnapshot.capturedAt = '2026-10-19T11:01:00Z'; freshSnapshot.verifiedAt = '2026-10-19T11:01:10Z';
  const input = { payload, operatorJob, freshSnapshot, freshSchemaEvidence: { ...structuredClone(evidence), checked_at: '2026-10-19T11:01:12Z' },
    freshSchemasFirst: structuredClone(raw), freshSchemasSecond: structuredClone(raw), now: new Date('2026-10-19T11:01:15Z') };
  await bindFresh(input); return input;
}

Deno.test('matching complete fresh proof emits bounded SQL and no private source content or capability', async () => {
  const input = await fixture(), result = await createSourceAttestation(input);
  assert(input.freshSnapshot.digest !== input.payload.snapshot.digest, 'refresh metadata must differ');
  assert(result.summary.source_rows === 1 && result.summary.remote_entities === 26);
  assert(result.sql.includes("source_attested_at='2026-10-19T11:01:10.000Z'::timestamptz"));
  assert(result.sql.includes("updated_at<='2026-10-19T11:01:00.000Z'::timestamptz"));
  assert(result.sql.includes("clock_timestamp()-interval '60 seconds'") && result.sql.includes('lease_until<=clock_timestamp()'));
  assert(result.sql.includes('left join auth.users') && result.sql.includes('returning id,status,source_attested_at'));
  for (const secret of ['private-user-id', 'private@example.test', 'private-capability-token', '123-456']) assert(!JSON.stringify(result).includes(secret));
});
Deno.test('validly recaptured row change fails even when all fresh digest fields agree', async () => {
  const input = await fixture(); input.freshSnapshot.entities.User[0].progress = 43; await bindFresh(input);
  await rejects(input, 'source_content_changed');
});
Deno.test('changed tracked schemas also invalidate source content', async () => {
  const input = await fixture(); input.freshSnapshot.sourceSchemas.User.type = 'changed'; await bindFresh(input);
  await rejects(input, 'source_content_changed');
});
Deno.test('unsealed source or operator payload cannot be attested', async () => {
  const input = await fixture(); input.payload.core.accounts = [];
  await rejects(input, 'sealed_payload_mismatch');
  const second = await fixture(); second.operatorJob.sourceDigest = '0'.repeat(64);
  await rejects(second, 'job_source_mismatch');
});
Deno.test('a complete snapshot cannot omit an empty entity', async () => {
  const input = await fixture(); delete input.freshSnapshot.entities.RoomInvite;
  input.freshSnapshot.inventory = input.freshSnapshot.inventory.filter((r: Row) => r.entity !== 'RoomInvite');
  await bindFresh(input); await rejects(input, 'incomplete_entity_inventory');
});
Deno.test('full archive hash does not substitute for the two verified entity reads', async () => {
  const input = await fixture(); input.freshSnapshot.inventory[0].verifiedDigest = '0'.repeat(64);
  const { digest: _, ...body } = input.freshSnapshot; input.freshSnapshot.digest = await hash(body);
  input.freshSchemaEvidence.source_snapshot_digest = input.freshSnapshot.digest;
  await rejects(input, 'unverified_source_entity');
});
Deno.test('fresh duplicate source IDs fail even if digest fields agree', async () => {
  const input = await fixture(); input.freshSnapshot.entities.User.push(structuredClone(input.freshSnapshot.entities.User[0])); await bindFresh(input);
  await rejects(input, 'invalid_source_ids');
});
Deno.test('matching two raw schema reads detect schema content drift from sealed baseline', async () => {
  const input = await fixture(); input.freshSchemasFirst.schemas[0].entity_schema.properties = { extra: { type: 'string' } };
  input.freshSchemasSecond = structuredClone(input.freshSchemasFirst);
  input.freshSchemaEvidence.schema_inventory_digest = await hash(input.freshSchemasFirst);
  await rejects(input, 'source_schema_changed');
});
Deno.test('different raw schema reads cannot be certified by summary metadata', async () => {
  const input = await fixture(); input.freshSchemasSecond.schemas[0].entity_schema.properties = {};
  await rejects(input, 'fresh_schema_reads_mismatch');
});
Deno.test('schema inventory requires exact live names and both verified reads', async () => {
  const input = await fixture(); input.freshSchemaEvidence.remote_entity_names[0] = 'UnknownEntity';
  await rejects(input, 'invalid_schema_evidence');
  const second = await fixture(); second.freshSchemaEvidence.two_complete_schema_reads_match = false;
  await rejects(second, 'invalid_schema_evidence');
});
Deno.test('proof freshness is bounded by the earlier completed rows or schemas check', async () => {
  const input = await fixture(); input.now = new Date('2026-10-19T11:02:10Z');
  await rejects(input, 'proof_expired');
  const second = await fixture(); second.freshSchemaEvidence.checked_at = '2026-10-19T11:01:16Z';
  await rejects(second, 'future_proof');
});
Deno.test('preexisting captures and pre-capture schema proofs cannot attest a new run', async () => {
  const input = await fixture(); input.freshSnapshot.capturedAt = '2026-10-19T11:00:09Z'; await bindFresh(input);
  await rejects(input, 'fresh_proof_precedes_capture');
  const second = await fixture(); second.freshSchemaEvidence.checked_at = '2026-10-19T11:00:59Z';
  await rejects(second, 'fresh_proof_precedes_capture');
});
Deno.test('SQL metadata is restricted to exact UUID, project and cryptographic hashes', async () => {
  const input = await fixture(); input.operatorJob.id += "';select";
  await rejects(input, 'invalid_operator_job');
  const second = await fixture(); second.operatorJob.project = 'wrongproject';
  await rejects(second, 'invalid_operator_job');
});
