-- Read-only Base44 snapshots are imported only after immutable identity verification.
-- Provenance survives local edits/deletion so another login cannot resurrect content.
create table if not exists app_private.legacy_import_runs (
  user_id uuid not null, source_key text not null, legacy_user_id text not null,
  profile_applied boolean not null default false,
  status text not null default 'pending' check(status in ('pending','complete')),
  history_cursor jsonb not null default '{"phase":"stable","skip":0}',
  social_status text not null default 'deferred_verified_export_required',
  membership_snapshot jsonb, membership_checked_at timestamptz,
  last_import_at timestamptz not null default clock_timestamp(),
  primary key(user_id,source_key)
);
create table if not exists app_private.legacy_import_rows (
  user_id uuid not null, source_key text not null, entity text not null,
  source_id text not null, source_digest text not null, target_id uuid,
  imported_at timestamptz not null default clock_timestamp(),
  primary key(source_key,entity,source_id),
  check(entity in ('User','WordPack','GameHistory'))
);
create index if not exists legacy_import_rows_owner on app_private.legacy_import_rows(user_id);
create table if not exists app_private.legacy_import_history_stage (
  user_id uuid not null, source_key text not null, source_id text not null,
  data jsonb not null, primary key(user_id,source_key,source_id)
);
create table if not exists app_private.legacy_pending_social (
  owner_id uuid not null, source_key text not null, source_id text not null,
  entity text not null check(entity in ('Friendship','ProfileComment')),
  peer_legacy_id text not null, source_digest text not null, data jsonb not null,
  state text not null default 'awaiting_identity_mapping' check(state in ('awaiting_identity_mapping','ready_for_review','applied')),
  captured_at timestamptz not null, primary key(owner_id,source_key,entity,source_id)
);
create index if not exists legacy_pending_social_peer on app_private.legacy_pending_social(source_key,peer_legacy_id);
-- Historical provider results have no playable Supabase room. Do not fabricate one.
alter table full_game_private.history alter column room_id drop not null;
alter table app_private.legacy_import_runs enable row level security;
alter table app_private.legacy_import_rows enable row level security;
alter table app_private.legacy_import_history_stage enable row level security;
alter table app_private.legacy_pending_social enable row level security;
revoke all on app_private.legacy_import_runs,app_private.legacy_import_rows,app_private.legacy_import_history_stage,app_private.legacy_pending_social from public,anon,authenticated;
