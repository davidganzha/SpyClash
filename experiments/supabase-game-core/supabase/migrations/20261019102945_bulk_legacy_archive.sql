-- Operator-only migration staging and immutable, lossless source snapshots.
-- No application role has access and no verified identity links are created here.
create table if not exists app_private.bulk_migration_rows (
  source_key text not null,
  entity text not null,
  source_id text not null,
  source_digest text not null,
  target_id uuid,
  disposition text not null,
  imported_at timestamptz not null default clock_timestamp(),
  primary key(source_key,entity,source_id)
);
create table if not exists app_private.bulk_migration_jobs (
  id uuid primary key,
  source_key text not null,
  source_digest text not null check(source_digest ~ '^[0-9a-f]{64}$'),
  source_content_digest text not null check(source_content_digest ~ '^[0-9a-f]{64}$'),
  source_attested_digest text,
  source_attested_at timestamptz,
  plan_digest text not null check(plan_digest ~ '^[0-9a-f]{64}$'),
  token_digest text not null check(token_digest ~ '^[0-9a-f]{64}$'),
  token_expires_at timestamptz not null,
  payload jsonb not null,
  status text not null default 'ready' check(status in ('ready','reserved','provisioning','applied','rolled_back')),
  lease_id uuid,
  lease_until timestamptz,
  rollback_journal jsonb,
  summary jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  applied_at timestamptz,
  check ((lease_id is null) = (lease_until is null))
);
create table if not exists app_private.bulk_migration_archive (
  job_id uuid not null references app_private.bulk_migration_jobs(id),
  source_key text not null,
  entity text not null,
  source_id text not null,
  source_digest text not null,
  payload jsonb not null,
  disposition text not null,
  target_id uuid,
  reason text not null,
  archived_at timestamptz not null default clock_timestamp(),
  primary key(job_id,entity,source_id)
);
alter table app_private.bulk_migration_rows enable row level security;
alter table app_private.bulk_migration_jobs enable row level security;
alter table app_private.bulk_migration_archive enable row level security;
revoke all on app_private.bulk_migration_rows, app_private.bulk_migration_jobs, app_private.bulk_migration_archive from public,anon,authenticated;
