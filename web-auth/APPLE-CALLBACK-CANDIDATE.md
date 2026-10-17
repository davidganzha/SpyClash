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
