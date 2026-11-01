-- A signed relay failure is terminal for this provider claim. Keep its charge:
-- an upstream failure does not prove that paid work never ran.
alter table game_center_private.generation_provider_calls
  add column if not exists error_code text;
alter table game_center_private.generation_provider_calls
  drop constraint if exists generation_provider_calls_state_check;
alter table game_center_private.generation_provider_calls
  add constraint generation_provider_calls_state_check
  check(state in ('prepared','started','complete','failed'));
alter table game_center_private.generation_provider_calls
  drop constraint if exists generation_provider_calls_failure_check;
alter table game_center_private.generation_provider_calls
  add constraint generation_provider_calls_failure_check
  check((state='failed' and error_code is not null and error_code in ('provider_failed','quality_failed'))
    or (state<>'failed' and error_code is null));
-- Existing result/claim constraints, private-schema RLS and grants remain intact.
