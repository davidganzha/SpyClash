-- Isolated SpyClash game-core experiment. This is not production parity.
-- One command, its durable receipt, and its public revision signal commit in
-- the same transaction. There are no account-wide leases or external calls.
-- Prototype rules: one spy, one round, host opens voting, all active players
-- vote, a unique plurality for the spy wins for civilians; a tie wins for spies.
-- Match IDs fence delayed commands from earlier games in a reused room.

create schema if not exists game_private;
revoke all on schema game_private from public, anon, authenticated, service_role;
-- USAGE is needed by the invoker wrappers and RLS predicate. This schema must
-- remain absent from the Supabase API exposed-schemas configuration.
grant usage on schema game_private to authenticated;
alter default privileges in schema game_private revoke execute on functions from public;

create table game_private.rooms (
  id uuid primary key,
  host_id uuid not null,
  revision bigint not null default 0 check (revision >= 0),
  phase text not null default 'lobby'
    check (phase in ('lobby', 'playing', 'voting', 'finished', 'closed')),
  settings jsonb not null default '{"max_players":6}'::jsonb,
  settings_revision integer not null default 1 check (settings_revision >= 1),
  lobby_id uuid not null default pg_catalog.gen_random_uuid(),
  match_id uuid,
  spy_id uuid,
  secret_word text,
  winner text check (winner in ('civilians', 'spies')),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  check (pg_catalog.jsonb_typeof(settings) = 'object'),
  check ((settings ->> 'max_players')::integer between 3 and 12),
  check (phase <> 'lobby' or
    (match_id is null and spy_id is null and secret_word is null and winner is null)),
  check (phase not in ('playing', 'voting', 'finished') or
    (match_id is not null and spy_id is not null and secret_word is not null)),
  check ((phase = 'finished') = (winner is not null) or phase = 'closed')
);

create table game_private.players (
  room_id uuid not null references game_private.rooms(id) on delete cascade,
  user_id uuid not null,
  membership_id uuid not null default pg_catalog.gen_random_uuid(),
  name text not null check (pg_catalog.char_length(name) between 1 and 32),
  ready boolean not null default false,
  active boolean not null default true,
  joined_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (room_id, user_id)
);
create index players_active_actor on game_private.players(user_id, room_id) where active;

create table game_private.votes (
  room_id uuid not null references game_private.rooms(id) on delete cascade,
  match_id uuid not null,
  voter_id uuid not null,
  target_id uuid not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (room_id, match_id, voter_id),
  foreign key (room_id, voter_id) references game_private.players(room_id, user_id),
  foreign key (room_id, target_id) references game_private.players(room_id, user_id),
  check (voter_id <> target_id)
);
create index votes_room_voter on game_private.votes(room_id, voter_id);
create index votes_room_target on game_private.votes(room_id, target_id);

create table game_private.command_receipts (
  actor_id uuid not null,
  request_id uuid not null,
  room_id uuid not null,
  action text not null,
  payload jsonb not null,
  result jsonb not null,
  committed_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (actor_id, request_id)
);

alter table game_private.rooms enable row level security;
alter table game_private.players enable row level security;
alter table game_private.votes enable row level security;
alter table game_private.command_receipts enable row level security;
revoke all on all tables in schema game_private from public, anon, authenticated, service_role;

-- This is the only replicated table. Its rows contain no roles, words, player
-- IDs, command payloads, or receipts. Clients refetch their authorized snapshot.
create table public.game_room_signals (
  room_id uuid primary key references game_private.rooms(id) on delete cascade,
  revision bigint not null check (revision >= 0),
  changed_at timestamptz not null default pg_catalog.clock_timestamp()
);
alter table public.game_room_signals enable row level security;
revoke all on public.game_room_signals from public, anon, authenticated, service_role;
grant select on public.game_room_signals to authenticated;

create function game_private.can_read_room(p_room_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from game_private.players p
    where p.room_id = p_room_id and p.user_id = auth.uid() and p.active
  );
$$;
revoke all on function game_private.can_read_room(uuid) from public, anon, authenticated, service_role;
grant execute on function game_private.can_read_room(uuid) to authenticated;

create policy member_read_signal on public.game_room_signals
for select to authenticated
using (game_private.can_read_room(room_id));

