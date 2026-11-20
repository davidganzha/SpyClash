# Apple registration — prepared coverage activation, 20 November 2026

Status: prepared and locally verified; production registration remains disabled.

The production `apple-session` v2 runtime matches every file of the previously
reviewed package. The current login path supports new accounts, but both
`APPLE_NEW_ACCOUNTS_ENABLED` and `APPLE_MIGRATION_COVERAGE_VERIFIED` still hash
to `false`. They must not be enabled on the strength of the two-account pilot.

## Historical coverage

A complete read of 30 source credential records and 84 source users found two
bound Apple owners already migrated, plus 22 pending credential records whose
historical keyed email identifiers match distinct existing verified source
users. All 22 already have their original reserved Supabase Auth UUIDs, matching
private mailboxes, active profiles and completed data imports. Two have active
legacy links; 20 reservations remain `reserved`. None has a conflicting native
provider, deletion fence or extra source billing/reward/quota records.

Pending source credentials alone are insufficient to activate those identities.
The prepared temporary `verifyAppleCoverage251` function requires the app
administrator, a fixed private cohort and an expiry. It reads each exact source
revision and verified source user, checks their keyed identity association, and
authenticates the stored grant's encrypted identity/subject/client binding using
the existing server key. It returns provenance only; credentials and keys stay
on the source server. It has no entity-write or Apple-provider-call dependency.
Its deployment source, fixed targets, hashes and expiry are private artifacts.

Five other pending subjects have no current source-user match. No existing
account ownership is inferred for those unfinished attempts. Their historical
credential retention/revocation is a separate account-deletion release check;
this operation does not claim to complete real Apple revocation testing.

## Exact proposed operation

1. Base44 app `69a0e57fa939f578082f8091`: deploy and invoke the fixed temporary
   administrator verifier, verify the deployed source hash, then remove it and
   verify absence even if the verification fails.
2. After all 22 verifications succeed, compile the actual receipt into the
   prepared Supabase transaction for `bbkfsgnordtdiblgdzkg`. It adds 22 private
   Apple account mappings and snapshots, completes the 20 missing legacy links
   and marks their existing reservations ready. The existing two legacy links
   and the already accepted two native Apple accounts are preserved.
3. Read back all 24 Apple UUID mappings and readiness, unchanged profiles and
   Auth owners, and preserved Game Center/billing/reward records.
4. Set only `APPLE_NEW_ACCOUNTS_ENABLED=true` and
   `APPLE_MIGRATION_COVERAGE_VERIFIED=true`; verify both digests and preserve
   every other setting. No permanent function deployment is required.

The SQL is serializable, locks the relevant ownership tables, checks canonical
source reservations, active Auth/profile owners and completed imports, refuses
deletion/provider/subject conflicts, and verifies profile hashes remain intact.
It never writes managed Auth users or replaces profile/purchase/reward data.
An ownership conflict rolls back the whole cohort. Replaying the same verified
plan is idempotent. The actual source receipt must be at most 15 minutes old.

The provisional SQL refuses execution while its verification receipt is absent.
It must be recompiled from the actual server response, never a fabricated
receipt. Refresh source revisions and live ownership immediately before apply.
Production actions require the exact fresh approval described in `AGENTS.md`.

## Verification

- Eight new-registration scenarios passed against the downloaded production
  code and an isolated real local Supabase Auth/Postgres stack: both approval
  flags, first signup/onboarding, repeated authorization, refresh, parallel
  signup, cross-subject replay rollback, rejected code and provisioning recovery.
- Eight fixed-cohort verifier tests passed with networking and environment
  access denied, including admin/expiry gates, scope changes, source conflicts,
  failed decryption, private-error handling and incomplete-cohort rejection.
- Four actual local SQL scenarios passed with 22 disposable Auth users: blocked
  provisional execution, complete rollback on a final-owner conflict, preserved
  UUID/profile readiness, and idempotent replay.
- The verifier, both local integration scripts and Python compiler passed their
  type/syntax checks. The full offline authentication regression also passed.

These tests do not represent a real new Apple account signing in on an iPhone.
That remains a distinct acceptance check after activation. The previously
accepted existing-account login and relaunch in build 247 remain separate.

Private evidence and deploy payloads: `.local/apple-new-users-251/`. The SQL
compiler is `scripts/prepare-apple-coverage-import.py`; local integration suites
are under `experiments/supabase-game-core/tests/apple-session/`. Use only the
dedicated loopback Auth/DB environment; both suites reject cloud targets.
