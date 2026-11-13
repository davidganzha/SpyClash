# Combined server candidates — build 238

Prepared locally on 13 November 2026 from live snapshots, with no release
deployment, migration, activation, secret update, or Unity message. The
accidental Base44 copy and its separately approved removal are documented in
[`../incident.md`](../incident.md); that export was never used as an input.

## Exact targets

| Target | Live baseline | Candidate files | Changed / preserved |
| --- | --- | ---: | ---: |
| Supabase app-services | v26, 78 files | 84 | 19 / 65 |
| Supabase rewarded-generation-ssv | v3, 10 files | 11 | 5 / 6 |
| Base44 generateWordPack | canonical deployed bundle | 18 | 2 / 16 |
| Base44 generationRewardAction | canonical deployed bundle | 9 | 3 / 6 |
| Base44 deleteAccount | canonical deployed bundle | 15 | 1 / 14 |
| Base44 app-store-entitlement | canonical deployed bundle | 16 | 5 / 11 |

`candidate-summary.json` lists the target directories under
`.local/rewards238/prepared/`. Each target has a `*-manifest.json` containing
every before/after SHA256, exact entry point, live version/deployment ID, and
reviewed overlay list. The corresponding zero-context `*.patch` reconstructs
the candidate from its captured baseline. `patch-reconstruction.json` records
byte-exact reconstruction of all six packages. The canonical Base44 GET
snapshot at 01:34:46 UTC contains 22 deployed function bundles; its response and
per-file hashes are in `base44-live-snapshot-manifest.json`. The raw snapshot
is local-only with mode 0600. All unrelated deployed files remain byte-identical.

The app-services overlay includes the Unity/enrollment policy, enrolled
membership allowance, monthly billing plus optional verified Loyalty, and
prepared achievements/invitation features required by the current client.
The worker receives only the queued-invitation recheck; existing push transport
is preserved. Independent review and its own 30 checks are documented in
[`../monthly/profile-dependency-review.md`](../monthly/profile-dependency-review.md).
The separate full-game-core candidate is owned by the monthly package report.

Base44 deleteAccount changes only enrollment cleanup; the live Apple identity
and credential deletion helpers are preserved. The Base44 monthly package
updates its reviewed monthly/Loyalty files while preserving the other eleven
live files. No whole application export is a deployment input.

## Repairs and behavior

- The existing generation policy already enforced three free generations for
  enrolled accounts, but membership.check still reported ten. A real local
  database regression first failed `10 !== 3` (`membership-allowance-before.log`).
  It now verifies three, exhaustion, one signed Unity bonus, bonus consumption,
  old-account ten, rollout-off ten, and paid unlimited behavior.
- The public SSV entry still used transaction pooler port 6543 with max three
  connections. It now matches app-services' established session pooler 5432
  with max one connection. Prepared and committed callbacks keep their
  transactional, idempotent ledger behavior.
- Exact-package billing tests exposed missing profile projection of stored
  Loyalty. The prepared achievement and invitation dependency closure is now
  included. Public profiles expose bounded award progress, not billing IDs.
  Invitation opt-out/block rules apply on send, list, acceptance, inbox reads,
  and queued push delivery.

The fresh live app-services entry/router are preserved: the dedicated public
SSV endpoint owns provider callbacks. Dormant main-app Base44 push transport is
excluded because it is not enabled by the active client configuration. Three
source-only bridge cases are explicitly omitted in `verification-summary.json`;
this report does not claim that source suite's full 51 cases ran unchanged
against the preserved live transport.

## Validation

All final exact-candidate checks passed:

| Evidence | Passed |
| --- | ---: |
| `candidate-native-integration.log`: isolated PostgreSQL reward, enrollment, quota, signature/replay, deletion and recovery checks | 34 |
| `candidate-base44-integration.log`: real prepared entry handlers with an in-memory SDK/provider fixture | 16 |
| `candidate-gateway-tests.log`: public SSV verification, routing and delivery handling | 16 |
| `candidate-base44-monthly-tests.log`: monthly/weekly entitlement and canonical status rules | 24 |
| `candidate-profile-policy-tests.log`: achievement/privacy and invitation policies | 11 |
| `candidate-billing-community-tests.tap`: 48 in-scope billing/push tests plus 19 profile/community database checks | 67 |

Total: **168 exact-candidate checks, zero failures**. Three groups of strict
cached-only Deno entry-point typechecks passed. All six patches reconstruct
their complete manifests exactly. The preliminary verifier/ledger unit suite
also passed 19 checks (`verifier-ledger-tests.log`); its count is separate from
the 168 candidate checks. Earlier incomplete-package billing evidence is kept
in `candidate-billing-before-profile-overlay.tap`, not treated as final results.

The harnesses change imports to the actual prepared bundles and retain the
original assertions. Source-only dormant push helpers are loaded solely so
the legacy test module can define its excluded cases; the 48 executed billing
cases use the assembled billing and existing push implementations. Tests use
synthetic provider responses and isolated/local PostgreSQL fixtures. They do
not establish a real Unity impression/callback, a device reward, a production
monthly purchase, or acceptance of the assembled bundle by the live Edge
runtime. Existing Apple runtime repair evidence remains separate.

## Repeat locally

The scripts contain no cloud or Base44 CLI operation. From the repository:

```sh
python3 QA/app-store-complete-238/rewards/prepare-candidates.py
# Set REWARDED_TEST_DATABASE_URL to the existing local 127.0.0.1:56322 URL.
python3 QA/app-store-complete-238/rewards/verify-candidates.py
```

Use the pinned `experiments/supabase-game-core/node_modules/.bin/deno` 2.9.6.
Verification uses cached dependencies and allows network access only to
127.0.0.1 for the isolated native database suite. Other Deno tests deny network.
Node integration fixtures assert the local host/port and read local Supabase
status; they create and clean only synthetic test records. No credentials
belong in the checked-in commands or logs.

## Activation prerequisites and limits

`candidate-summary.json` pins the SHA256 of the new server-only Base44
GenerationRewardEnrollment schema and private native enrollment migration.
Install those before the corresponding deletion/generation code and before
enabling enrollment. They have not been applied by this preparation.

The three-free policy applies only after the rollout is enabled and a supported
account enrolls. Until then old accounts retain ten. An omitted or downgraded
client capability does not undo an existing enrollment. Credits require the
provider signature, exact issued attempt, correct game/placement, and durable
single-use settlement; client ad-completion events cannot grant credits.

No Unity-issued S2S secret was available to this preparation and real callback
activation is unverified. Support activation/secret delivery and real native
and legacy callback acceptance remain required. See
[`../../../release/REWARDS-AND-SERVICES-238.md`](../../../release/REWARDS-AND-SERVICES-238.md).
Monthly App Store metadata and checkout gating are covered by the monthly
report. No production action is authorized by these prepared artifacts.
