# Base44 CLI eject incident — 13 November 2026

During preparation, the rewards agent mistakenly treated `base44 eject` as a
read-only download. The command was:

```text
npx --no-install base44 --app-id 69a0e57fa939f578082f8091 eject --path .local/rewards238/base44-eject --yes
```

This was not an authorized production action. CLI help described eject as
“Download the code for an existing Base44 project” and `--yes` as “Skip
confirmation prompts”. The agent did not inspect the implementation before
using that flag. The implementation downloads the source, creates a new cloud
app, switches its app context to the new ID, and interprets `--yes` as consent
to install/build/deploy the copy. The agent stopped the process with Ctrl-C
when deployment output was observed; the process returned exit status 130.

## Confirmed impact

- Source app: **SpyClash**, `69a0e57fa939f578082f8091`.
- Created app: **SpyClash Copy**, `6af667285effbfd6f111af93`.
- Copy creation: `2026-11-13T01:26:00.574Z`; local link written at 01:26:01 UTC.
- Copy last update observed: `2026-11-13T01:26:31.896Z`.
- Copy contains 27 custom entity schemas plus the User schema (28 CLI items).
- Six functions were deployed to the copy: `advanceRound`, `autoRegisterUser`,
  `checkSubscription`, `deleteAccount`, `createCheckout`, `mobileAuthCallback`.
- The copy's `last_deployed_at` and deployment checkpoint are null. No site
  publication step was reached. Its payment integrations and installed
  integration context were empty. No Stripe connector setup step was reached.
- No cloud cleanup was attempted. The copy remains pending a separate decision.

The installed CLI source at
`/opt/homebrew/lib/node_modules/base44/dist/cli/index.js:258143` downloads the
selected source; lines 258147–258152 create/link the copy and set its app context.
Lines 258161–258172 turn `--yes` into a deployment decision. The deploy order is
entity schemas, functions, agents/auth/connectors, then site; interruption
occurred during the function stage. No entity-record copying operation appears
in this command flow. This is a source-code observation, not an exhaustive
audit of every possible platform-side effect.

## Read-only verification and limits

Process inspections at 01:28:20 and 01:31:39 UTC found no remaining Base44,
eject, or deploy processes; only the audit commands matched the process search.
Authenticated HTTP GETs at 01:29:47–01:31:39 UTC confirmed the app IDs and state
above. Tokens, function bodies, and private user records were not included in
the audit output.

For the original app, all **41 files** in the three complete preincident
function snapshots were byte-identical to the later GET response:
`generateWordPack` (18), `generationRewardAction` (8), `deleteAccount` (15).
The original app's `updated_date` remained `2026-11-11T22:37:59.427`, its
`last_deployed_at` remained `2026-10-27T14:15:16.646`, and its published
checkpoint remained `6a59049c82c09d1f3436cf7b`.

The eject archive is a builder export, not a complete snapshot of the deployed
function sources. It cannot establish a before/after comparison for all 22
original functions. 24 of 27 custom schema JSONs matched that export; the live
GameHistory, GameRoom, and WordPack retained additive fields missing from the
export. This is consistent with export drift and does not demonstrate a
change caused by this incident. No claim of an exhaustive original-app audit
is made.

## Evidence and subsequent preparation

The tool transcript contains the command, partial deployment output, exit 130,
sanitized remote audit, and source inspection. Original preincident function
snapshots remain under `.local/rewards238/live-base44/`; the accidental copy's
local files remain under `.local/rewards238/base44-eject/`.

After the parent stopped the task, work resumed only on local candidate
packaging from the already downloaded live snapshots. The eject archive is
excluded from all deployment candidates. No Base44 CLI commands, cloud
cleanup, production deployment, migration, secret/configuration change, or
Unity message is authorized by this preparation.

## Resolution

After the user explicitly approved removal of only the accidental copy, the
parent agent deleted `6af667285effbfd6f111af93` at 01:39:04 UTC. The recorded
response was HTTP 200; a subsequent GET returned 404. The original app returned
200 with unchanged update and publication metadata. See
[`copy-cleanup-receipt.json`](copy-cleanup-receipt.json). This resolved the
accidental copy; it did not authorize publishing any release candidate.
