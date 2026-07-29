# SpyClash 1.0 (41) — Web App ID repair candidate

Prepared on 29 July 2026 for Apple ID `6793534085`, team
`David Ganzha (3Z64QKNL54)`, bundle ID `com.spyclash.ios`, Base44 app
`69a0e57fa939f578082f8091`, and `https://spyclash.com`.

This checkpoint repairs the public Web bootstrap only. It has not been deployed
to Base44 Production. Build 41 is not archived, uploaded, selected in App Store
Connect, submitted to App Review, promoted through TestFlight, or released.

## Incident

The previously deployed clean Web artifact was built from commit `fb0860f`.
Its ignored `.env.local` was absent, so the generated JavaScript contained
`appId:getAppParamValue("app_id",{defaultValue:void 0})`. A new browser had no
stored `base44_app_id`, requested
`/api/apps/public/prod/public-settings/by-id/null`, received HTTP `404` with
`App not found`, and rendered the `CONNECTION ERROR` screen.

The earlier desktop smoke was not a valid clean-session proof because that
browser already had the correct App ID in local storage.

## Fix candidate

- Web source commit:
  `c21e7a297fdd4adf2c658999028e98fa26a168a7`
- Change scope: only `src/lib/app-params.js`,
  `src/lib/appParamsPolicy.js`, and `src/lib/appParamsPolicy.test.js`
- Public tracked Base44 App ID:
  `69a0e57fa939f578082f8091`
- Production builds ignore URL and local-storage attempts to replace that ID
- Production ignores URL, environment, and stored `functions_version` values
- Production authentication stays same-origin and rejects `app_base_url`
  overrides
- Non-production origins fail closed unless the current URL or trusted build
  explicitly provides an App ID; stored Production identities are discarded
- Development previews may use an explicit alternate App ID and a validated
  HTTP(S) auth origin
- Reproducible source patches and SHA-256 values:
  - `WebCandidate/0001-fix-pin-spyclash-base44-app-identity.patch.gz`:
    `3782c2ed5f41b05c1e34e28bed46aedc21a7f5ebd006c308602138be439296f3`
  - `WebCandidate/0002-fix-lock-production-base44-routing.patch.gz`:
    `ce6aeb711d01fc4b1a7ff7e00655ca49601ef4bfba6408296153c725d18dcf44`
  - `WebCandidate/0003-fix-fail-closed-outside-production-hosts.patch.gz`:
    `d65be07063bdf2421e4068cf00d2c2219368ed2511e44e82b5091015e13fa8ce`
  - `WebCandidate/0004-fix-lock-base44-auth-origin.patch.gz`:
    `b81438aface9d8c4fe151c6cd9786886f0dd78996d27d4904d1be58bb1ad2e5b`

The candidate was built from a detached clean worktree containing zero `.env*`
files. Verification passed:

- JavaScript tests: `42/42`
- ESLint: passed
- TypeScript check: passed
- Vite production build: passed
- Old null-App-ID bootstrap occurrences: `0`
- Tracked App ID configuration marker occurrences: `1`

## Exact six-file Web artifact

- `assets/index-0l8dwMq3.css`:
  `213b1b836274d0aeffbead7931d41cc43f8482cc7eaec8b955dfd20c2dd077b3`
- `assets/index-DGwF0ML3.js`:
  `09c1f0f315c2e398fec72dfa710728b7c9f341fc3083efbe2db8ea4b6a48b7b9`
- `icon-192.png`:
  `f87e24ccca18273ac41aa11d5b7971ff87509231f606a872d2cae1554a39c7b5`
- `icon-512.png`:
  `bf034fa28c99e7242c1b58abfbf202515cd9386e07424ef558f59285cadcd15e`
- `index.html`:
  `cf25af87e1c764e8084d4dcdcd2240af2651ab06fea883f9dc983e922d629d10`
- `manifest.json`:
  `25511fc511061469990b367cc1c52f14622c7a70b50d8f3bbf2d844d44b70a80`

The SHA-256 of the canonical `hash  relative-path` manifest is:
`5ffbf99c8a48f6c22aef439381cc470422cc2c87c05cae2bbc464ef08b9eb881`.

## Required deployment gate

After fresh authorization, deploy only this exact six-file artifact to the
Base44 Production site of app `69a0e57fa939f578082f8091`. Do not change
entities, schema, data, functions, secrets, auth configuration, iOS, or App
Store Connect. Postflight must use a fresh browser context with no stored site
data and prove that plain `https://spyclash.com` renders without URL parameters.