-- Internal validation helpers deliberately have no client EXECUTE grant.
create function game_private.validate_keys(p_payload jsonb, p_allowed text[])
returns void
language plpgsql immutable security invoker set search_path = ''
as $$
begin
  if p_payload is null or pg_catalog.jsonb_typeof(p_payload) <> 'object'
    or pg_catalog.octet_length(p_payload::text) > 4096
    or exists (select 1 from pg_catalog.jsonb_object_keys(p_payload) as k(key)
      where not (k.key = any(p_allowed))) then
    raise exception using errcode = 'P0001', message = 'invalid_payload';
  end if;
end;
$$;

create function game_private.validate_settings(p_settings jsonb)
returns jsonb
language plpgsql stable security invoker set search_path = ''
as $$
declare
  v_max numeric;
begin
  if p_settings is null or pg_catalog.jsonb_typeof(p_settings) <> 'object'
    or exists (select 1 from pg_catalog.jsonb_object_keys(p_settings) as k(key)
      where k.key <> 'max_players') then
    raise exception using errcode = 'P0001', message = 'invalid_settings';
  end if;
  if not (p_settings ? 'max_players') then
    return '{"max_players":6}'::jsonb;
  end if;
  if pg_catalog.jsonb_typeof(p_settings -> 'max_players') <> 'number' then
    raise exception using errcode = 'P0001', message = 'invalid_settings';
  end if;
  v_max := (p_settings ->> 'max_players')::numeric;
  if v_max <> pg_catalog.trunc(v_max) or v_max < 3 or v_max > 12 then
    raise exception using errcode = 'P0001', message = 'invalid_settings';
  end if;
  return pg_catalog.jsonb_build_object('max_players', v_max::integer);
end;
$$;

create function game_private.validate_name(p_payload jsonb)
returns text
language plpgsql immutable security invoker set search_path = ''
as $$
declare
  v_name text;
begin
  if pg_catalog.jsonb_typeof(p_payload -> 'name') is distinct from 'string' then
    raise exception using errcode = 'P0001', message = 'invalid_payload';
  end if;
  v_name := pg_catalog.btrim(p_payload ->> 'name');
  if pg_catalog.char_length(v_name) not between 1 and 32 or v_name ~ '[[:cntrl:]]' then
    raise exception using errcode = 'P0001', message = 'invalid_payload';
  end if;
  return v_name;
end;
$$;

create function game_private.payload_uuid(p_payload jsonb, p_key text)
returns uuid
language plpgsql immutable security invoker set search_path = ''
as $$
begin
  if pg_catalog.jsonb_typeof(p_payload -> p_key) is distinct from 'string' then
    raise exception using errcode = 'P0001', message = 'invalid_payload';
  end if;
  begin
    return (p_payload ->> p_key)::uuid;
  exception when invalid_text_representation then
    raise exception using errcode = 'P0001', message = 'invalid_payload';
  end;
end;
$$;

-- Caller already owns the room row lock. Finish only when every active player
-- has cast a still-valid vote. A departure removes votes by/for that player.
create function game_private.reconcile_vote(p_room_id uuid)
returns void
language plpgsql volatile security invoker set search_path = ''
as $$
declare
  v_room game_private.rooms%rowtype;
  v_players integer;
  v_votes integer;
  v_top bigint;
  v_top_count integer;
  v_target uuid;
begin
  select * into strict v_room from game_private.rooms where id = p_room_id;
  if v_room.phase <> 'voting' then return; end if;
  select pg_catalog.count(*) into v_players from game_private.players
    where room_id = p_room_id and active;
  select pg_catalog.count(*) into v_votes from game_private.votes
    where room_id = p_room_id and match_id = v_room.match_id;
  if v_players = 0 or v_votes <> v_players then return; end if;

  select pg_catalog.max(t.n) into v_top from (
    select pg_catalog.count(*) as n from game_private.votes
    where room_id = p_room_id and match_id = v_room.match_id group by target_id
  ) t;
  select pg_catalog.count(*) into v_top_count from (
    select target_id from game_private.votes
    where room_id = p_room_id and match_id = v_room.match_id
    group by target_id having pg_catalog.count(*) = v_top
  ) t;
  select target_id into v_target from game_private.votes
    where room_id = p_room_id and match_id = v_room.match_id
    group by target_id having pg_catalog.count(*) = v_top
    order by target_id limit 1;
  update game_private.rooms set phase = 'finished',
    winner = case when v_top_count = 1 and v_target = v_room.spy_id
      then 'civilians' else 'spies' end
    where id = p_room_id;
