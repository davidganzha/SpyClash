-- Read-only, aggregate-only verification; never returns raw game state or keys.
with checks(name,passed) as (
 select 'private_rls',bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='full_game_private' and c.relkind='r'
 union all select 'private_client_privileges',bool_and(not has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE') and not has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE')) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='full_game_private' and c.relkind='r'
 union all select 'room_revision',not exists(select 1 from full_game_private.rooms where revision<>(state->>'room_revision')::bigint)
 union all select 'signal_revision',not exists(select 1 from full_game_private.rooms r left join public.full_game_room_signals s on s.room_id=r.id where s.revision is distinct from r.revision)
 union all select 'membership_authority',not exists(select 1 from full_game_private.members m join full_game_private.rooms r on r.id=m.room_id where not exists(select 1 from jsonb_array_elements(r.state->'players') p where p->>'user_id'=m.user_id::text and p->>'membership_id'=m.membership_id::text and not coalesce(r.state->'departed_player_emails','[]'::jsonb) ? (p->>'email')))
 union all select 'receipt_identity',not exists(select 1 from full_game_private.receipts where status=200 and response#>>'{receipt,request_id}' is distinct from request_id::text)
 union all select 'receipt_revision',not exists(select 1 from full_game_private.receipts where status=200 and room_id is not null and (response#>>'{receipt,revision}')::bigint is distinct from revision)
 union all select 'signal_read_only',has_table_privilege('authenticated','public.full_game_room_signals','SELECT') and not has_table_privilege('authenticated','public.full_game_room_signals','INSERT,UPDATE,DELETE') and not has_table_privilege('anon','public.full_game_room_signals','SELECT,INSERT,UPDATE,DELETE')
 union all select 'signal_publication',exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='full_game_room_signals')
 union all select 'configuration_key',exists(select 1 from full_game_private.configuration where key='leaderboard_pseudonym' and octet_length(value)>=32)
)
select jsonb_build_object('checks',count(*),'passed',count(*)filter(where passed),'failed',coalesce(jsonb_agg(name)filter(where passed is not true),'[]'::jsonb),'rooms',(select count(*) from full_game_private.rooms),'receipts',(select count(*)from full_game_private.receipts),'history',(select count(*)from full_game_private.history),'outbox',(select count(*)from full_game_private.outbox)) as audit from checks;
