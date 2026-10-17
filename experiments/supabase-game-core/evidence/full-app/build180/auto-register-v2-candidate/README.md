# Apple registration candidate

Local preparation only. This is a separate downstream repair from the build176 Apple handoff failure: the original served registration function ignores `apple_binding_ticket`, so successful registration does not bind the pending Apple credential or respect the intended ticket-before-provisioning boundary.

The generator emits exactly one function, `autoRegisterUserV2`. Its four runtime files match the previously reviewed modern candidate byte-for-byte. The source manifest names each tracked source and SHA256. Three sources are in `base44/functions/autoRegisterUser`; the lifecycle helper uses the already-tracked build178 snapshot because the normal source directory has a separate pre-existing constructor extension. No ignored readback is required to reproduce the package.

```sh
python3 experiments/supabase-game-core/scripts/package-auto-register-v2.py --output .local/auto-register-v2-review
deno test --no-lock --config .local/auto-register-v2-review/tests/deno.json .local/auto-register-v2-review/tests/contract_test.ts
deno check --no-lock --no-config .local/auto-register-v2-review/base44/functions/autoRegisterUserV2/entry.ts
```

The generated tests capture the actual handler and execute its real Apple binding and lifecycle helpers. SDK identity and persistence are in-memory fixtures; network and environment permissions are denied. The source-only legacy fixture contains no user data, live credentials, readback wrapper or server metadata. It is retained to reproduce the defect: an invalid ticket causes the old handler to invite and return success, while the modern handler rejects before invitation.

Verified cases include existing/new users, canonical service context, forged identity/destination fields, rejected tokens, expired/foreign tickets, foreign ownership, same-owner retries, active deletion markers, and uncertain persistence. Google registration is not redirected by this backend package.

Before native activation, obtain explicit approval for the exact new function deployment, verify no name collision, use only named function deployment, then verify public GET405 and unauthenticated POST401 and unchanged existing functions. Native Apple registration should require the modern verified-user response before accepting its session. Real ticket binding and physical-device sign-in remain delivery checks.

This package changes no account-deletion implementation. Modern Base44 deletion can collect unclaimed credentials by verified email as well as bound ownership; missing binding alone does not prove revocation is impossible. The lifecycle guard is still necessary to prevent stale tickets from provisioning across deletion boundaries.

Rollback means restoring native route selection and leaving V2 unreferenced; it restores the prior missing-binding behavior, not a known working Apple flow.
