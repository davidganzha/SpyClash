-- Private durable provider claims. No raw-input columns or exclusion list are
-- stored here; the generated result's category can contain the submitted theme.
-- Deleting a generation request erases both its completed result and every claim.
create table if not exists game_center_private.generation_provider_calls (
  user_id uuid not null,
  request_id uuid not null,
  call_index smallint not null check(call_index in (0,1)),
  input_hash text not null check(input_hash ~ '^[0-9a-f]{64}$'),
  lease_id uuid not null,
  claim_id uuid,
  state text not null check(state in ('prepared','started','complete')),
  result jsonb,
  result_hash text check(result_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  primary key(user_id,request_id,call_index),
  foreign key(user_id,request_id) references game_center_private.generation_requests(user_id,request_id) on delete cascade,
  check((state='prepared') = (claim_id is null)),
  check((state='complete') = (result is not null)),
  check((result is null) = (result_hash is null))
);
alter table game_center_private.generation_provider_calls enable row level security;
revoke all on game_center_private.generation_provider_calls from public, anon, authenticated;
