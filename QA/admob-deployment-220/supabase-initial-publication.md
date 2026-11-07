# Supabase publication receipt — 219

Executed on 2026-11-07 after explicit approval to publish Supabase/Base44 server
support and connect AdMob verification while keeping ads and new limits disabled.
Only the Supabase portion was performed by this agent.

## Preflight

- All 85 frozen candidate-file hashes and its manifest hash matched.
- A fresh management readback returned app-services v17, JWT verification enabled.
- All 68 live source-file SHA256s matched the reviewed baseline; no drift.
- Reward table/charge-source column and reward migration were absent.

## Applied

- Exact SQL from `20261105224817_rewarded_generation_credits.sql`, registered by
  the migration tool as `20261107190551_rewarded_generation_credits`.
- `SPYCLASH_REWARDED_GENERATION_ENABLED=false` and the approved owned rewarded
  unit. CLI readback SHA256 digests matched both approved values; no other secret
  values were printed or recorded.
- Minimal app-services package: active v19, `verify_jwt=true`.
- New rewarded-generation-ssv: active v1, `verify_jwt=false`, authenticating
  Google's signed callback independently.
- No other function deployment, auth setting change, generation request, issued
  attempt, or reward grant was performed.

## Verified

- All 72 returned app-services source files and 10 gateway dependency/source
  files exactly match the frozen candidate (see published-source-sha256.json).
- Private reward table exists with RLS, anon/authenticated access denied,
  charge_source defaults to legacy, and issued attempt count remains zero.
- Unsigned callback: HTTP400 invalid_reward_signature.
- app-services without Authorization: HTTP401 UNAUTHORIZED_NO_AUTH_HEADER.
- Other function bundle hashes, entrypoint paths, timestamps and JWT settings
  remained unchanged. Their version counters increased by one after the project
  secret update; only the two approved functions received deployment calls.
- Security advisors found the expected INFO for RLS without policies on the new
  server-only table. Its client grants are explicitly revoked. No new table WARN
  or ERROR was reported. The unrelated leaked-password-protection Auth warning
  was recorded without changing Auth configuration.

The root agent subsequently tested AdMob's dashboard URL verification using only
reserved non-account markers. Delivery reached this function and returned400.
Sanitized log fields: synthetic ad_unit1234567890, reward1 generation, both expected
test markers matched. The strict production handler deliberately rejected this
unissued token; no credit was created. Completing the dashboard handshake needs
the separately reviewed signed, no-credit setup response. This receipt describes
the strict v1 endpoint, not that subsequent adjustment.

Advisory references:
- https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy
- https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection
