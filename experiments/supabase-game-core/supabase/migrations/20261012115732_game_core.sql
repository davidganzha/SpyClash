SET local check_function_bodies = off;

CREATE SCHEMA "game_private";

CREATE TABLE "game_private"."command_receipts" (
  "actor_id"     uuid                     NOT NULL,
  "request_id"   uuid                     NOT NULL,
  "room_id"      uuid                     NOT NULL,
  "action"       text                     NOT NULL,
  "payload"      jsonb                    NOT NULL,
  "result"       jsonb                    NOT NULL,
  "committed_at" timestamp with time zone NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT "command_receipts_pkey" PRIMARY KEY (actor_id, request_id)
);

ALTER TABLE "game_private"."command_receipts"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "game_private"."players" (
  "room_id"       uuid                     NOT NULL,
  "user_id"       uuid                     NOT NULL,
  "membership_id" uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "name"          text                     NOT NULL,
  "ready"         boolean                  NOT NULL DEFAULT false,
  "active"        boolean                  NOT NULL DEFAULT true,
  "joined_at"     timestamp with time zone NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT "players_name_check" CHECK (((char_length(name) >= 1) AND (char_length(name) <= 32))),
  CONSTRAINT "players_pkey" PRIMARY KEY (room_id, user_id)
);

ALTER TABLE "game_private"."players"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "game_private"."rooms" (
  "id"                uuid                     NOT NULL,
  "host_id"           uuid                     NOT NULL,
  "revision"          bigint                   NOT NULL DEFAULT 0,
  "phase"             text                     NOT NULL DEFAULT 'lobby'::text,
  "settings"          jsonb                    NOT NULL DEFAULT '{"max_players": 6}'::jsonb,
  "settings_revision" integer                  NOT NULL DEFAULT 1,
  "lobby_id"          uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "match_id"          uuid,
  "spy_id"            uuid,
  "secret_word"       text,
  "winner"            text,
  "created_at"        timestamp with time zone NOT NULL DEFAULT clock_timestamp(),
  "updated_at"        timestamp with time zone NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT "rooms_check1" CHECK (((phase <> ALL (ARRAY['playing'::text, 'voting'::text, 'finished'::text])) OR ((match_id IS NOT NULL) AND (spy_id IS
    NOT NULL) AND (secret_word IS NOT NULL)))),
  CONSTRAINT "rooms_check2" CHECK ((((phase = 'finished'::text) = (winner IS NOT NULL)) OR (phase = 'closed'::text))),
  CONSTRAINT "rooms_check" CHECK (((phase <> 'lobby'::text) OR ((match_id IS NULL) AND (spy_id IS NULL) AND (secret_word IS NULL) AND (winner IS NULL)))),
  CONSTRAINT "rooms_phase_check" CHECK ((phase = ANY (ARRAY['lobby'::text, 'playing'::text, 'voting'::text, 'finished'::text, 'closed'::text]))),
  CONSTRAINT "rooms_pkey" PRIMARY KEY (id),
  CONSTRAINT "rooms_revision_check" CHECK ((revision >= 0)),
  CONSTRAINT "rooms_settings_check1" CHECK (((((settings ->> 'max_players'::text))::integer >= 3) AND (((settings ->> 'max_players'::text))::integer <= 12))),
  CONSTRAINT "rooms_settings_check" CHECK ((jsonb_typeof(settings) = 'object'::text)),
  CONSTRAINT "rooms_settings_revision_check" CHECK ((settings_revision >= 1)),
  CONSTRAINT "rooms_winner_check" CHECK ((winner = ANY (ARRAY['civilians'::text, 'spies'::text])))
);

ALTER TABLE "game_private"."rooms"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "game_private"."votes" (
  "room_id"    uuid                     NOT NULL,
  "match_id"   uuid                     NOT NULL,
  "voter_id"   uuid                     NOT NULL,
  "target_id"  uuid                     NOT NULL,
  "created_at" timestamp with time zone NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT "votes_check" CHECK ((voter_id <> target_id)),
  CONSTRAINT "votes_pkey" PRIMARY KEY (room_id, match_id, voter_id)
);

ALTER TABLE "game_private"."votes"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."game_room_signals" (
  "room_id"    uuid                     NOT NULL,
  "revision"   bigint                   NOT NULL,
  "changed_at" timestamp with time zone NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT "game_room_signals_pkey" PRIMARY KEY (room_id),
  CONSTRAINT "game_room_signals_revision_check" CHECK ((revision >= 0))
);

ALTER TABLE "public"."game_room_signals"
  ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE "public"."game_room_signals" FROM "anon", "service_role";