end;
$$;

create function game_private.command_impl(
  p_request_id uuid, p_room_id uuid, p_action text, p_payload jsonb
)
returns jsonb
language plpgsql volatile security definer set search_path = '' set lock_timeout = '5s'
as $$
declare
  v_actor uuid := auth.uid();
  v_room game_private.rooms%rowtype;
  v_receipt game_private.command_receipts%rowtype;
  v_member game_private.players%rowtype;
  v_name text;
  v_settings jsonb;
  v_count integer;
  v_target uuid;
  v_match uuid;
  v_spy uuid;
  v_word text;
  v_revision numeric;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception using errcode = 'P0001', message = 'unauthenticated';
  end if;
  if p_request_id is null or p_room_id is null or p_action is null
    or p_action not in ('create_room', 'join_room', 'set_ready', 'update_settings',
      'start_game', 'open_voting', 'vote', 'leave_room', 'close_room', 'return_to_lobby')
    or p_payload is null or pg_catalog.jsonb_typeof(p_payload) <> 'object'
    or pg_catalog.octet_length(p_payload::text) > 4096 then
    raise exception using errcode = 'P0001', message = 'invalid_payload';
  end if;

  -- All commands take the same lock order: exact actor+request, then one room.
  -- Hash collisions merely serialize unrelated requests; the full key remains
  -- the receipt's unique key and is checked below. No client-controlled actor.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'spyclash-request:' || v_actor::text || ':' || p_request_id::text, 0));
  select * into v_receipt from game_private.command_receipts
    where actor_id = v_actor and request_id = p_request_id;
  if found then
    if v_receipt.room_id <> p_room_id or v_receipt.action <> p_action
      or v_receipt.payload <> p_payload then
      raise exception using errcode = 'P0001', message = 'idempotency_mismatch';
    end if;
    -- Exact historical acknowledgement, even after subsequent changes or leave.
    -- Receipts never contain the room word, role, or other players' secrets.
    return v_receipt.result;
  end if;

  case p_action
    when 'create_room' then perform game_private.validate_keys(p_payload, array['name','settings']);
    when 'join_room' then perform game_private.validate_keys(p_payload, array['name']);
    when 'set_ready' then perform game_private.validate_keys(p_payload, array['ready','membership_id','settings_revision']);
    when 'update_settings' then perform game_private.validate_keys(p_payload, array['settings','expected_revision']);
    when 'start_game' then perform game_private.validate_keys(p_payload, array['lobby_id']);
    when 'vote' then perform game_private.validate_keys(p_payload, array['match_id','target_id']);
    when 'leave_room' then perform game_private.validate_keys(p_payload, array['membership_id','match_id']);
    when 'close_room' then perform game_private.validate_keys(p_payload, array['lobby_id','match_id']);
    else perform game_private.validate_keys(p_payload, array['match_id']);
  end case;

  if p_action = 'create_room' then
    v_name := game_private.validate_name(p_payload);
    v_settings := game_private.validate_settings(coalesce(p_payload -> 'settings', '{}'::jsonb));
    insert into game_private.rooms(id, host_id, settings)
      values (p_room_id, v_actor, v_settings)
      on conflict (id) do nothing returning * into v_room;
    if not found then
      raise exception using errcode = 'P0001', message = 'room_exists';
    end if;
    insert into game_private.players(room_id, user_id, name)
      values (p_room_id, v_actor, v_name);
  else
    select * into v_room from game_private.rooms where id = p_room_id for update;
    if not found then
      raise exception using errcode = 'P0001', message = 'room_not_found';
    end if;
    select * into v_member from game_private.players
      where room_id = p_room_id and user_id = v_actor and active;
    if p_action <> 'join_room' and not found then
      raise exception using errcode = 'P0001', message = 'not_member';
    end if;

    if p_action in ('set_ready', 'leave_room') then
      if game_private.payload_uuid(p_payload, 'membership_id') <> v_member.membership_id then
        raise exception using errcode = 'P0001', message = 'stale_membership';
      end if;
    end if;

    if p_action in ('join_room', 'set_ready', 'update_settings', 'start_game')
      and v_room.phase <> 'lobby' then
      raise exception using errcode = 'P0001', message = 'invalid_phase';
    end if;
    if p_action = 'start_game' or (p_action = 'close_room' and v_room.phase = 'lobby') then
      if game_private.payload_uuid(p_payload, 'lobby_id') <> v_room.lobby_id then
        raise exception using errcode = 'P0001', message = 'stale_lobby';
      end if;
    end if;
    -- Fence both an existing match and a stale supplied match after the room
    -- has already returned to the lobby. In particular, a delayed old leave
    -- must never remove somebody from the next lobby/game.
    if p_payload ? 'match_id' or (v_room.match_id is not null and v_room.phase <> 'lobby') then
      v_match := game_private.payload_uuid(p_payload, 'match_id');
      if v_match is distinct from v_room.match_id then
        raise exception using errcode = 'P0001', message = 'stale_match';
      end if;
    end if;
    select pg_catalog.count(*) into v_count from game_private.players
      where room_id = p_room_id and active;

    case p_action
      when 'join_room' then
        if v_room.phase <> 'lobby' then
          raise exception using errcode = 'P0001', message = 'invalid_phase';
        end if;
        if v_member.user_id is not null then
          raise exception using errcode = 'P0001', message = 'already_member';
        end if;
        if v_count >= (v_room.settings ->> 'max_players')::integer then
          raise exception using errcode = 'P0001', message = 'room_full';
        end if;
        v_name := game_private.validate_name(p_payload);
        insert into game_private.players(room_id, user_id, name)
          values (p_room_id, v_actor, v_name)
          on conflict (room_id, user_id) do update
            set name = excluded.name, active = true, ready = false,
              membership_id = pg_catalog.gen_random_uuid(),
              joined_at = pg_catalog.clock_timestamp();

      when 'set_ready' then
        if v_room.phase <> 'lobby' then
          raise exception using errcode = 'P0001', message = 'invalid_phase';
        end if;
        if pg_catalog.jsonb_typeof(p_payload -> 'ready') is distinct from 'boolean' then
          raise exception using errcode = 'P0001', message = 'invalid_payload';
        end if;
        if pg_catalog.jsonb_typeof(p_payload -> 'settings_revision') is distinct from 'number' then
          raise exception using errcode = 'P0001', message = 'invalid_payload';
        end if;
        v_revision := (p_payload ->> 'settings_revision')::numeric;
        if v_revision <> pg_catalog.trunc(v_revision) or v_revision < 1
          or v_revision > 2147483647 then
          raise exception using errcode = 'P0001', message = 'invalid_payload';
        end if;
        if v_revision <> v_room.settings_revision then
          raise exception using errcode = 'P0001', message = 'stale_settings';
        end if;
        update game_private.players set ready = (p_payload ->> 'ready')::boolean
          where room_id = p_room_id and user_id = v_actor;

      when 'update_settings' then
        if v_room.host_id <> v_actor then
          raise exception using errcode = 'P0001', message = 'host_required';
        end if;
        if v_room.phase <> 'lobby' then
          raise exception using errcode = 'P0001', message = 'invalid_phase';
        end if;
        if pg_catalog.jsonb_typeof(p_payload -> 'expected_revision') is distinct from 'number' then
          raise exception using errcode = 'P0001', message = 'invalid_payload';
        end if;
        v_revision := (p_payload ->> 'expected_revision')::numeric;
        if v_revision <> pg_catalog.trunc(v_revision) or v_revision < 0
          or v_revision > 9007199254740991 then
          raise exception using errcode = 'P0001', message = 'invalid_payload';
        end if;
        if v_revision <> v_room.revision then
          raise exception using errcode = 'P0001', message = 'stale_revision';
        end if;
        v_settings := game_private.validate_settings(p_payload -> 'settings');
        if (v_settings ->> 'max_players')::integer < v_count then
          raise exception using errcode = 'P0001', message = 'room_full';
        end if;
        update game_private.rooms set settings = v_settings,
          settings_revision = settings_revision + 1 where id = p_room_id;
        -- A readiness acknowledgement refers to the settings the player saw.
        update game_private.players set ready = false where room_id = p_room_id and active;

      when 'start_game' then
        if v_room.host_id <> v_actor then
          raise exception using errcode = 'P0001', message = 'host_required';
        end if;
        if v_room.phase <> 'lobby' then
          raise exception using errcode = 'P0001', message = 'invalid_phase';
        end if;
        if v_count < 3 then
          raise exception using errcode = 'P0001', message = 'not_enough_players';
        end if;
        if exists (select 1 from game_private.players
          where room_id = p_room_id and active and not ready) then
          raise exception using errcode = 'P0001', message = 'not_all_ready';
        end if;
        select user_id into v_spy from game_private.players
          where room_id = p_room_id and active
          order by pg_catalog.gen_random_uuid() limit 1;
        select word into v_word from (values
          ('Airport'), ('Library'), ('Museum'), ('Beach'), ('Restaurant'),
          ('Train station'), ('Hospital'), ('Cinema'), ('Mountain'), ('School')
        ) words(word) order by pg_catalog.gen_random_uuid() limit 1;
        update game_private.rooms set phase = 'playing', match_id = pg_catalog.gen_random_uuid(),
          spy_id = v_spy, secret_word = v_word, winner = null where id = p_room_id;
        delete from game_private.votes where room_id = p_room_id;

      when 'open_voting' then
        if v_room.host_id <> v_actor then
          raise exception using errcode = 'P0001', message = 'host_required';
        end if;
        if v_room.phase <> 'playing' then
          raise exception using errcode = 'P0001', message = 'invalid_phase';
        end if;
        update game_private.rooms set phase = 'voting' where id = p_room_id;

      when 'vote' then
        if v_room.phase <> 'voting' then
          raise exception using errcode = 'P0001', message = 'invalid_phase';
        end if;
        v_target := game_private.payload_uuid(p_payload, 'target_id');
        if v_target = v_actor or not exists (select 1 from game_private.players
          where room_id = p_room_id and user_id = v_target and active) then
          raise exception using errcode = 'P0001', message = 'invalid_target';
        end if;
        if exists (select 1 from game_private.votes where room_id = p_room_id
          and match_id = v_room.match_id and voter_id = v_actor) then
          raise exception using errcode = 'P0001', message = 'already_voted';
        end if;
        insert into game_private.votes(room_id, match_id, voter_id, target_id)
          values (p_room_id, v_room.match_id, v_actor, v_target);
        perform game_private.reconcile_vote(p_room_id);

      when 'leave_room' then
        update game_private.players set active = false, ready = false
          where room_id = p_room_id and user_id = v_actor;
        delete from game_private.votes where room_id = p_room_id
          and (voter_id = v_actor or target_id = v_actor);
        if v_count = 1 then
          update game_private.rooms set phase = 'closed' where id = p_room_id;
        else
          if v_room.host_id = v_actor then
            select user_id into v_target from game_private.players
              where room_id = p_room_id and active order by joined_at, user_id limit 1;
            update game_private.rooms set host_id = v_target where id = p_room_id;
          end if;
          if v_room.phase in ('playing', 'voting') then
            if v_room.spy_id = v_actor then
              update game_private.rooms set phase = 'finished', winner = 'civilians'
                where id = p_room_id;
            elsif v_count - 1 <= 2 then
              update game_private.rooms set phase = 'finished', winner = 'spies'
                where id = p_room_id;
            else
              perform game_private.reconcile_vote(p_room_id);
            end if;
          end if;
        end if;

      when 'close_room' then
        if v_room.host_id <> v_actor then
          raise exception using errcode = 'P0001', message = 'host_required';
        end if;
        if v_room.phase = 'closed' then
          raise exception using errcode = 'P0001', message = 'invalid_phase';
        end if;
        update game_private.rooms set phase = 'closed' where id = p_room_id;

      when 'return_to_lobby' then
        if v_room.host_id <> v_actor then
          raise exception using errcode = 'P0001', message = 'host_required';
        end if;
        if v_room.phase <> 'finished' then
          raise exception using errcode = 'P0001', message = 'invalid_phase';
        end if;
        update game_private.rooms set phase = 'lobby', match_id = null,
          spy_id = null, secret_word = null, winner = null,
          settings_revision = settings_revision + 1, lobby_id = pg_catalog.gen_random_uuid()
          where id = p_room_id;
        update game_private.players set ready = false where room_id = p_room_id;
        delete from game_private.votes where room_id = p_room_id;
    end case;
  end if;

  update game_private.rooms set revision = revision + 1, updated_at = pg_catalog.clock_timestamp()
    where id = p_room_id returning * into v_room;
  v_result := pg_catalog.jsonb_build_object(
    'room_id', v_room.id, 'request_id', p_request_id, 'revision', v_room.revision,
    'phase', v_room.phase, 'match_id', v_room.match_id, 'winner', v_room.winner
  );
  insert into game_private.command_receipts(actor_id, request_id, room_id, action, payload, result)
    values (v_actor, p_request_id, p_room_id, p_action, p_payload, v_result);
  insert into public.game_room_signals(room_id, revision, changed_at)
    values (p_room_id, v_room.revision, v_room.updated_at)
    on conflict (room_id) do update
      set revision = excluded.revision, changed_at = excluded.changed_at;
  return v_result;
