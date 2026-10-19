/** Complete, read-only Base44 archive. Raw rows are private operator data. */
export const SOURCE = { origin: 'https://spyclash.com', appID: '69a0e57fa939f578082f8091' } as const;
export const ENTITIES = [
  'AccountDeletionReceipt', 'AiGenerationQuota', 'AiGenerationUsage', 'AiWordPackCacheVariant',
  'AiWordPackOperation', 'AiWordPackRequestResult', 'AppStoreAccount', 'AppleSignInCredential',
  'BillingIdentityLifecycle', 'CommunityProfileSignal', 'CommunityReport', 'Entitlement',
  'Friendship', 'GameHistory', 'GameRoom', 'GameRoomSignal', 'LiveActivityRegistration',
  'MembershipGrant', 'MembershipSignal', 'NotificationAnnouncement', 'NotificationReadReceipt',
  'ProfileComment', 'PushDeviceRegistration', 'PushNotificationEvent', 'RoomInvite', 'User', 'WordPack',
] as const;
export type Row = Record<string, unknown>;
export type Reader = (entity: string, options: { sort: 'id'; limit: number; skip: number }) => Promise<unknown>;
export type EntityInventory = { entity: string; count: number; sourceAvailability: 'deployed' | 'confirmed_schema_absent'; firstPassDigest: string; verifiedDigest: string; schemaDigest: string | null };
export type SourceSnapshot = {
  version: 1; source: typeof SOURCE; capturedAt: string; verifiedAt: string;
  entities: Record<string, Row[]>; inventory: EntityInventory[]; digest: string;
  schemaInventoryOrigin: string; sourceSchemas: Record<string, unknown>;
  consistency: 'two_complete_matching_reads_not_cross_entity_transaction';
};
export class ExportError extends Error {
  constructor(public code: string, public entity?: string) { super(code); this.name = 'ExportError'; }
}
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value !== null && typeof value === 'object') return '{' + Object.keys(value as Row).sort().map(k => JSON.stringify(k) + ':' + canonical((value as Row)[k])).join(',') + '}';
  const encoded = JSON.stringify(value);
  if (encoded === undefined) throw new ExportError('non_json_source_value');
  return encoded;
}
export async function digest(value: unknown): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(canonical(value))))].map(v => v.toString(16).padStart(2, '0')).join('');
}
function validateInventory(entities: string[]) {
  if (entities.length !== ENTITIES.length || new Set(entities).size !== entities.length || ENTITIES.some(e => !entities.includes(e))) throw new ExportError('incomplete_entity_inventory');
}
async function readEntity(read: Reader, entity: string, pageSize: number, maxRows: number): Promise<{ rows: Row[]; available: boolean }> {
  const rows: Row[] = []; let previous = '';
  for (let skip = 0; skip <= maxRows; skip += pageSize) {
    let page: unknown;
    try { page = await read(entity, { sort: 'id', limit: pageSize, skip }); }
    catch { throw new ExportError('source_read_failed', entity); }
    if (page && typeof page === 'object' && !Array.isArray(page) && (page as Row).confirmedSchemaAbsent === entity) {
      if (skip !== 0) throw new ExportError('source_changed_repeat_snapshot', entity);
      return { rows: [], available: false };
    }
    if (!Array.isArray(page) || page.length > pageSize) throw new ExportError('invalid_source_page', entity);
    for (const candidate of page) {
      if (!candidate || typeof candidate !== 'object' || Array.isArray(candidate)) throw new ExportError('invalid_source_record', entity);
      const row = candidate as Row, id = row.id;
      if (typeof id !== 'string' || !id || id.length > 200) throw new ExportError('missing_stable_source_id', entity);
      if (previous && id <= previous) throw new ExportError('duplicate_or_unstable_pagination', entity);
      previous = id; rows.push(row);
      if (rows.length > maxRows) throw new ExportError('source_row_bound_exceeded', entity);
    }
    if (page.length < pageSize) return { rows, available: true };
  }
  throw new ExportError('source_row_bound_exceeded', entity);
}
export async function captureSourceSnapshot(read: Reader, options: {
  entities?: string[]; schemas?: Record<string, unknown>; pageSize?: number; maxRowsPerEntity?: number;
  now?: () => Date; progress?: (entity: string, phase: 'capture' | 'verify', count: number) => void;
} = {}): Promise<SourceSnapshot> {
  const entities = [...(options.entities || ENTITIES)].sort(); validateInventory(entities);
  const pageSize = options.pageSize ?? 250, maxRows = options.maxRowsPerEntity ?? 100_000;
  if (!Number.isInteger(pageSize) || pageSize < 1 || pageSize > 500 || !Number.isInteger(maxRows) || maxRows < 1 || maxRows > 1_000_000) throw new ExportError('invalid_export_bounds');
  const now = options.now || (() => new Date()), capturedAt = now().toISOString();
  const data: Record<string, Row[]> = {}, inventory: EntityInventory[] = [];
  for (const entity of entities) {
    const captured = await readEntity(read, entity, pageSize, maxRows);
    data[entity] = captured.rows;
    inventory.push({ entity, count: data[entity].length, sourceAvailability: captured.available ? 'deployed' : 'confirmed_schema_absent', firstPassDigest: await digest(data[entity]), verifiedDigest: '', schemaDigest: options.schemas?.[entity] ? await digest(options.schemas[entity]) : null });
    options.progress?.(entity, 'capture', data[entity].length);
  }
  // A second FULL scan detects edits/deletions as well as inserts beyond page one.
  for (const record of inventory) {
    const again = await readEntity(read, record.entity, pageSize, maxRows);
    record.verifiedDigest = await digest(again.rows);
    if ((record.sourceAvailability === 'deployed') !== again.available || record.count !== again.rows.length || record.firstPassDigest !== record.verifiedDigest) throw new ExportError('source_changed_repeat_snapshot', record.entity);
    options.progress?.(record.entity, 'verify', again.rows.length);
  }
  const value = { version: 1 as const, source: SOURCE, capturedAt, verifiedAt: now().toISOString(), entities: data, inventory,
    schemaInventoryOrigin: 'tracked_base44_entities_plus_builtin_User; each_named_entity_read_or_exact_schema_absence_verified_twice',
    sourceSchemas: options.schemas || {}, consistency: 'two_complete_matching_reads_not_cross_entity_transaction' as const };
  return { ...value, digest: await digest(value) };
}