CREATE OR REPLACE FUNCTION game_private.can_read_room (
  p_room_id uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select auth.uid() is not null and exists (
    select 1 from game_private.players p
    where p.room_id = p_room_id and p.user_id = auth.uid() and p.active
  );
$function$;

CREATE OR REPLACE FUNCTION game_private.command_impl (
  p_request_id uuid,
  p_room_id    uuid,
  p_action     text,
  p_payload    jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  SET lock_timeout TO '5s'
  AS $function$
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

    if p_action in ('set_ready', 'leave_room') and
      game_private.payload_uuid(p_payload, 'membership_id') <> v_member.membership_id then
      raise exception using errcode = 'P0001', message = 'stale_membership';
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
$function$;

CREATE OR REPLACE FUNCTION game_private.payload_uuid (
  p_payload jsonb,
  p_key     text
)
  RETURNS uuid
  LANGUAGE plpgsql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION game_private.reconcile_vote (
  p_room_id uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION game_private.snapshot_impl (
  p_room_id uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION game_private.validate_keys (
  p_payload jsonb,
  p_allowed text[]
)
  RETURNS void
  LANGUAGE plpgsql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
begin
  if p_payload is null or pg_catalog.jsonb_typeof(p_payload) <> 'object'
    or pg_catalog.octet_length(p_payload::text) > 4096
    or exists (select 1 from pg_catalog.jsonb_object_keys(p_payload) as k(key)
      where not (k.key = any(p_allowed))) then
    raise exception using errcode = 'P0001', message = 'invalid_payload';
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION game_private.validate_name (
  p_payload jsonb
)
  RETURNS text
  LANGUAGE plpgsql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION game_private.validate_settings (
  p_settings jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.game_command (
  p_request_id uuid,
  p_room_id    uuid,
  p_action     text,
  p_payload    jsonb DEFAULT '{}'::jsonb
)
  RETURNS jsonb
  LANGUAGE sql
  SET search_path TO ''
  AS $function$ select game_private.command_impl(p_request_id, p_room_id, p_action, p_payload); $function$;

REVOKE ALL ON FUNCTION "public"."game_command"(uuid, uuid, text, jsonb) FROM PUBLIC, "anon", "service_role";

CREATE OR REPLACE FUNCTION public.game_snapshot (
  p_room_id uuid
)
  RETURNS jsonb
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$ select game_private.snapshot_impl(p_room_id); $function$;

REVOKE ALL ON FUNCTION "public"."game_snapshot"(uuid) FROM PUBLIC, "anon", "service_role";

ALTER TABLE "game_private"."players"
  ADD CONSTRAINT "players_room_id_fkey" FOREIGN KEY (room_id) REFERENCES game_private.rooms(id) ON DELETE CASCADE;

ALTER TABLE "game_private"."votes"
  ADD CONSTRAINT "votes_room_id_fkey" FOREIGN KEY (room_id) REFERENCES game_private.rooms(id) ON DELETE CASCADE;

ALTER TABLE "game_private"."votes"
  ADD CONSTRAINT "votes_room_id_target_id_fkey" FOREIGN KEY (room_id, target_id) REFERENCES game_private.players(room_id, user_id);

ALTER TABLE "game_private"."votes"
  ADD CONSTRAINT "votes_room_id_voter_id_fkey" FOREIGN KEY (room_id, voter_id) REFERENCES game_private.players(room_id, user_id);

ALTER TABLE "public"."game_room_signals"
  ADD CONSTRAINT "game_room_signals_room_id_fkey" FOREIGN KEY (room_id) REFERENCES game_private.rooms(id) ON DELETE CASCADE;

CREATE INDEX players_active_actor ON game_private.players USING btree (user_id, room_id)
  WHERE active;

CREATE INDEX votes_room_target ON game_private.votes USING btree (room_id, target_id);

CREATE INDEX votes_room_voter ON game_private.votes USING btree (room_id, voter_id);

CREATE POLICY "member_read_signal" ON "public"."game_room_signals"
  FOR SELECT
  TO "authenticated"
  USING (game_private.can_read_room(room_id));

ALTER PUBLICATION "supabase_realtime" ADD TABLE "public"."game_room_signals";

REVOKE ALL ON FUNCTION "game_private"."can_read_room"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "game_private"."can_read_room"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "game_private"."command_impl"(uuid, uuid, text, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "game_private"."command_impl"(uuid, uuid, text, jsonb) TO "authenticated";

REVOKE ALL ON FUNCTION "game_private"."payload_uuid"(jsonb, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."reconcile_vote"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."snapshot_impl"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "game_private"."snapshot_impl"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "game_private"."validate_keys"(jsonb, text[]) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."validate_name"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "game_private"."validate_settings"(jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."game_command"(uuid, uuid, text, jsonb) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."game_command"(uuid, uuid, text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."game_command"(uuid, uuid, text, jsonb) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."game_snapshot"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."game_snapshot"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."game_snapshot"(uuid) TO "postgres";

GRANT USAGE ON SCHEMA "game_private" TO "authenticated";

REVOKE ALL ON TABLE "public"."game_room_signals" FROM "authenticated";

GRANT SELECT ON TABLE "public"."game_room_signals" TO "authenticated";

REVOKE ALL ON TABLE "public"."game_room_signals" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."game_room_signals" TO "postgres";


-- Explicit privilege contract, independent of the deployment platform's
-- default grants. pg-delta does not emit the source's default-privilege fence.
revoke all on schema game_private from public, anon, authenticated, service_role;
grant usage on schema game_private to authenticated;
alter default privileges in schema game_private revoke execute on functions from public;
revoke all on all tables in schema game_private from public, anon, authenticated, service_role;
revoke all on all functions in schema game_private from public, anon, authenticated, service_role;
grant execute on function game_private.can_read_room(uuid) to authenticated;
grant execute on function game_private.command_impl(uuid, uuid, text, jsonb) to authenticated;
grant execute on function game_private.snapshot_impl(uuid) to authenticated;
revoke all on public.game_room_signals from public, anon, authenticated, service_role;
grant select on public.game_room_signals to authenticated;
revoke all on function public.game_command(uuid, uuid, text, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.game_snapshot(uuid) from public, anon, authenticated, service_role;
grant execute on function public.game_command(uuid, uuid, text, jsonb) to authenticated;
grant execute on function public.game_snapshot(uuid) to authenticated;
