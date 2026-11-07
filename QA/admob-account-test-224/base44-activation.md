# Base44 own-account rewarded test activation

Activated 2026-11-07 at 20:02:03 UTC for the verified profile SPY ID 844-010 only.

- Canonical account identity was confirmed by the actual logged-in app session `/entities/User/me` and the visible profile.
- Before activation, CLI-token reads returned empty usage, reward, entitlement and grant arrays. These counts are visibility-limited, as qualified below; existing generation access was preserved.
- Published only `generationRewardAction` from the frozen candidate. All 8 runtime file hashes match readback; only entry and reward helper changed. Other 21 functions and all entity schemas remain byte-identical.
- Set `SPYCLASH_REWARDED_GENERATION_TEST_USER_IDS` to the single confirmed account ID. Exact-value CLI acknowledgement and secret-name readback succeeded. No secret values were read back.
- The global rewarded-generation flag and ad unit were not changed. The prior explicit global `false` setting was preserved; runtime environment values are not exposed by the read API.
- No quota, reward, entitlement or membership records were edited. No ad reward was synthesized. A real signed Google callback is still required.
- Deployment ID: `07e555ad178d46c69b178c7db989df4e`.
- Candidate verification: 16 actual handler tests and 14 ledger/SSV tests passed before publication. This receipt proves publication and configuration acknowledgement; the actual in-app ad / credit test is tracked separately.
- The test allowlist was revoked after Google blocked ad loading; see the revocation receipt below.

Durable evidence: `/Users/davidganzha/.codex/visualizations/2026/11/05/01a1add8-89ed-7a72-976b-533695c34d6f/admob-setup/base44-account-test-deployment-20261107T200039Z`.

## Test result and revocation

At 2026-11-07T20:05:19.150921+00:00, the single-account test allowlist was explicitly set to an empty value and acknowledged by Base44; secret-name readback confirmed the setting remains present. No function, global flag, ad-unit, quota, entitlement, or reward mutation accompanied revocation. Actual runtime secret values are not exposed by the management API.

The in-app Google SDK returned `Account not approved yet` before an ad was shown (root captured actual error text). The test UI displayed zero additional generations. CLI-token reads returned zero visible reward and usage rows, but do not independently establish account balances. A rewarded impression and +1 credit were not demonstrated.

### Ledger read visibility qualification

The zero-row counts in the raw receipts are the direct results of CLI-token management reads, not independently established server ledger absence. Entity RLS may hide rows from that token: the actual iOS flow prepares an attempt before invoking the Google SDK, so the observed SDK error conflicts with zero visible attempts. Treat usage/grant/bonus counts as provisional until an authenticated exact-attempt claim or editor-authorized record read confirms them. The exact empty allowlist acknowledgement and unchanged source/configuration scope are unaffected.
