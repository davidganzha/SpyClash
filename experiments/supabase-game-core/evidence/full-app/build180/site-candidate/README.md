# Frozen Apple callback site candidate

Local preparation only. Canonical target: Base44 app
`69a0e57fa939f578082f8091`, `https://spyclash.com`. A future approved operation
must use **site deploy only** from the frozen directory below. There are no
functions, auth changes, secrets, dependencies or symlinks in either package.

- Candidate: `.local/apple180-browser/site-deploy` (repository root).
- Rollback: `.local/apple180-browser/site-rollback` (exact published175 payload).
- Manifest: `site-candidate-manifest.json`, SHA256
  `fe54c9b1f5abc3474e424dc678f70a886e887581c068748ecf16b9305d79c277`.
- Each directory has exactly five static files plus the retained canonical
  `base44/.app.jsonc` and site-only `base44/config.jsonc`.
- Deterministic review ZIPs are beside those directories; hashes and exact
  seven-file package inventories are in the manifest. ZIPs contain only the
  five static payload files. They have not been uploaded.

Unauthenticated public GETs on 2026-10-17 at 19:05 UTC matched all five current
published175 files to retained receipts. See `site-live-before.json`. This is a
point-in-time check; repeat before any later approved deployment.

The new entry is `assets/index-B5iDK17o.js`, SHA256
`da3600f07c5ccdd00036182dc65d86681b6beb9bad5446012ea3f04b66a7ee5a`.
The ordinary application JS, CSS and manifest remain byte-identical to live175.
HTML changes are three exact Apple callback exclusions, the new entry filename,
and a final newline. Google callback source and normal bootstrap source remain
byte-identical.

## Reproduction and provenance

1. Copy retained published175 source from
   `experiments/supabase-game-core/.local/google175/site-candidate` into a fresh
   ignored directory, excluding node_modules, dist, Git metadata and env files.
2. Overlay exactly `web-auth/index.html`, `web-auth/src/main.jsx`, and
   `web-auth/src/lib/mobileAppleAuthCallback.js` at matching source paths.
   The manifest records their SHA256 values and the unchanged lockfile hash.
3. Restore the retained lockfile with
   `npm ci --ignore-scripts --no-audit --no-fund --offline` (648 cached packages;
   pinned Vite 6.4.4). No dependency install scripts ran.
4. Build with the published **public** values:
   `VITE_BASE44_APP_ID=69a0e57fa939f578082f8091
   VITE_BASE44_APP_BASE_URL=https://spyclash.com npm run build`.
   These variables must be supplied on the same shell command line. Without
   them, Vite substitutes undefined defaults into the ordinary bundle. The
   final frozen build restores both values and exactly matches that bundle;
   no manual JavaScript bundle patch was used.
5. Compare all five output hashes to `afterFiles` in the manifest. Copy only
   dist and the retained two Base44 config files into a new deployment folder.
   For rollback, use the five `beforeFiles` from retained175 and the same configs.

## Verification

- Source tests: 104 passed (38 Apple/shared route + 66 unchanged Google).
- Actual frozen Vite entry and actual built HTML inline guards:
  **13/13 macOS WKWebView cases passed**. Eleven Apple cases cover accepted
  token/error, inert fragment, literal plus, malformed/duplicate/mixed input and
  reload after cleanup. Two Google cases preserve its existing return contract.
- Native navigation was intercepted and cancelled; all network was blocked by
  a WebKit content rule. Storage, fetch, XHR, service worker, cache and uncaught
  error counters stayed zero, and no ordinary bootstrap preload appeared.
- `SiteWebKitProbe.swift` records the exact harness. It loads synthetic HTTPS
  documents, evaluates the unmodified built entry and extracted inline scripts,
  and checks rendered DOM and native navigation. Its result is
  `site-webkit-outcome.json`; it is not an Apple authentication session.

The callback still needs approved publishing before the native browser flow
can be tested on a device. No actual Apple login, live final native response,
ASWebAuthenticationSession completion or phone acceptance is established here.
