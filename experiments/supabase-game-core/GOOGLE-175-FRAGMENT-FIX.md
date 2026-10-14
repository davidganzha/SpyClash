# Google callback fragment compatibility — source 175

Status: published with explicit user approval on 2026-10-13 at approximately 21:48 UTC; live asset and browser checks passed. On 2026-10-14 (Europe/London), the user confirmed successful Google sign-in and their existing profile on Ganzha. Main TestFlight build 173 remains installed. No native source, backend function, provider configuration, Supabase project or TestFlight assignment changed.

## Confirmed failure and remaining uncertainty

On Ganzha, the user retried Google after the approved diagnostic publication and reported `SCG174-02`. Earlier they confirmed the error appeared immediately after account selection/confirmation, without Refresh or Back. In the published callback, this code means the original `window.location.href` contained a literal `#`; the page rejected it before query validation and before attempting the native handoff.

The previous unconditional fragment prohibition also rejects an empty `#` after an otherwise valid query. This is a demonstrated compatibility defect. The code alone does **not** identify the actual fragment on Ganzha, its upstream origin, whether the query contains a valid token/provider, or whether a later step would succeed. No callback URL, token, cookie or password was requested or retained.

HTTP redirects can inherit a fragment when the next `Location` omits one ([RFC 9110 §10.2.2](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.2)). OAuth security guidance explicitly permits an inert fragment such as `#_` to prevent that inheritance ([RFC 9700 §4.1.3](https://www.rfc-editor.org/rfc/rfc9700.html#section-4.1.3)). These explain why a fragment need not be a malformed credential; they do not prove which server/browser produced this phone's fragment. The current broker uses Google's authorization-code flow. The Base44 SDK reads its final application token from the query; there is no demonstrated need to accept fragment credentials.

## Narrow change

- Accept exactly the raw suffixes `#`, `#_`, and `#_=_` as inert markers. The last is included as a literal inert compatibility marker, not as a claim about the observed Google response.
- Read only the query. Never decode, merge, recover or forward a fragment credential. Reject all other fragment forms, including encoded marker variants, whitespace, extra delimiters, token/error/code/state payloads and arbitrary anchors.
- Keep exact canonical origin/path, required `auth_provider=google`, decoded duplicate-key rejection, token/error exclusivity, length/control checks and the fixed `spyclash://auth` destination.
- Continue removing the query and fragment before UI construction or navigation. If cleanup fails, do not forward. A second mount/reload cannot recover a credential from DOM, storage or history.
- Change only the support-code prefix to `SCG175` to distinguish the new page. The callback still makes no SDK, API, storage, cookie or logging calls.

Inspect the **raw** suffix rather than relying on `URL.hash`: an empty fragment has an empty `.hash`, and URL parsing normalizes some control characters. A normalized comparison could accidentally allow extra suffix forms.

## Artifact and validation

The tracked source is `web-auth/src/lib/mobileAuthCallback.js`; the candidate lives under ignored `.local/google175/site-candidate`. It was built using the retained published-site source/dependencies, replacing only that callback source. Deployment staging `.local/google175/site-deploy` contains five static files and only the canonical app/site configuration. It has no backend functions, secrets or symlinks.

- Callback unit/VM suite: **66/66 passed**. Includes successful token/safe-error handoff for all three markers; sensitive and malformed fragments; unchanged rejection cases with every marker appended; duplicate encoded keys, mixed payloads, fixed destination, cleanup failure, reload/remount and forbidden browser capabilities.
- Vite production build: passed.
- Ordinary site JavaScript, CSS and manifest: byte-identical to published 174. `index.html` changes only the callback entry filename.
- Callback entry: `assets/index-GEnUi1AX.js`, SHA-256 `06bfa39438b4280296aa391df494fca5c409b34219a5589cd06c068b346a9afd`.
- Source SHA-256: `a59964b250227975fe8093ed912a9eec094813d7df5017aa763e2fad14c09f3c`.
- Prepared ZIP SHA-256: `9c12b470925f2e7e4fdf2df3af49d8c84645841a1aaf2f63c56395d3abca3b1e`.

Independent checks completed:

- Differential/mutation review: **484,970 inputs**, zero unexpected output changes or exceptions; exactly 3,087 newly accepted cases, all valid query payloads with one of the three allowed suffixes. Six deliberately weakened validation variants were detected.
- Actual bundled entry VM audit: **412 runs passed**; only the intended files changed and no callback SDK/network calls were introduced.
- macOS 26.5.2 **WKWebView: 16/16 passed** using real DOM, history and location against a synthetic canonical origin, with networking blocked. All three markers succeeded; malformed/credential fragments and invalid query cases failed. Four outgoing synthetic native navigations were cancelled by the probe. This is WebKit-engine evidence, not an iPhone ASWebAuthenticationSession or a completed Google login. Reproducer remains in ignored `.local/google175/macos-probe` at the worktree root.
- A fresh read-only live check confirmed diagnostic 174 is still served and all four public asset hashes match its receipt. At that preparation stage, candidate 175 had not been published.
- Project plist syntax and synchronized source version 175 passed verification.

Receipts: `evidence/full-app/build175`. Synthetic checks are not real Google-account acceptance.

## Preparation-time publication and acceptance gate

AGENTS.md requires fresh approval for the exact production action. The earlier approval covered diagnostic 174 only. The proposed next action is **site-only publication** of this prepared candidate to Base44 app `69a0e57fa939f578082f8091` / `spyclash.com`; no general deploy or broker/configuration mutation is part of it.

After approval, verify the live entry hash, unchanged site asset hashes and synthetic callback behavior. Then the user closes the old web sheet in SpyClash 173, starts a fresh Google login and confirms whether the native home screen and existing profile/history appear. Successful web navigation alone is insufficient: the real native session and account mapping must succeed. If a new `SCG175-02` remains, its fragment lies outside this allowlist; retain the failure boundary and obtain only a safe shape classification, never a raw credential-bearing URL.

## Approved publication completed

The user explicitly approved site-only publication of commit `b27e3d6def47a03a97ad9e1265bd72d48e5218c1` in this chat. The fresh preflight verified the clean commit, exact five staged static files, two canonical configuration files, no symlinks/backend files and the still-live 174 baseline.

Executed from ignored `google175/site-deploy`: `npx --no-install base44 --app-id 69a0e57fa939f578082f8091 site deploy --yes`. CLI 0.0.56 exited 0 with `Site deployed successfully` and returned `https://spy-game-zone.base44.app`.

Custom domain `https://spyclash.com/MobileAuthCallback.html` now references `assets/index-GEnUi1AX.js`. All four referenced public assets matched the approved hashes; ordinary site assets remain unchanged. Base44 adds a generated HTML wrapper to this route, so route HTML itself is not described as byte-identical to local index.html.

Live Chrome checks confirmed the empty-fragment synthetic token reaches the fixed native link, the `#_=_` safe-error response reaches its canonical error link, a credential-shaped fragment still produces `SCG175-02`, and reload of the cleaned address produces `SCG175-04` without replay. Navigation waits timed out on the unhandled native scheme in two cases; the subsequent DOM and link checks proved page behavior, without claiming a Mac or iPhone native session. Only synthetic inputs were used.

Receipts: `deployment-preflight.json`, `deployment-postflight.json`, and `live-browser-checks.json` in `evidence/full-app/build175`. The earlier candidate manifest and validation summary retain their historical prepared/unpublished state. The user was asked to start a fresh Google attempt on Ganzha with installed build 173; no app update is needed.

Independent readback also verified raw `/index.html` and all four assets byte-for-byte against the approved artifact. The generated callback wrapper differs from the recorded 174 wrapper only by the new entry filename and ordering of two SEO title-map pairs; reconstructing the old ordering and entry reproduces the recorded 174 wrapper hash. See `independent-live-readback.json`.

## Physical Google acceptance — confirmed by user

On 2026-10-14 (Europe/London), in response to the fresh-Google-login instruction for Ganzha / SpyClash 1.0.3 (173), the user replied: **«Вошёл, мой профиль на месте»**. This is direct user acceptance of the previously failing Google-to-native sign-in with the existing profile after callback 175, beyond the earlier synthetic browser checks. See `physical-google-acceptance.json`.

No raw callback fragment, credentials or independent native session trace was captured. History was not separately rechecked in this reply. The exact inert marker and its upstream source remain unobserved. This closes the reported Google callback failure for this device/account; Apple sign-in and subscription purchase/restore are separate checks. No deployment or build was performed to record this acceptance.
