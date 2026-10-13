# Native Google OAuth return page

The current source checkpoint is 174. It adds failure-only support codes and navigation/mount diagnostics, with the existing sign-in acceptance rules unchanged. It was published with explicit user approval on 2026-10-13 at approximately 21:34 UTC; canonical live asset hashes and the diagnostic UI were verified. The exact physical iPhone failure remains unconfirmed; see the [Google 173 investigation and diagnostic candidate](../experiments/supabase-game-core/GOOGLE-174-INVESTIGATION.md) for live evidence, prepared artifact scope and acceptance steps.

`npm test`: 62 callback tests pass, including safe diagnostic output, history cleanup, same-document remount and fresh-document reload. Build 174 here is a source version bump, not a TestFlight delivery. Installed main build 173 can use the updated web callback through the now-published web callback.

The remaining sections describe the original build 166 overlay. Their broker deployment sequence is historical; no broker/configuration update belongs to the current diagnostic change.

Base44 currently rejects function URLs in `from_url` with HTTP 400. The native Google entry and its broker recovery link now return through `https://spyclash.com/MobileAuthCallback.html?auth_provider=google`.

These four frontend files form a patch over the canonical Base44 source read on 2026-10-11:
- `index.html`: no-referrer before resource loads; skip website storage/cache bootstrap for native return.
- `src/main.jsx`: intercept native return before loading the normal app.
- `src/bootstrap.jsx`: the unchanged former main entry, loaded only for website routes.
- `src/lib/mobileAuthCallback.js`: validate the fresh response, remove its query, and return only a token or safe error to the fixed `spyclash://auth` destination. No SDK, session storage, telemetry or API calls on this route.

The `.html` suffix is a URL route; Base44 serves its normal SPA index. No separate HTML hosting feature is required. The callback module must run before `App.jsx` imports the SDK, which otherwise consumes the token into the website session.

## Validation

`npm test` in this directory: 48 callback tests. Built production bundle additionally verified in a real headless Chromium browser for success, cancellation, duplicate token and missing token; no API requests, storage access or App bootstrap occurred. Native auth regression tests: 25 passed. Live Google-form cancellation/restart UI test: 1 passed (two successive attempts). Broker tests: 65 passed.

These checks do not substitute for a real account completing sign-in on the published callback page. Perform that acceptance after publication, then join the three-player test room.

## Deployment scope and ordering

1. Publish the reviewed frontend build for canonical app `69a0e57fa939f578082f8091` (`spyclash.com`). All existing source was freshly read; only the four listed files differ.
2. Deploy only `appleAuthBroker` from a fresh runtime snapshot; the only runtime delta is `google-state-recovery.ts` app retry URL. Preserve its Apple native bootstrap, provider credentials, cookie handling and all other files.
3. Verify the callback route and recovery URL on the live site, complete a real Google sign-in, then distribute build 166 in TestFlight Internal QA.

Production actions require separate current-chat approval per AGENTS.md. The TestFlight upload was requested on 2026-10-11; website/function approval is separate. Keep this source overlay in future Base44 website builds; publishing a builder snapshot without it would remove the callback fix.

## Baseline hashes for the replaced remote files

- `src/main.jsx`: `e74b2988b408945f488a50e3ac866122b4d8a0b5b6f59966ddc70d4bd735153e`
- `index.html`: `10a8207814b1e4bc13ecd20b79cf56c407ff053037c4bae3f02c32c991f8146a`
- deployed `google-state-recovery.ts`: `aa6cf334f74099ff70cbdb206ea63bea7c07c619ee8af44e4a18222d86756e88`
