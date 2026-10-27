# Native Game Center managed AI relay

Local implementation only. Deploying code, applying migrations or setting
production secrets requires approval for those exact actions. This change does
not create a Base44 user or change existing Base44 generation/billing flows.

## Fixed scope and deployment inputs

- Supabase project: `bbkfsgnordtdiblgdzkg`.
- Base44 app: `69a0e57fa939f578082f8091`, `spyclash.com`.
- Base44 function: `base44/functions/nativeGameCenterWordPack`, entry `main.ts`.
  All imports are contained in that folder. The existing canonical prompt and
  quality helpers are copied unchanged and checked byte-for-byte by tests.
- Existing Supabase `app-services` adds `/native-ai-relay/claim` and
  `/native-ai-relay/complete`. Keep its gateway `verify_jwt=true`.
- Additive migration after native GC identity:
  `20261026234309_native_game_center_ai_relay.sql`. It creates one RLS-enabled
  private table with no public/anon/authenticated access. No public RPC is added.

Required Supabase server configuration:

```
APP_NATIVE_GAME_CENTER_AI_ENABLED=true
APP_NATIVE_GAME_CENTER_AI_PROVIDER=base44-managed
SPYCLASH_NATIVE_AI_RELAY_SECRET=<fresh random 32-byte secret encoded as 64 lowercase hex>
```

Required Base44 server configuration for the relay:

```
SPYCLASH_NATIVE_AI_RELAY_SECRET=<the same server-only secret>
SPYCLASH_NATIVE_AI_RELAY_ANON_KEY=<main project's public legacy anon JWT>
```

The public anon JWT is only for the existing Supabase gateway: its payload must
have role `anon` and ref `bbkfsgnordtdiblgdzkg`. A service-role JWT is rejected.
No Supabase service-role key, Base44 user token, OpenAI key or Apple key is sent
across the relay. Rotate the HMAC secret on both servers together. Disabling
`APP_NATIVE_GAME_CENTER_AI_ENABLED` closes both generation and callback routes.

Main provider calls go only to the fixed Base44 URL and fixed callback URL.
Redirects are rejected. The relay fixes model `gpt_5_4`, the canonical prompt
builder and JSON schema; request bodies cannot supply URLs, prompts, models,
quota, entitlement or identity assertions. Base44 uses its documented server
service-role `Core.InvokeLLM` integration. Themes and exclusions are processed
there; language follows the theme. No paid provider call was made by local tests.

## Single paid invocation and uncertain outcomes

The normal authenticated native generation path owns account checks, daily quota,
membership, request UUID/hash and the generation lease. The relay only replaces
the provider invocation. Before contacting Base44, Supabase stores a prepared
provider call bound to actor, request, current lease, call index and input hash.
Domain-separated HMAC authenticates each action, method, timestamp and exact body.
The 60-second signature window is supplemented by a durable atomic claim.

Base44 claims the prepared row before calling AI. Only one concurrent caller may
change it to started. Completed provider results are saved to Supabase before
Base44 responds. Supabase accepts words only from that private completion record,
never the HTTP response body. Existing output safety and theme checks still apply.
One optional exhaustion refill has a separate claim, with at most two provider
calls under the same generation quota charge.

Lost HTTP or completion acknowledgements recover a recorded result. Before a
claim, failure safely releases quota and invalidates that old lease. After a
claim, failure retains the quota and permits an in-flight completion until the
120-second lease ends. During that window the same request reports retryable
`generation_in_progress`. If it remains unknown after expiry, it becomes failed
with nonretryable `generation_outcome_unknown`; the same UUID cannot call AI again.
There is no automatic provider retry or fallback. A new, explicit request consumes
another quota reservation. An expired/replaced lease or deleted account cannot
write a late completion.

The provider-call table stores hashes, actor/request/lease/claim identifiers,
call index, state, timestamps and sanitized results. It has no separate raw-input
columns and does not retain the exclusion list. Generated result names/categories
can contain the submitted theme, including the normal completed generation name.
Deleting its parent generation request cascades all provider-call records.

## Local evidence and remaining acceptance

`node --experimental-transform-types --test --test-concurrency=1
tests/app-services/native-ai-relay.test.mjs` uses the dedicated Postgres at
`127.0.0.1:56322`, applies only the additive table DDL, and mocks all provider HTTP.
It covers durable claim races, replay, ACK loss, unknown outcome, late completion,
lease fencing, deletion, HMAC tampering, private-table access, fixed configuration,
free quota, server membership and exhaustion refill. Both deployed entry points
are checked with Deno. Cloud gateway routing, actual Base44 managed integration
and a real native-client request remain separate post-deploy acceptance checks.

Verified locally on 2026-10-27: 17 relay tests and 31 existing Game Center/native
integration checks passed, with no failures or skips. Deno checked the Base44
relay and Supabase app-services entrypoints. Local security advisors reported
no warnings or errors. Independent review found and fixed unsigned Base44 SDK
routing headers: the relay now pins the SDK app ID and API URL before using
platform service authorization, with a focused regression test.
