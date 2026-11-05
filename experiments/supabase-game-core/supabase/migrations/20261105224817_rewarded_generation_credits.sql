-- Server-only reward claims and credit reservations. Deploying this schema does
-- not enable ads or change quota: SPYCLASH_REWARDED_GENERATION_ENABLED defaults off.
create table if not exists game_center_private.generation_reward_attempts (
  user_id uuid not null references game_center_private.accounts(user_id),
  attempt_id uuid not null,
  custom_data text not null unique,
  ad_unit_id text not null,
  state text not null default 'pending' check(state in ('pending','earned')),
  transaction_id text unique,
  reward_at timestamptz,
  consumed_request_id uuid,
  created_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null default clock_timestamp()+interval '24 hours',
  primary key(user_id,attempt_id),
  unique(user_id,consumed_request_id),
  check((state='earned') = (transaction_id is not null)),
  check((state='earned') = (reward_at is not null)),
  check(consumed_request_id is null or state='earned')
);
create index if not exists generation_reward_available on game_center_private.generation_reward_attempts(user_id,created_at)
  where state='earned' and consumed_request_id is null;
alter table game_center_private.generation_reward_attempts enable row level security;
revoke all on game_center_private.generation_reward_attempts from public,anon,authenticated;
alter table game_center_private.generation_requests add column if not exists charge_source text not null default 'legacy';
alter table game_center_private.generation_requests drop constraint if exists generation_charge_source_check;
alter table game_center_private.generation_requests add constraint generation_charge_source_check
  check(charge_source in ('legacy','free','bonus','unlimited'));
