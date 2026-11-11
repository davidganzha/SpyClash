-- Persist per-account adoption of a supported rewarded-generation client. This
-- does not enable production quotas: the global rollout switch remains off.
-- Client capability may opt into stricter limits, never opt back out.
create table if not exists game_center_private.generation_reward_enrollments (
  user_id uuid primary key references game_center_private.accounts(user_id) on delete cascade,
  provider text not null check (provider = 'unity'),
  client_build integer not null check (client_build >= 228),
  enrolled_at timestamptz not null default clock_timestamp()
);
alter table game_center_private.generation_reward_enrollments enable row level security;
revoke all on game_center_private.generation_reward_enrollments from public, anon, authenticated;
