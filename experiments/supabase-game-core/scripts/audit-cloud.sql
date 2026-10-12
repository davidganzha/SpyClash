-- Read-only acceptance query for the isolated cloud test project only.
-- Submit as the `query` body to the Management API read-only endpoint, or run
-- inside BEGIN READ ONLY through an explicitly verified test-project DB URL.
-- https://supabase.com/docs/reference/api/v1-read-only-query
-- Run after the committed migration. A query error is a failed audit, never PASS.
-- The observer must have full read visibility, including RLS bypass/ownership;
-- do not add client grants or weaken RLS just to make this audit succeed.
-- Output contains only check labels and counts, never secrets or player rows.
with
expected_tables(name) as (values
  ('game_private.rooms'), ('game_private.players'), ('game_private.votes'),
  ('game_private.command_receipts'), ('public.game_room_signals')
),
tables as (
  select n.nspname || '.' || c.relname as name, c.relrowsecurity as rls,
    pg_catalog.has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
      or pg_catalog.has_any_column_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,REFERENCES') as anon_access,
    pg_catalog.has_table_privilege('authenticated', c.oid, 'SELECT')
      or pg_catalog.has_any_column_privilege('authenticated', c.oid, 'SELECT') as auth_read,
    pg_catalog.has_table_privilege('authenticated', c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
      or pg_catalog.has_any_column_privilege('authenticated', c.oid, 'INSERT,UPDATE,REFERENCES') as auth_write,
    pg_catalog.has_table_privilege(current_user, c.oid, 'SELECT')
      and not pg_catalog.row_security_active(c.oid) as full_observer_visibility
  from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where c.relkind in ('r', 'p') and (n.nspname = 'game_private'
    or (n.nspname = 'public' and c.relname = 'game_room_signals'))
),
expected_functions(name, definer, auth_execute, volatility) as (values
  ('game_private.can_read_room(uuid)', true, true, 's'),
  ('game_private.command_impl(uuid, uuid, text, jsonb)', true, true, 'v'),
  ('game_private.snapshot_impl(uuid)', true, true, 's'),
  ('game_private.payload_uuid(jsonb, text)', false, false, 'i'),
  ('game_private.reconcile_vote(uuid)', false, false, 'v'),
  ('game_private.validate_keys(jsonb, text[])', false, false, 'i'),
  ('game_private.validate_name(jsonb)', false, false, 'i'),
  ('game_private.validate_settings(jsonb)', false, false, 's'),
  ('public.game_command(uuid, uuid, text, jsonb)', false, true, 'v'),
  ('public.game_snapshot(uuid)', false, true, 's')
),
functions as (
  select n.nspname || '.' || p.proname || '(' || pg_catalog.oidvectortypes(p.proargtypes) || ')' as name,
    p.prosecdef as definer, p.provolatile::text as volatility, p.proconfig as settings,
    pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
    pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_execute
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'game_private' or (n.nspname = 'public' and p.proname like 'game_%')
),
policies as (
  select schemaname, tablename, policyname, roles::text[] as roles, cmd, qual, with_check
  from pg_catalog.pg_policies where schemaname = 'game_private'
    or (schemaname = 'public' and tablename = 'game_room_signals')
),
publication as (
  select schemaname, tablename, attnames::text[] as columns
  from pg_catalog.pg_publication_tables where pubname = 'supabase_realtime'
),
room_state as (
  select pg_catalog.count(*) as checked,
    pg_catalog.count(*) filter (where s.revision is distinct from r.revision) as bad_signal,
    pg_catalog.count(*) filter (where c.n is distinct from r.revision or c.max_revision is distinct from r.revision
      or c.distinct_revisions is distinct from r.revision or c.min_revision is distinct from 1::bigint) as bad_receipts,
    pg_catalog.count(*) filter (where r.phase <> 'closed' and not exists (
      select 1 from game_private.players p where p.room_id = r.id and p.user_id = r.host_id and p.active
    )) as bad_host
  from game_private.rooms r left join public.game_room_signals s on s.room_id = r.id
  left join lateral (
    select pg_catalog.count(*) as n, pg_catalog.max((result ->> 'revision')::bigint) as max_revision,
      pg_catalog.min((result ->> 'revision')::bigint) as min_revision,
      pg_catalog.count(distinct (result ->> 'revision')::bigint) as distinct_revisions
    from game_private.command_receipts where room_id = r.id
  ) c on true
),
receipt_state as (
  select pg_catalog.count(*) as checked, pg_catalog.count(*) filter (where r.id is null
    or c.result ->> 'room_id' is distinct from c.room_id::text
    or c.result ->> 'request_id' is distinct from c.request_id::text) as invalid
  from game_private.command_receipts c left join game_private.rooms r on r.id = c.room_id
),
vote_state as (
  select pg_catalog.count(*) as checked, pg_catalog.count(*) filter (where r.id is null
    or v.match_id is distinct from r.match_id or p.active is distinct from true
    or t.active is distinct from true or v.voter_id = v.target_id
    or r.phase not in ('voting', 'finished', 'closed')) as invalid
  from game_private.votes v left join game_private.rooms r on r.id = v.room_id
  left join game_private.players p on p.room_id = v.room_id and p.user_id = v.voter_id
  left join game_private.players t on t.room_id = v.room_id and t.user_id = v.target_id
),
checks(name, passed) as (
  select 'game_table_inventory', not exists (
    select 1 from expected_tables e full join tables t on e.name = t.name where e.name is null or t.name is null)
  union all select 'observer_has_full_table_visibility', (select pg_catalog.bool_and(full_observer_visibility) from tables)
  union all select 'rls_enabled_on_every_game_table', (select pg_catalog.bool_and(rls) from tables)
  union all select 'anonymous_table_access_denied', (select pg_catalog.bool_and(not anon_access) from tables)
  union all select 'client_table_writes_denied', (select pg_catalog.bool_and(not auth_write) from tables)
  union all select 'client_reads_limited_to_signals',
    (select pg_catalog.bool_and(auth_read = (name = 'public.game_room_signals')) from tables)
  union all select 'game_function_inventory', not exists (
    select 1 from expected_functions e full join functions f on e.name = f.name where e.name is null or f.name is null)
  union all select 'anonymous_function_execution_denied', (select pg_catalog.bool_and(not anon_execute) from functions)
  union all select 'function_search_paths_empty',
    (select pg_catalog.bool_and(coalesce('search_path=""' = any(settings), false)) from functions)
  union all select 'function_privilege_and_snapshot_contract', not exists (
    select 1 from expected_functions e join functions f on e.name = f.name
    where (e.definer, e.auth_execute, e.volatility) is distinct from (f.definer, f.auth_execute, f.volatility))
  union all select 'bounded_command_lock_wait', exists (
    select 1 from functions where name = 'game_private.command_impl(uuid, uuid, text, jsonb)'
      and 'lock_timeout=5s' = any(settings))
  union all select 'signal_membership_policy_only', (select pg_catalog.count(*) = 1 and pg_catalog.bool_and(
    schemaname = 'public' and tablename = 'game_room_signals' and policyname = 'member_read_signal'
    and roles = array['authenticated']::text[] and cmd = 'SELECT'
    and qual = 'game_private.can_read_room(room_id)' and with_check is null) from policies)
  union all select 'realtime_publication_contains_only_secret_free_signals',
    (select pg_catalog.count(*) = 1 and pg_catalog.bool_and(schemaname = 'public'
      and tablename = 'game_room_signals' and columns = array['room_id','revision','changed_at']::text[]) from publication)
  union all select 'room_signal_revisions_match', bad_signal = 0 from room_state
  union all select 'room_revisions_match_durable_receipts', bad_receipts = 0 from room_state
  union all select 'open_rooms_have_active_host', bad_host = 0 from room_state
  union all select 'receipt_identities_match_committed_rooms', invalid = 0 from receipt_state
  union all select 'votes_have_current_match_and_active_participants', invalid = 0 from vote_state
)
select pg_catalog.jsonb_build_object(
  'status', case when pg_catalog.bool_and(coalesce(passed, false)) then 'PASS' else 'FAIL' end,
  'audit', 'cloud_database_privileges_and_invariants', 'read_only', true,
  'checks', pg_catalog.count(*),
  'failed_checks', coalesce(pg_catalog.jsonb_agg(name order by name) filter (where passed is not true), '[]'::jsonb),
  'tables', (select pg_catalog.count(*) from tables),
  'functions', (select pg_catalog.count(*) from functions),
  'replicated_tables', (select pg_catalog.count(*) from publication),
  'rooms_checked', (select checked from room_state),
  'receipts_checked', (select checked from receipt_state),
  'votes_checked', (select checked from vote_state)
) as audit_result from checks;
