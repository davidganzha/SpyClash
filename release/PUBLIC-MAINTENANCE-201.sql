-- REVIEW ONLY. No production execution is recorded by this file.
-- Execute ONLY against Supabase project bbkfsgnordtdiblgdzkg after approval.
-- Prerequisites: reviewed public app-services deployed, APP_WORKER_SECRET set,
-- and Vault entries inserted separately through the approved secret channel:
--   spyclash_worker_secret      = same private APP_WORKER_SECRET (>=32 chars)
--   spyclash_gateway_anon_jwt   = main project's PUBLIC legacy anon JWT
-- No service-role credential, private key or secret literal belongs here.

begin;

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

-- HTTP request headers exist briefly in the queue. Preserve only owner/internal
-- access; ordinary API roles must not acquire the private worker credential.
revoke all on schema net from public, anon, authenticated;
revoke all on all tables in schema net from public, anon, authenticated;
revoke all on schema vault from public, anon, authenticated;
revoke all on all tables in schema vault from public, anon, authenticated;

do $readiness$
declare
  worker_value text;
  gateway_value text;
  encoded_payload text;
  claims jsonb;
begin
  if (select count(*) from vault.secrets where name='spyclash_worker_secret') <> 1
    or (select count(*) from vault.secrets where name='spyclash_gateway_anon_jwt') <> 1 then
    raise exception 'maintenance_vault_configuration_missing';
  end if;
  select decrypted_secret into worker_value from vault.decrypted_secrets where name='spyclash_worker_secret';
  select decrypted_secret into gateway_value from vault.decrypted_secrets where name='spyclash_gateway_anon_jwt';
  if length(worker_value)<32 then raise exception 'maintenance_worker_secret_invalid'; end if;
  encoded_payload := split_part(gateway_value,'.',2);
  begin
    claims := convert_from(decode(translate(encoded_payload,'-_','+/') || repeat('=',(4-length(encoded_payload)%4)%4),'base64'),'UTF8')::jsonb;
  exception when others then
    raise exception 'maintenance_gateway_token_invalid';
  end;
  if claims->>'role' is distinct from 'anon'
    or claims->>'ref' is distinct from 'bbkfsgnordtdiblgdzkg' then
    raise exception 'maintenance_gateway_scope_invalid';
  end if;
end
$readiness$;

select cron.schedule(
  'spyclash-account-maintenance',
  '* * * * *',
  $job$
    select net.http_post(
      url := 'https://bbkfsgnordtdiblgdzkg.supabase.co/functions/v1/app-services/maintenance',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='spyclash_gateway_anon_jwt'),
        'apikey', (select decrypted_secret from vault.decrypted_secrets where name='spyclash_gateway_anon_jwt'),
        'x-spyclash-worker', (select decrypted_secret from vault.decrypted_secrets where name='spyclash_worker_secret')
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 90000
    );
  $job$
);

commit;

-- Read-back only: do not SELECT decrypted secrets or queued request headers.
select jobname,schedule,active from cron.job where jobname='spyclash-account-maintenance';
select j.jobname,r.status,r.start_time,r.end_time
from cron.job_run_details r join cron.job j on j.jobid=r.jobid
where j.jobname='spyclash-account-maintenance'
order by r.start_time desc limit 5;
-- SQL enqueue success is not HTTP success. Correlate returned request IDs with
-- net._http_response and read only status_code,timed_out,error_msg,created.
-- Pause/unschedule only this exact job if its readiness verification fails.
