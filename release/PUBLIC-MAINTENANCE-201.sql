-- REVIEW ONLY. No production execution is recorded by this file.
-- Execute ONLY against Supabase project bbkfsgnordtdiblgdzkg after approval.
-- Prerequisites: reviewed public app-services deployed, APP_WORKER_SECRET set,
-- and Vault entries inserted separately through the approved secret channel:
--   spyclash_worker_secret      = same private APP_WORKER_SECRET (>=32 chars)
--   spyclash_gateway_anon_jwt   = main project's PUBLIC legacy anon JWT
-- No service-role credential, private key or secret literal belongs here.
-- REQUIRED EXTERNAL PREFLIGHT BEFORE EXECUTION (SQL cannot verify API settings):
-- 1. Read hosted Data API schemas: exactly public,graphql_public. Check a public
--    anon request with Accept-Profile: net is rejected with PGRST106 (limit 0;
--    never select headers/body). Check API/GraphQL search paths also exclude net.
-- 2. Review exposed RPCs/views and their reachable callees: no net reader or
--    arbitrary SQL bridge. Recheck if enabling GraphQL or changing API schemas.
-- 3. Review every LOGIN role/credential holder; only trusted infrastructure and
--    administrators may connect directly. The worker header is visible to them.
-- Hosted pg_net is owned by supabase_admin and has platform PUBLIC grants.
-- postgres cannot revoke those grants or add RLS; this script does not try.
-- Vault protects secrets at rest, not their temporary decrypted queue headers.
-- See https://supabase.com/kb/troubleshooting/revoking-access-to-pg_net-objects-has-no-effect
-- and https://supabase.com/kb/troubleshooting/database-roles-can-read-request-headers-queued-by-pg_net

begin;

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

-- Fail closed on the SQL-verifiable part of the supported access boundary.
-- These guards do not replace the external API/RPC/LOGIN-role review above.
do $access$
begin
  if (select count(*) from pg_roles where rolname in ('anon','authenticated','service_role')) <> 3
    or exists(select 1 from pg_roles where rolname in ('anon','authenticated','service_role') and rolcanlogin) then
    raise exception 'maintenance_client_roles_must_be_nologin';
  end if;
  if to_regclass('vault.secrets') is null or to_regclass('vault.decrypted_secrets') is null then
    raise exception 'maintenance_vault_schema_missing';
  end if;
  if exists(
    select 1 from pg_namespace n,
      lateral aclexplode(coalesce(n.nspacl,acldefault('n',n.nspowner))) a
    where n.nspname='vault' and a.grantee=0
  ) or exists(
    select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace,
      lateral aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a
    where n.nspname='vault' and c.relkind in ('r','v','m','p','f') and a.grantee=0
  ) or exists(
    select 1 from pg_roles r
    where r.rolname in ('anon','authenticated')
      and (has_schema_privilege(r.oid,'vault','USAGE') or has_schema_privilege(r.oid,'vault','CREATE'))
  ) or exists(
    select 1 from pg_roles r cross join pg_class c join pg_namespace n on n.oid=c.relnamespace
    where r.rolname in ('anon','authenticated') and n.nspname='vault' and c.relkind in ('r','v','m','p','f')
      and (has_table_privilege(r.oid,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
        or has_any_column_privilege(r.oid,c.oid,'SELECT,INSERT,UPDATE,REFERENCES'))
  ) then
    raise exception 'maintenance_vault_client_access_detected';
  end if;
end
$access$;

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
  if worker_value is null or length(worker_value)<32 then raise exception 'maintenance_worker_secret_invalid'; end if;
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