export function aggregateSnapshot(snapshot: SourceSnapshot) {
  const users = snapshot.entities.User, ids = new Set(users.map(r => r.id));
  const spyIDs = users.map(r => String(r.spy_id || '').trim()).filter(v => /^\d{3}-\d{3}$/.test(v));
  const pairs: Record<string, [string, string]> = { Friendship: ['requester_id', 'addressee_id'], ProfileComment: ['target_user_id', 'author_user_id'], RoomInvite: ['sender_user_id', 'recipient_user_id'] };
  const relationships = Object.fromEntries(Object.entries(pairs).map(([entity, fields]) => [entity, { rows: snapshot.entities[entity].length,
    missing_source_participant_rows: snapshot.entities[entity].filter(r => fields.some(f => !ids.has(r[f]))).length }]));
  return { version: snapshot.version, source: snapshot.source, captured_at: snapshot.capturedAt, verified_at: snapshot.verifiedAt,
    digest: snapshot.digest, read_only: true, complete_known_entity_inventory: true, schema_inventory_origin: snapshot.schemaInventoryOrigin,
    consistency: snapshot.consistency, entities: snapshot.inventory, total_rows: snapshot.inventory.reduce((n, e) => n + e.count, 0),
    users: { total: users.length, valid_spy_ids: spyIDs.length, duplicate_valid_spy_ids: spyIDs.length - new Set(spyIDs).size,
      missing_or_invalid_spy_ids: users.length - spyIDs.length, verified: users.filter(r => r.is_verified === true).length,
      has_name: users.filter(r => String(r.display_name || r.full_name || '').trim()).length,
      onboarded: users.filter(r => r.onboarding_completed === true).length,
      administrators: users.filter(r => r.role === 'admin').length }, relationships,
    raw_payload_committed: false, archive_mode: '0600', archive_directory_mode: '0700', production_mutations: false };
}

