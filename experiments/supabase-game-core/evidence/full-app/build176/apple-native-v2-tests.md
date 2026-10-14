# Apple native handoff v2 — local server verification

Prepared on 2026-10-14. No production mutation, provider login, signing, installation or physical-device acceptance is represented by this evidence.

Command (from the repository root):

```sh
npx --yes deno test --allow-env --allow-read --allow-net --no-lock base44/functions/appleAuthBroker/native-handoff_test.ts base44/functions/appleAuthBroker/native-handoff-handler_test.ts base44/functions/appleAuthBroker/provider_test.ts base44/functions/appleAuthBroker/google-state-recovery_test.ts
```

Result: **13 passed, 0 failed**.

- 2 new policy tests: exact explicit version, unchanged legacy callback, invalid values rejected, Apple remains Apple, working Google return remains Google.
- 1 new actual-handler test: signed ticket claim controls the callback, unsigned query overrides cannot change it, unknown signed claim is rejected, invalid native opt-in stops before provider calls. Synthetic keys and identities only; no provider/network calls from this handler fixture.
- 4 existing provider-selection tests passed unchanged.
- 6 existing Google-state-recovery tests passed unchanged.

`deno check --no-lock` passed for the prepared candidate entry against the freshly pulled deployed helper files. The live billing-identity-lifecycle helper differs from the checkout and is intentionally preserved; its baseline and candidate hashes match in the manifest. Only the function entry and new native-handoff module differ from the deployed baseline.

Standalone `swiftc -swift-version 6 -typecheck SpyClash/Services/AppleNativeHandoff.swift` also passed. The parent task also confirmed **7/7 Apple native tests passed**, including real loopback HTTP302 interception for the canonical HTTPS callback and the legacy custom-scheme return. The separate ordinary Debug regression run passed **135/135**; exact run artifacts are recorded by the parent task.

## Reproduction and limits

The runtime patch uses paths relative to the pulled function directory containing `function.jsonc`. Verify all baseline hashes before applying it with `git apply --unidiff-zero -p1`; abort on drift. Tests are source-only files, deliberately excluded from the runtime patch.

The proposed callback bypasses JavaScript by intercepting the exact HTTPS redirect in the new native URLSession delegate. No website/Google callback publication belongs to this patch. The observed legacy function-return limitation is a candidate cause; current direct SSO probes were blocked equally for Apple and the known-working Google control, so they do not establish a new live root cause. A real Apple login after separately approved deployment and build delivery is still required.
