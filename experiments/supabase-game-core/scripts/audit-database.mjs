import pg from 'pg';

// Acceptance audit only: never migrate, repair, or print credentials/user rows.
class AuditFailure extends Error {}
function check(condition, name) {
  if (!condition) throw new AuditFailure(name);
}
function sameItems(actual, expected) {
  return JSON.stringify([...actual].sort()) === JSON.stringify([...expected].sort());
}

async function audit() {
  check(Boolean(process.env.DATABASE_URL), 'local_database_url_required');
  let url;
  try { url = new URL(process.env.DATABASE_URL); }
  catch { throw new AuditFailure('invalid_database_url'); }
  check(['postgres:', 'postgresql:'].includes(url.protocol)
    && ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)
    && url.port === '56322' && !url.search && !url.hash, 'isolated_loopback_database_required');

  const db = new pg.Client({ connectionString: url.href, connectionTimeoutMillis: 5_000,
    statement_timeout: 10_000, query_timeout: 12_000 });
  let connected = false;
  let transaction = false;
  try {
    await db.connect();
    connected = true;
    await db.query('BEGIN READ ONLY');
    transaction = true;
    await db.query('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ');

    const { rows: tables } = await db.query(`
      select n.nspname || '.' || c.relname as name, c.relrowsecurity as rls,
        has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
          or has_any_column_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,REFERENCES') as anon_access,
        has_table_privilege('authenticated', c.oid, 'SELECT')
          or has_any_column_privilege('authenticated', c.oid, 'SELECT') as auth_read,
        has_table_privilege('authenticated', c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
          or has_any_column_privilege('authenticated', c.oid, 'INSERT,UPDATE,REFERENCES') as auth_write
      from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      where c.relkind in ('r', 'p') and (n.nspname = 'game_private'
        or (n.nspname = 'public' and c.relname = 'game_room_signals'))
    `);
    check(sameItems(tables.map((row) => row.name), [
      'game_private.rooms', 'game_private.players', 'game_private.votes',
      'game_private.command_receipts', 'public.game_room_signals',
    ]), 'game_table_inventory');
    check(tables.every((row) => row.rls), 'rls_enabled_on_every_game_table');
    check(tables.every((row) => !row.anon_access), 'anonymous_table_access_denied');
    check(tables.every((row) => !row.auth_write), 'client_table_writes_denied');
    check(tables.every((row) => row.auth_read === (row.name === 'public.game_room_signals')),
      'client_reads_limited_to_signals');

    const expectedFunctions = new Map([
      ['game_private.can_read_room(uuid)', { definer: true, auth: true, volatility: 's' }],
      ['game_private.command_impl(uuid, uuid, text, jsonb)', { definer: true, auth: true, volatility: 'v' }],
      ['game_private.snapshot_impl(uuid)', { definer: true, auth: true, volatility: 's' }],
      ['game_private.payload_uuid(jsonb, text)', { definer: false, auth: false, volatility: 'i' }],
      ['game_private.reconcile_vote(uuid)', { definer: false, auth: false, volatility: 'v' }],
      ['game_private.validate_keys(jsonb, text[])', { definer: false, auth: false, volatility: 'i' }],
      ['game_private.validate_name(jsonb)', { definer: false, auth: false, volatility: 'i' }],
      ['game_private.validate_settings(jsonb)', { definer: false, auth: false, volatility: 's' }],
      ['public.game_command(uuid, uuid, text, jsonb)', { definer: false, auth: true, volatility: 'v' }],
      ['public.game_snapshot(uuid)', { definer: false, auth: true, volatility: 's' }],
    ]);
    const { rows: functions } = await db.query(`
      select n.nspname || '.' || p.proname || '(' || pg_catalog.oidvectortypes(p.proargtypes) || ')' as name,
        p.prosecdef as definer, p.provolatile as volatility, p.proconfig as settings,
        has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
        has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_execute
      from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'game_private' or (n.nspname = 'public' and p.proname like 'game_%')
    `);
    check(sameItems(functions.map((row) => row.name), expectedFunctions.keys()), 'game_function_inventory');
    check(functions.every((row) => !row.anon_execute), 'anonymous_function_execution_denied');
    check(functions.every((row) => row.settings?.includes('search_path=""')), 'function_search_paths_empty');
    check(functions.every((row) => {
      const expected = expectedFunctions.get(row.name);
      return row.definer === expected.definer && row.auth_execute === expected.auth
        && row.volatility === expected.volatility;
    }), 'function_privilege_and_snapshot_contract');
    check(functions.find((row) => row.name === 'game_private.command_impl(uuid, uuid, text, jsonb)')
      .settings.includes('lock_timeout=5s'), 'bounded_command_lock_wait');

    const { rows: policies } = await db.query(`
      select schemaname, tablename, policyname, roles::text[] as roles, cmd, qual, with_check
      from pg_catalog.pg_policies where schemaname = 'game_private'
        or (schemaname = 'public' and tablename = 'game_room_signals')
    `);
    check(policies.length === 1 && policies[0].schemaname === 'public'
      && policies[0].tablename === 'game_room_signals' && policies[0].policyname === 'member_read_signal'
      && sameItems(policies[0].roles, ['authenticated']) && policies[0].cmd === 'SELECT'
      && policies[0].qual === 'game_private.can_read_room(room_id)' && policies[0].with_check === null,
    'signal_membership_policy_only');

    const { rows: publication } = await db.query(`
      select schemaname, tablename, attnames::text[] as columns from pg_catalog.pg_publication_tables
      where pubname = 'supabase_realtime'
    `);
    check(publication.length === 1 && publication[0].schemaname === 'public'
      && publication[0].tablename === 'game_room_signals'
      && sameItems(publication[0].columns, ['room_id', 'revision', 'changed_at']),
    'realtime_publication_contains_only_secret_free_signals');

    const { rows: [rooms] } = await db.query(`
      select count(*)::int as checked,
        count(*) filter (where s.revision is distinct from r.revision)::int as bad_signal,
        count(*) filter (where c.n is distinct from r.revision or c.max_revision is distinct from r.revision
          or c.distinct_revisions is distinct from r.revision or c.min_revision is distinct from 1::bigint)::int as bad_receipts,
        count(*) filter (where r.phase <> 'closed' and not exists (
          select 1 from game_private.players p where p.room_id = r.id and p.user_id = r.host_id and p.active
        ))::int as bad_host
      from game_private.rooms r left join public.game_room_signals s on s.room_id = r.id
      left join lateral (
        select count(*) as n, max((result ->> 'revision')::bigint) as max_revision,
          min((result ->> 'revision')::bigint) as min_revision,
          count(distinct (result ->> 'revision')::bigint) as distinct_revisions
        from game_private.command_receipts where room_id = r.id
      ) c on true
    `);
    check(rooms.bad_signal === 0, 'room_signal_revisions_match');
    check(rooms.bad_receipts === 0, 'room_revisions_match_durable_receipts');
    check(rooms.bad_host === 0, 'open_rooms_have_active_host');

    const { rows: [receipts] } = await db.query(`
      select count(*)::int as checked, count(*) filter (where r.id is null
        or c.result ->> 'room_id' is distinct from c.room_id::text
        or c.result ->> 'request_id' is distinct from c.request_id::text)::int as invalid
      from game_private.command_receipts c left join game_private.rooms r on r.id = c.room_id
    `);
    check(receipts.invalid === 0, 'receipt_identities_match_committed_rooms');

    const { rows: [votes] } = await db.query(`
      select count(*)::int as checked, count(*) filter (where r.id is null
        or v.match_id is distinct from r.match_id or p.active is distinct from true
        or t.active is distinct from true or v.voter_id = v.target_id
        or r.phase not in ('voting', 'finished', 'closed'))::int as invalid
      from game_private.votes v left join game_private.rooms r on r.id = v.room_id
      left join game_private.players p on p.room_id = v.room_id and p.user_id = v.voter_id
      left join game_private.players t on t.room_id = v.room_id and t.user_id = v.target_id
    `);
    check(votes.invalid === 0, 'votes_have_current_match_and_active_participants');
    await db.query('ROLLBACK');
    transaction = false;
    return { status: 'PASS', audit: 'database_privileges_and_invariants', read_only: true,
      tables: tables.length, functions: functions.length, replicated_tables: publication.length,
      rooms_checked: rooms.checked, receipts_checked: receipts.checked, votes_checked: votes.checked };
  } finally {
    if (connected) {
      if (transaction) await db.query('ROLLBACK').catch(() => {});
      await db.end();
    }
  }
}

try { console.log(JSON.stringify(await audit())); }
catch (error) {
  // SQL errors can embed user data; output only our fixed check identifiers.
  console.error(JSON.stringify({ status: 'FAIL', audit: 'database_privileges_and_invariants',
    check: error instanceof AuditFailure ? error.message : 'database_connection_or_query' }));
  process.exitCode = 1;
}