/** Runs only within authenticated `base44 exec`; SDK surface permits reads only. */
export async function runSourceExport(client: {
  auth: { me(): Promise<Row> }; entities: Record<string, { list(sort: string, limit: number, skip: number): Promise<unknown> }>;
}, repositoryRoot: string, captureName?: string) {
  if (captureName !== undefined && !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(captureName)) throw new ExportError('invalid_capture_name');
  const root = await Deno.realPath(repositoryRoot), baseDirectory = root + '/experiments/supabase-game-core/.local/bulk-migration';
  const directory = baseDirectory + (captureName ? '/' + captureName : '');
  if (Deno.env.get('BASE44_APP_ID') !== SOURCE.appID) throw new ExportError('unexpected_source_app');
  const me = await client.auth.me();
  if (me.role !== 'admin') throw new ExportError('source_administrator_required');
  const schemas: Record<string, unknown> = {};
  for await (const item of Deno.readDir(root + '/base44/entities')) {
    if (!item.isFile || !item.name.endsWith('.jsonc')) continue;
    const schema = JSON.parse(await Deno.readTextFile(root + '/base44/entities/' + item.name));
    if (typeof schema.name !== 'string' || schemas[schema.name]) throw new ExportError('invalid_schema_inventory');
    schemas[schema.name] = schema;
  }
  validateInventory(Object.keys(schemas));
  await Deno.mkdir(baseDirectory, { recursive: true, mode: 0o700 });
  if ((await Deno.lstat(baseDirectory)).isSymlink || await Deno.realPath(baseDirectory) !== baseDirectory) throw new ExportError('private_directory_symlink');
  await Deno.chmod(baseDirectory, 0o700);
  await Deno.mkdir(directory, { recursive: true, mode: 0o700 });
  if ((await Deno.lstat(directory)).isSymlink) throw new ExportError('private_directory_symlink');
  await Deno.chmod(directory, 0o700);
  const archive = directory + '/source-snapshot.json';
  try { await Deno.lstat(archive); throw new ExportError('snapshot_already_exists'); }
  catch (error) { if (!(error instanceof Deno.errors.NotFound)) throw error; }
  const snapshot = await captureSourceSnapshot(async (entity, o) => {
    try { return await client.entities[entity].list(o.sort, o.limit, o.skip); }
    catch (error) {
      const e = error as { status?: number; message?: string };
      if (e?.status === 404 && e.message === `Entity schema ${entity} not found in app`) return { confirmedSchemaAbsent: entity };
      throw error;
    }
  }, { schemas,
    progress: (entity, phase, count) => console.error(JSON.stringify({ phase, entity, count })) });
  const temporary = archive + '.tmp-' + crypto.randomUUID();
  try {
    await Deno.writeTextFile(temporary, JSON.stringify(snapshot) + '\n', { createNew: true, mode: 0o600 });
    await Deno.chmod(temporary, 0o600);
    // link is atomic and refuses to overwrite an existing final snapshot.
    await Deno.link(temporary, archive);
  } finally { await Deno.remove(temporary).catch(() => {}); }
  const aggregate = aggregateSnapshot(snapshot);
  const aggregatePath = directory + '/source-summary.json';
  await Deno.writeTextFile(aggregatePath, JSON.stringify(aggregate, null, 2) + '\n', { createNew: true, mode: 0o600 });
  console.log(JSON.stringify({ exported: true, source: SOURCE.appID, entity_count: snapshot.inventory.length,
    total_rows: aggregate.total_rows, digest: snapshot.digest, raw_path: archive, summary_path: aggregatePath, production_mutations: false }));
  return aggregate;
}
