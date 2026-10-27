# Combined public backend: configuration review

This is a deployment plan, not an execution record. The signed App Store client remains build 200. The machine-readable inputs are in `PUBLIC-BACKEND-CONFIG-201.json`; all private values are null placeholders with named sources. Existing legacy billing configuration must be preserved, and `APP_BILLING_PROVIDER` must remain `base44` globally. Only the private Game Center account mapping selects native billing per request.

The exact public overlay has four additive domain migrations, three Supabase functions (`app-services`, `full-game-core`, `game-center-session`), two Base44 functions (`deleteAccount`, `nativeGameCenterWordPack`) and one private receipt entity. Use the reviewed package's hashes and paths, not a whole-project Base44 deployment. The existing billing webhooks, legacy-session function, main game engine, push delivery and live-activity behavior remain outside this change.

## Credentials and public trust

Game Center requires no private Apple key. Its fixed main-bundle assertion verifier includes its own pinned DigiCert trust material. The three Apple roots used by App Store transaction verification are separate; Apple documents providing the root certificates to `SignedDataVerifier`. [Apple server library](https://github.com/apple/app-store-server-library-node), [Apple PKI](https://www.apple.com/certificateauthority/).

Downloaded public DER certificates and their SHA256/expiry metadata are under `.local/public-backend-preflight/apple-roots`. `app-iap-root-certificates.json` is the exact public JSON/base64 value for `APP_IAP_ROOT_CERTIFICATES_JSON`. The template records each official source URL and hash, so this artifact is reproducible.

`APP_IAP_PRIVATE_KEY_P8` uses the existing local `AuthKey_C9Z2RND4TQ.p8` as raw PEM, with issuer `d48e471d-8458-4c67-b18b-cadcfe0bd7de`. No key contents are in this plan. Accepted production/sandbox API authentication was established by synthetic transaction lookups returning `4040010`, while a deliberately invalid signature returned 401. This verifies API credentials, not a real purchase, restoration or subscription entitlement. Keep bundle `com.spyclash.ios`, App Apple ID `6793534085`, product `com.spyclash.ios.limitless.weekly`, and explicit `SandboxAndProduction` verification.

New independent server secrets have separate purposes: AI relay HMAC, archive-proof HMAC, durable deletion-receipt recovery, and maintenance authorization. The first two are shared with their narrow Base44 counterparts. Do not copy a Supabase service-role key, historical pseudonym key, encryption key, user bearer or OpenAI key across services. Base44's AI callback uses the existing **public legacy anon JWT** only to pass the Supabase gateway; HMAC and a durable private claim authorize the actual work. Its JWT must say role `anon` and project ref `bbkfsgnordtdiblgdzkg`.

## Exact activation sequence

1. Obtain approval for the complete public package, the two specified Base44 functions/entity, named server configuration and the maintenance setup below. These additions expand the earlier main Game Center configuration scope.
2. Re-read live function versions/hashes and the package manifest. Apply the four listed private migrations in order. Deploy the prepared Base44 entity/functions and the three Supabase functions with the new feature flags still disabled. Preserve gateway checks for app-services/core; Game Center uses its own Apple proof before a session exists.
3. Bind the existing IAP key, public Apple roots, and independent new server secrets from the template. Configure the Base44 public anon JWT for AI callbacks. No OpenAI account/key is needed for `base44-managed`.
4. Verify the historical Apple selector key with the signed **read-only** `deletion_archive_probe` before setting `APP_DELETION_ARCHIVE_KEY_VERIFIED=true`. Follow the exact immutable-owner/positive-match/coverage procedure in `PUBLIC-ACCOUNT-DELETION-SERVER-201.md`. A successful probe HTTP status alone is insufficient.
5. Set up and verify the maintenance runner. Then enable the Game Center/IAP/managed AI/full-deletion gates from the template's activation section. Native accounts receive free limits of ten AI generations per UTC day and five history entries; signed owned Apple transactions unlock benefits. Canonical Apple status is refreshed before premium-consuming operations when older than 60 seconds.
6. Read back migrations, source hashes and configuration names, run advisors, and perform negative unauthenticated/forged-proof probes. Actual Game Center sign-in, sandbox purchase/restore, one managed AI invocation and ordinary-account deletion need their own real acceptance evidence; local fixture tests do not establish those outcomes.

## Maintenance: confirmed absence and minimal setup

Read-only inspection on 2026-10-27 found no `APP_WORKER_SECRET`, no installed `pg_cron`/`pg_net`, an empty Vault, no tracked external schedule and no maintenance-log matches during the preceding 24 hours. No authenticated existing runner is established. Available versions were pg_cron 1.6.4 and pg_net 0.20.4; Vault 0.3.1 already exists. Both extensions are already in shared_preload_libraries, so this plan does not require changing preload configuration or planning a database restart.

The self-contained option adds **two extensions and one scheduled HTTP job**, separately from the four domain migrations. Supabase documents pg_cron + pg_net + Vault for scheduled Edge calls. This application retains its existing JWT gateway and additionally requires its private worker header; do not copy the documentation's newer `verify_jwt=false` setup into this endpoint. [Scheduling Edge Functions](https://supabase.com/docs/guides/functions/schedule-functions).

After approval, enable pg_cron/pg_net and store only `spyclash_gateway_anon_jwt` and `spyclash_worker_secret` in Vault. The latter equals the Edge `APP_WORKER_SECRET`. Ensure public/anon/authenticated roles cannot read Vault or the net request queue, where queued headers exist temporarily. The queue's public credential is insufficient without the worker secret. Do not put a service-role credential in this schedule. [pg_net documentation](https://supabase.com/docs/guides/database/extensions/pg_net).

The complete review-only install/readback template is `PUBLIC-MAINTENANCE-201.sql`; it contains no secret literals and validates the Vault anon JWT scope before scheduling. The reviewed schedule is one job named `spyclash-account-maintenance`, every minute, with this fixed statement:

```sql
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
```

No new nonce table is necessary: the route has independent secret authentication and existing per-job leases/idempotent receipts. Each run handles at most three original-account deletion intents and three Auth cleanup jobs. Preserve push flags; setting up this runner is not permission to enable push delivery. AI relay claims and on-demand Apple status checks do not require a new schedule.

Before the first authorized no-work HTTP check, confirm there are no unexpected pending deletion jobs. Test a wrong worker header (401), then the correct header on the empty queue (200). Verify at least two scheduled HTTP responses, not merely successful SQL enqueueing: inspect only response status/timing/error fields and the bounded maintenance counters. Do not dump request headers or Vault decrypted values. The request timeout is explicit because pg_net otherwise defaults to two seconds. [pg_net reference](https://supabase.com/docs/guides/database/extensions/pg_net).

Real lost-acknowledgement recovery must use a separately authorized disposable ordinary account. Never remove or revoke the installed QA account/session merely to clean up verification evidence.
