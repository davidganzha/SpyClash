-- Full original-game protocol. Only the verified Edge service owns raw state.
-- The original reduced experiment remains independent for regression tests.
create schema if not exists full_game_private;
revoke all on schema full_game_private from public, anon, authenticated;

create table if not exists full_game_private.rooms (
  id uuid primary key,
  code text not null unique check (code ~ '^[A-Z0-9]{6}$'),
  revision bigint not null default 0 check (revision >= 0),
  state jsonb not null check (jsonb_typeof(state) = 'object'),
  closed boolean not null default false,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);
create table if not exists full_game_private.members (
  room_id uuid not null references full_game_private.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  membership_id uuid not null,
  primary key (room_id, user_id)
);
create index if not exists full_game_members_actor on full_game_private.members(user_id, room_id);

create table if not exists full_game_private.receipts (
  actor_id uuid not null references auth.users(id) on delete cascade,
  request_id uuid not null,
  request_hash text not null,
  room_id uuid,
  revision bigint,
  status integer not null,
  response jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key (actor_id, request_id)
);
create table if not exists full_game_private.history (
  match_id uuid not null,
  player_id uuid not null references auth.users(id) on delete cascade,
  room_id uuid not null references full_game_private.rooms(id),
  result jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key (match_id, player_id)
);
create index if not exists full_game_history_actor on full_game_private.history(player_id, created_at desc);
create index if not exists full_game_history_room on full_game_private.history(room_id);
create table if not exists full_game_private.outbox (
  id text primary key,
  room_id uuid not null references full_game_private.rooms(id),
  event jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  delivered_at timestamptz
);
create index if not exists full_game_outbox_room on full_game_private.outbox(room_id);
create table if not exists full_game_private.word_packs (
  id uuid primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  pack jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);
create index if not exists full_game_word_packs_owner on full_game_private.word_packs(owner_id, created_at desc);

-- Installation-local pseudonym key. Generated inside Postgres and never exposed
-- through Auth, the Data API, migrations, function logs, or client bundles.
create table if not exists full_game_private.configuration (
  key text primary key,
  value text not null
);
insert into full_game_private.configuration(key, value)
values ('leaderboard_pseudonym', gen_random_uuid()::text || gen_random_uuid()::text)
on conflict(key) do nothing;

alter table full_game_private.rooms enable row level security;
alter table full_game_private.members enable row level security;
alter table full_game_private.receipts enable row level security;
alter table full_game_private.history enable row level security;
alter table full_game_private.outbox enable row level security;
alter table full_game_private.word_packs enable row level security;
alter table full_game_private.configuration enable row level security;
revoke all on all tables in schema full_game_private from public, anon, authenticated;

create table if not exists public.full_game_room_signals (
  room_id uuid primary key references full_game_private.rooms(id) on delete cascade,
  revision bigint not null check (revision >= 0),
  updated_at timestamptz not null default clock_timestamp()
);
alter table public.full_game_room_signals enable row level security;
revoke all on public.full_game_room_signals from public, anon, authenticated;
grant select on public.full_game_room_signals to authenticated;

-- The narrowly scoped membership predicate is the only privileged SQL helper.
-- It returns a boolean, never game state or roles, and binds to auth.uid().
create or replace function full_game_private.is_member(p_room_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from full_game_private.members m
    where m.room_id = p_room_id and m.user_id = auth.uid()
  );
$$;
revoke all on function full_game_private.is_member(uuid) from public, anon, authenticated;
grant usage on schema full_game_private to authenticated;
grant execute on function full_game_private.is_member(uuid) to authenticated;
drop policy if exists full_game_signal_member on public.full_game_room_signals;
create policy full_game_signal_member on public.full_game_room_signals
for select to authenticated using (full_game_private.is_member(room_id));

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'full_game_room_signals'
     ) then
    alter publication supabase_realtime add table public.full_game_room_signals;
  end if;
end $$;
