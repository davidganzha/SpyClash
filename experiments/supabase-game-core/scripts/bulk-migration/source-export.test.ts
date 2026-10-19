import { captureSourceSnapshot, aggregateSnapshot, runSourceExport, ENTITIES, ExportError, type Row } from './source-export.ts';

function assert(value: unknown, message = 'assertion failed'): asserts value { if (!value) throw new Error(message); }
async function rejects(action: () => Promise<unknown>, code: string) {
  try { await action(); } catch (e) { assert(e instanceof ExportError && e.code === code, 'wrong safe error'); return; }
  throw new Error('expected rejection');
}
const empty = () => Object.fromEntries(ENTITIES.map(e => [e, [] as Row[]]));
const reader = (data: Record<string, Row[]>) => (entity: string, o: { skip: number; limit: number }) => Promise.resolve(data[entity].slice(o.skip, o.skip + o.limit));

Deno.test('complete paginated two-pass archive preserves full rows, including private fields, but aggregate omits them', async () => {
  const data = empty();
  data.User = [1, 2, 3].map(n => ({ id: String(n), email: 'private' + n + '@example.test', spy_id: n === 3 ? null : '100-00' + n, is_verified: true, full_name: 'Private name' }));
  data.AppleSignInCredential = [{ id: '1', refresh_token_ciphertext: 'private-encrypted-value' }];
  const seen: string[] = [];
  const snapshot = await captureSourceSnapshot(async (e, o) => { seen.push(e + ':' + o.skip); return reader(data)(e, o); }, { pageSize: 2 });
  assert(snapshot.entities.User.length === 3 && snapshot.entities.AppleSignInCredential[0].refresh_token_ciphertext === 'private-encrypted-value');
  assert(snapshot.inventory.length === 27 && snapshot.inventory.every(x => x.firstPassDigest === x.verifiedDigest));
  assert(seen.filter(x => x === 'User:2').length === 2);
  const summary = aggregateSnapshot(snapshot), text = JSON.stringify(summary);
  assert(summary.users.valid_spy_ids === 2 && summary.users.missing_or_invalid_spy_ids === 1);
  assert(!text.includes('private1') && !text.includes('Private name') && !text.includes('private-encrypted-value'));
});
Deno.test('detects a content change between scans', async () => {
  const data = empty(); data.User = [{ id: '1', display_name: 'before' }]; let passes = 0;
  await rejects(() => captureSourceSnapshot((e, o) => Promise.resolve(e === 'User' ? [{ id: '1', display_name: ++passes === 1 ? 'before' : 'after' }] : data[e])), 'source_changed_repeat_snapshot');
});
Deno.test('detects deletion between scans', async () => {
  let passes = 0;
  await rejects(() => captureSourceSnapshot(e => Promise.resolve(e === 'User' && ++passes === 1 ? [{ id: '1' }] : [])), 'source_changed_repeat_snapshot');
});
Deno.test('rejects repeated source IDs from unstable pagination', async () => {
  await rejects(() => captureSourceSnapshot((e) => Promise.resolve(e === 'User' ? [{ id: '1' }] : []), { pageSize: 1 }), 'duplicate_or_unstable_pagination');
});
Deno.test('refuses omitted entities rather than calling a partial export complete', async () => {
  await rejects(() => captureSourceSnapshot(reader(empty()), { entities: [...ENTITIES].filter(e => e !== 'AppleSignInCredential') }), 'incomplete_entity_inventory');
});
Deno.test('fails at the explicit row bound', async () => {
  const data = empty(); data.User = [{ id: '1' }, { id: '2' }];
  await rejects(() => captureSourceSnapshot(reader(data), { pageSize: 1, maxRowsPerEntity: 1 }), 'source_row_bound_exceeded');
});
Deno.test('source errors cannot place private response bodies in thrown errors', async () => {
  await rejects(() => captureSourceSnapshot(() => { throw new Error('secret credential and private email'); }), 'source_read_failed');
});
Deno.test('records exact schema absence separately from an empty deployed entity', async () => {
  const snapshot = await captureSourceSnapshot(e => Promise.resolve(e === 'AccountDeletionReceipt' ? { confirmedSchemaAbsent: e } : []));
  assert(snapshot.inventory.find(e => e.entity === 'AccountDeletionReceipt')?.sourceAvailability === 'confirmed_schema_absent');
  assert(snapshot.inventory.find(e => e.entity === 'User')?.sourceAvailability === 'deployed');
});
Deno.test('schema appearing during capture is drift even when its rows are empty', async () => {
  let passes = 0;
  await rejects(() => captureSourceSnapshot(e => Promise.resolve(e === 'AccountDeletionReceipt' && ++passes === 1 ? { confirmedSchemaAbsent: e } : [])), 'source_changed_repeat_snapshot');
});
Deno.test('private fresh-capture names reject path traversal before reading auth or files', async () => {
  let touched = false;
  const client = { auth: { me: () => { touched = true; return Promise.resolve({ role: 'admin' }); } }, entities: {} };
  await rejects(() => runSourceExport(client, '.', '../outside'), 'invalid_capture_name');
  assert(!touched);
});
