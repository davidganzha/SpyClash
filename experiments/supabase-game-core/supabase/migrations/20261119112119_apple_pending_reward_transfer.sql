-- Exact source-fenced reward capabilities only. The source record remains
-- transferred, so old callback CAS/spend queries cannot create a second credit.
create table apple_private.reward_attempt_aliases (
  custom_data text primary key,
  source_record_id text not null unique,
  legacy_user_id text not null,
  user_id uuid not null references apple_private.accounts(user_id),
  attempt_id uuid not null,
  transfer_id uuid not null,
  source_state text not null check(source_state in ('pending','earned','spent')),
  created_at timestamptz not null default clock_timestamp(),
  unique(user_id,attempt_id),
  foreign key(user_id,attempt_id) references game_center_private.generation_reward_attempts(user_id,attempt_id) on delete cascade,
  check(custom_data ~ '^[0-9a-f-]{36}\.legacy\.[0-9a-f]{64}$')
);
alter table apple_private.reward_attempt_aliases enable row level security;
revoke all on apple_private.reward_attempt_aliases from public,anon,authenticated;
