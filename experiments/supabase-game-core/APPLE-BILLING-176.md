# Apple native sign-in and weekly billing — source 176

Prepared on 2026-10-14. Marketing version remains 1.0.3. This is a local candidate, not a deployment, TestFlight upload, or physical-device acceptance.

## Current evidence and scope

The user accepted Google sign-in on Ganzha with installed main SpyClash 173 and hosted callback source 175: “Вошёл, мой профиль на месте”. The Google public callback, provider selection, and native Google URL remain unchanged in 176. Callback source SHA-256 remains `a59964b250227975fe8093ed912a9eec094813d7df5017aa763e2fad14c09f3c`.

The user reported the current Apple error on Ganzha 173 as `invalid_url 400`. Apple uses a different transport: native Apple authorization followed by an ephemeral URLSession redirect chain. That transport does not execute a callback page's JavaScript. The deployed Apple broker still returns through the historical Base44 function URL; repository evidence records rejection of such `from_url` paths. This matches the reported URL rejection. Current unauthenticated HTTP/browser probes were blocked upstream and did not independently capture the phone's redirect chain. A fresh Apple sign-in on Ganzha after the fix remains required.

App Store Connect read-back on 2026-10-14 confirmed app `6793534085`, bundle `com.spyclash.ios`, subscription group `22256419`, and the approved weekly subscription `com.spyclash.ios.limitless.weekly` (product record `6793548263`, `ONE_WEEK`). No monthly product exists in this app's current group. Fresh canonical Base44 billing source also supports weekly only. No product, price, payment, or App Store setting was changed.

Build 173's immutable main-candidate configuration disables purchases. Live Supabase `app-services` v4 also lacks the legacy billing bridge present in newer local source. A server-only toggle cannot enable this feature in installed 173.

## Changes

- Native Apple requests opt into fixed `handoff_version=apple-native-v2`. The broker places that value in its signed native ticket and chooses the fixed HTTPS return `https://spyclash.com/MobileAppleAuthCallback.html?auth_provider=apple`. It accepts no caller-supplied return URL.
- The Apple-only URLSession delegate intercepts this exact return before fetching HTML. It validates scheme, origin, path, provider, duplicate decoded query keys, token/error exclusivity, raw inert fragments, value bounds, and redirect count. It still supports the legacy custom-scheme return. Untrusted token-bearing destinations are not fetched.
- Old clients without the opt-in retain their existing server return. Google source, route, and provider dispatch are unchanged. No website publication is needed for the new Apple native interception.
- Main-candidate configuration enables the existing weekly purchase/restore UI. Ordinary Release remains on its existing backend configuration. Push and account-deletion flags remain disabled in the hybrid candidate.
- Supabase forwards billing verification to the existing canonical Base44 billing provider, verifies the linked account owner, preserves the canonical Apple account token, and mirrors only verified entitlement state with a bounded lifetime. Base44 credentials remain wire-only and are excluded from durable command identity and receipts. Checkout remains weekly; compatibility restore accepts only explicitly allowlisted products in a server-verified result.
- If a saved StoreKit payload A lost its acknowledgement and Apple later presents payload B, the native session now drains A with its original request ID before independently sending B. A's response never finishes B. Account changes, cancellation and temporary failures preserve the appropriate saved intent; unrelated app operations keep their existing journal behavior.

## Deployment artifacts and isolation

Do not deploy the complete newer local backend directory. The prepared patches are based on fresh deployed sources and deliberately preserve unrelated live/source differences.

- Apple: `.local/apple-billing176/appleAuthBroker` at repository root. Runtime delta is only the broker entry and new `native-handoff.ts`. The live billing-identity-lifecycle module is preserved. Sanitized hashes and patch are in `evidence/full-app/build176/apple-native-v2-*`.
- Billing: `experiments/supabase-game-core/.local/apple-billing176/app-services`, with sibling full-game-core dependencies. Baseline is Supabase `app-services` v4, ID `a271cf0c-f0c7-4589-8448-406e286082fa`. Only dispatcher, handler, membership, and the new legacy-billing module differ. No schema migration is required. Push, deletion, generator, auth, and game runtime files are preserved.
- Supabase target remains isolated project `bbkfsgnordtdiblgdzkg` in `eu-west-1`. This does not authorize a production game-backend cutover.

Before deployment, compare fresh deployed hashes with these baselines. If anything has changed, rebase the minimal patches and reverify instead of overwriting newer live work. Rollback sources are the fresh baseline bundles; disable checkout before withdrawing the billing bridge. Never roll back or publish the working Google callback as part of this change.

## Rollout gates

1. Obtain fresh explicit approval for the exact canonical Base44 `appleAuthBroker` deployment (app `69a0e57fa939f578082f8091`). No other Base44 function, website, or authentication configuration belongs in that deployment.
2. Deploy only the reviewed billing overlay to the isolated Supabase `app-services` function. Required bridge configuration: `APP_BILLING_PROVIDER=base44`, `APP_LEGACY_BILLING_ENABLED=true`; checkout additionally requires `APP_LEGACY_PURCHASES_ENABLED=true`. Verify `SPYCLASH_LIMITLESS_ENABLED` for the existing Supabase premium feature enforcement during rollout. The current Edge environment values have not been independently verified. Preserve unrelated secrets/flags and the canonical Base44 purchase gates.
3. Authenticated membership validation may reconcile canonical records. Purchase preparation can reserve an AppStoreAccount token in Base44. These are not claimed to be read-only operations; include the intended account and these mutations in the approval scope before executing them.
4. Sign and upload main SpyClash 1.0.3 (176) to TestFlight Internal Only, David Ganzha only, only after exact distribution approval. There is no App Store submission in this plan.
5. On Ganzha: Apple sign-in/repeat/cancel, then Google sign-in returning to the recognized original profile. Apple private-relay identity must never be merged into a Google account just because an email looks related.
6. With an appropriate ordinary test account and user confirmation in Apple's sandbox sheet: weekly purchase, restore after restart, lost response/reconnect, logout/account switch, and revoked/expired entitlement. Only verified server delivery can finish a StoreKit transaction. No real purchase or account downgrade is performed by preparation.

## Validation

See the sanitized evidence under `evidence/full-app/build176/`:

- Native auth/session/StoreKit regression: **135/135**, including seven Apple handoff tests with real loopback HTTP redirects intercepted by the production URLSession delegate.
- Full hybrid Staging regression: **49/49**, including eight new durable purchase recovery regressions.
- Google web callback: **66/66**, with the source hash unchanged.
- Broker policy/handler/provider/Google-state regressions: **13/13**.
- Billing domain plus the actual prepared live-v4 HTTP handler: **8 + 5**, against local PostgreSQL/Auth and a mocked canonical provider.
- Prepared server patches reproduce the manifest hashes; independent final review found no remaining local blocker.
- Generic iPhone **SupabaseRelease archive succeeded**, 1.0.3 (176), with signing disabled. Embedded backend mode/configuration, version, widget, privacy manifest, weekly product, and separate callback routes were checked. It is not an installable or uploaded TestFlight artifact. The ordinary Simulator bundle also passed the release bundle resource gate.

An initial selection of legacy Base44 test fixtures under SupabaseDebug was stopped and is explicitly recorded as unsuccessful in `native-regression.json`; the intended Debug rerun and separate hybrid suite above passed. Test doubles and local HTTP fixtures do not prove live Apple authorization, canonical billing secrets/flags, physical StoreKit delivery, or App Store readiness.
