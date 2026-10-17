# Apple browser return candidate

This is a local candidate, not a published website change or a confirmed repair
of the reported phone failure. The final response that the existing native
handoff received has not been observed.

The new helper owns only `https://spyclash.com/MobileAppleAuthCallback.html`.
`main.jsx` selects it before the normal application loads, and `index.html`
excludes that exact route from its analytics, storage, service-worker and cache
bootstrap. The existing Google helper, tests and normal application bootstrap
are unchanged.

The page clears its query and fragment before creating UI. It requires the
exact HTTPS origin/path and `auth_provider=apple`, validates every query item
with the native policy's UTF-8 bounds, rejects duplicate decoded names and
mixed token/error payloads, and accepts only the inert fragments `#`, `#_`,
and `#_=_`. Literal plus signs remain literal query data, matching native
`URLComponents`. Malformed percent escapes are rejected.

Only a token or a fixed safe error returns through
`spyclash://auth?auth_provider=apple`. No other incoming field, provider error
description or caller-selected destination is forwarded. The helper has no
SDK, storage, network or telemetry calls. A visible link handles browsers that
require a gesture. Cleanup failure blocks both automatic and manual handoff;
refreshing the cleaned URL cannot recover a prior credential.

`npm test` in `web-auth`: **104 passed**, including 38 Apple/parser/mount/shared
entrypoint checks and all 66 unchanged Google checks. These tests execute the
helper source in a constrained browser fixture; they do not establish real
Apple browser authentication or device acceptance.

The native `ASWebAuthenticationSession` change requires this route to be present
in the reviewed hosted frontend before device testing. Publishing the frontend
and delivering a native build are separate production actions and are not
performed by this candidate.

## Frozen site artifact

Target: canonical Base44 app `69a0e57fa939f578082f8091`,
`https://spyclash.com`, site-only publication. This operation remains unperformed.
The reviewed local package is `.local/apple180-browser/site-deploy` relative to
the repository root; rollback is `.local/apple180-browser/site-rollback`.
Both contain exactly five static files and two retained site configuration files.

The frozen manifest is `.local/apple180-browser/site-candidate-manifest.json`,
SHA256 `fe54c9b1f5abc3474e424dc678f70a886e887581c068748ecf16b9305d79c277`.
Commit-ready receipts, exact before/after hashes and reproduction instructions
are in `experiments/supabase-game-core/evidence/full-app/build180/site-candidate`.
The new entry `assets/index-B5iDK17o.js` has SHA256
`da3600f07c5ccdd00036182dc65d86681b6beb9bad5446012ea3f04b66a7ee5a`.

Unauthenticated GETs at 2026-10-17 19:05 UTC verified all five live175 files
against the retained published payload. Building the three-file Apple overlay
on that source with its exact public app ID and domain preserves the ordinary
application JS, CSS and manifest byte-for-byte. Only the entry and three HTML
route exclusions plus a final newline change. Recheck live hashes before any
approved future publication.

The actual frozen entry and actual built HTML inline guards also passed
**13/13 macOS WKWebView checks** (11 Apple, two existing Google callbacks).
Native navigation was intercepted and cancelled, credential-bearing URL data
was cleared, and no SDK/storage/network/bootstrap activity was observed. All
network was blocked and only synthetic credentials were used. This proves the
built callback behavior in WebKit; actual Apple authentication and phone
acceptance remain separate checks.