end;
$$;

create function game_private.snapshot_impl(p_room_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_room game_private.rooms%rowtype;
  v_players jsonb;
  v_votes jsonb;
  v_has_role boolean;
  v_membership uuid;
begin
  if v_actor is null then
    raise exception using errcode = 'P0001', message = 'unauthenticated';
  end if;
  if not game_private.can_read_room(p_room_id) then
    raise exception using errcode = 'P0001', message = 'not_member';
  end if;
  select * into strict v_room from game_private.rooms where id = p_room_id;
  select membership_id into strict v_membership from game_private.players
    where room_id = p_room_id and user_id = v_actor and active;
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'user_id', p.user_id, 'membership_id', p.membership_id,
    'name', p.name, 'ready', p.ready, 'joined_at', p.joined_at
  ) order by p.joined_at, p.user_id), '[]'::jsonb) into v_players
    from game_private.players p where p.room_id = p_room_id and p.active;
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'voter_id', v.voter_id, 'target_id', v.target_id
  ) order by v.created_at, v.voter_id), '[]'::jsonb) into v_votes
    from game_private.votes v where v.room_id = p_room_id and v.match_id = v_room.match_id;
  v_has_role := v_room.phase in ('playing', 'voting', 'finished');
  return pg_catalog.jsonb_build_object(
    'room_id', v_room.id, 'revision', v_room.revision, 'phase', v_room.phase,
    'host_id', v_room.host_id, 'settings', v_room.settings, 'players', v_players,
    'settings_revision', v_room.settings_revision, 'lobby_id', v_room.lobby_id,
    'own_membership_id', v_membership,
    'match_id', v_room.match_id,
    'own_role', case when not v_has_role then null
      when v_actor = v_room.spy_id then 'spy' else 'civilian' end,
    'own_word', case when v_has_role and v_actor <> v_room.spy_id then v_room.secret_word else null end,
    'votes', v_votes, 'winner', v_room.winner
  );
