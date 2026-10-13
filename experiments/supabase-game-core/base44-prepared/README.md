# Main SpyClash billing and APNs preparation

Prepared locally; no Base44 function, production secret, Apple portal or live push has been changed. This folder is not an active deployment directory.

## Existing billing stays authoritative

The main candidate retains `com.spyclash.ios` and the existing weekly product `com.spyclash.ios.limitless.weekly`. `legacy-billing.ts` calls only canonical `https://spyclash.com` app `69a0e57fa939f578082f8091`, using the user's separately stored Base44 credential. Each call verifies `User/me` and the immutable Supabase-to-Base44 identity link. The original `checkSubscription` and `app-store-entitlement` functions keep their Apple verification, Stripe reconciliation, account-token ownership, subscription notification and entitlement policies.

Native requests remain membership `check`, `prepare` and `sync_transaction`. The legacy credential is attached only to the outgoing request, after saving its credential-free mutation journal. Supabase receipts and billing reservations exclude credentials. A retry preserves the original weekly account token/transaction; old saved membership responses do not extend the server cache.

Readiness switches, all off unless deliberately configured:

- Native `permitsLegacyBilling: true`, main candidate only.
- Supabase `APP_BILLING_PROVIDER=base44` and `APP_LEGACY_BILLING_ENABLED=true`.
- New purchases separately require `APP_LEGACY_PURCHASES_ENABLED=true`; the source's own purchase rollout must also permit them. Restore/sync uses existing verified transactions.

No new Apple/Stripe account or key is required. The Supabase mirror grants access for at most five minutes and never beyond the source expiry. Normal membership refresh renews it. Existing Base44 Apple/Stripe webhooks remain unchanged; they do not yet push entitlement changes directly to Supabase. This is a bounded-cache behavior, not an instantaneous cross-provider notification guarantee.

## APNs relay requires a production approval

Original Base44 `pushNotificationAction` loads Base44 GameRoom records and cannot authorize Supabase UUID rooms. Therefore native registration and source/recipient/match checks remain in Supabase. Its durable outbox signs a narrowly scoped server request to a new `supabasePushRelay` function; Base44 reuses its existing APNs key and transports alerts and Live Activity updates/end events.

The prepared function consists of `supabasePushRelay/{function.jsonc,entry.ts,handler.ts,contracts.ts,apns.ts}`. `apns.ts` is copied unchanged from the fresh canonical `pushNotificationAction` runtime (SHA-256 `a0a2e79c1d0b401735670265a132237b91b9f15bd6f07dcb9ad3262ac0897b6e`), retaining silent notifications, payload limits, production/sandbox routing, provider-token caching and token invalidation. It introduces no direct client access to APNs credentials.

Exact future production-facing operations requiring approval:

1. Register/deploy only the new Base44 function `supabasePushRelay` in existing app `69a0e57fa939f578082f8091`, after rechecking current canonical transport drift. Do not replace `pushNotificationAction`.
2. Add one random 32-byte relay secret server-side as Base44 `SPYCLASH_SUPABASE_PUSH_RELAY_SECRET` and Supabase `BASE44_PUSH_RELAY_SECRET`. Never place this in the app, source control, logs or chat. Existing APNs key material stays on Base44.
3. Enable Base44 `SPYCLASH_SUPABASE_PUSH_RELAY_ENABLED=true` only after the new function is verified. Enable Supabase `APP_PUSH_DELIVERY_PROVIDER=base44`, `APP_LEGACY_PUSH_RELAY_ENABLED=true`, `APNS_TOPIC=com.spyclash.ios`, plus its existing encrypted registration and delivery gates (`APP_PUSH_ENABLED`, `APP_PUSH_DELIVERY_ENABLED`, `PUSH_TOKEN_ENCRYPTION_KEY`). Verify the maintenance worker/scheduler before enabling native push registration.
4. After server verification, enable the native push gate only in the explicitly approved internal candidate. Confirm real-device alert and Live Activity update/end delivery there before wider release. TEST topic/configuration remains separate.

The relay accepts only an authenticated HMAC request from the prepared Supabase source `bbkfsgnordtdiblgdzkg`, main bundle topic, bounded expiry and payload, and a timestamp within 60 seconds. A native bearer, public Supabase key or guessed room UUID cannot authorize it. APNs uses stable collapse identifiers and retains at-least-once delivery after a lost response; an already in-flight push cannot be recalled by later account deletion.

This preparation is still restricted to the existing isolated Supabase project. Choosing a production project, migrating production data, deploying these functions/configurations or uploading the main app requires a separately reviewed cutover. No additional paid provider is introduced by these adapters.
