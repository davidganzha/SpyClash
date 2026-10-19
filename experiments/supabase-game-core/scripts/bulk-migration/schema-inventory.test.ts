import { captureSchemaInventory } from './schema-inventory.ts';
import { captureSourceSnapshot, ENTITIES } from './source-export.ts';
const assert = (ok: unknown) => { if (!ok) throw new Error('assertion failed'); };
async function rejects(fn: () => Promise<unknown>, code: string) {
  try { await fn(); } catch (e) { assert(e instanceof Error && e.message === 'schema_inventory_' + code); return; }
  throw new Error('expected rejection');
}
async function fixture() {
  const now = () => new Date('2026-10-19T11:00:00Z');
  const snapshot = await captureSourceSnapshot(name => Promise.resolve(name === 'AccountDeletionReceipt' ? { confirmedSchemaAbsent: name } : []), { now });
  const raw = { total: 26, schemas: ENTITIES.filter(n => n !== 'AccountDeletionReceipt').map(entity_name => ({ entity_name, entity_schema: { type: 'object' } })) };
  return { now, snapshot, raw };
}
Deno.test('independent schemas require two complete matching responses bound to fresh snapshot', async () => {
  const f = await fixture(); let calls = 0;
  const result = await captureSchemaInventory(f.snapshot, () => { calls++; return Promise.resolve(f.raw); }, f.now);
  assert(calls === 2 && result.evidence.remote_total === 26 && result.evidence.source_snapshot_digest === f.snapshot.digest);
  assert(result.evidence.tracked_but_absent[0] === 'AccountDeletionReceipt' && result.evidence.production_mutations === false);
});
Deno.test('unknown or missing deployed entities block completeness claims', async () => {
  const f = await fixture(); f.raw.schemas[0].entity_name = 'UnknownEntity' as any;
  await rejects(() => captureSchemaInventory(f.snapshot, () => Promise.resolve(f.raw), f.now), 'remote_entity_inventory_changed');
});
Deno.test('schema changes between independent reads block the proof', async () => {
  const f = await fixture(); let calls = 0;
  await rejects(() => captureSchemaInventory(f.snapshot, () => { const row = structuredClone(f.raw); if (++calls === 2) row.schemas[0].entity_schema.type = 'changed'; return Promise.resolve(row); }, f.now), 'schemas_changed_repeat_capture');
});
Deno.test('stale source archive is rejected before any remote request', async () => {
  const f = await fixture(); let called = false;
  await rejects(() => captureSchemaInventory(f.snapshot, () => { called = true; return Promise.resolve(f.raw); }, () => new Date('2026-10-19T11:06:00Z')), 'snapshot_not_fresh');
  assert(!called);
});
Deno.test('private response errors are reduced to a bounded code', async () => {
  const f = await fixture();
  await rejects(() => captureSchemaInventory(f.snapshot, () => { throw new Error('private-token private-email provider-response'); }, f.now), 'read_failed');
});