end;
$$;

-- Narrow privileged implementations are private and each authorizes auth.uid().
-- No function accepts an actor argument or a caller-provided secret assignment.
revoke all on all functions in schema game_private from public, anon, authenticated, service_role;
grant execute on function game_private.can_read_room(uuid) to authenticated;
grant execute on function game_private.command_impl(uuid, uuid, text, jsonb) to authenticated;
grant execute on function game_private.snapshot_impl(uuid) to authenticated;

create function public.game_command(
  p_request_id uuid, p_room_id uuid, p_action text, p_payload jsonb default '{}'::jsonb
)
returns jsonb
language sql volatile security invoker set search_path = ''
as $$ select game_private.command_impl(p_request_id, p_room_id, p_action, p_payload); $$;

create function public.game_snapshot(p_room_id uuid)
returns jsonb
language sql stable security invoker set search_path = ''
as $$ select game_private.snapshot_impl(p_room_id); $$;

revoke all on function public.game_command(uuid, uuid, text, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.game_snapshot(uuid) from public, anon, authenticated, service_role;
grant execute on function public.game_command(uuid, uuid, text, jsonb) to authenticated;
grant execute on function public.game_snapshot(uuid) to authenticated;

do $$
begin
  if not exists (select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'game_room_signals') then
    alter publication supabase_realtime add table public.game_room_signals;
  end if;
end;
$$;
