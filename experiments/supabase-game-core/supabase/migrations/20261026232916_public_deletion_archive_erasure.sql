-- Capability-verified selectors are stored only until archive erasure commits.
alter table app_private.main_account_deletions add column if not exists erasure_proof jsonb not null default '{}'::jsonb;
