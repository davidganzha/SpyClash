# SpyClash 1.0.4 (238) — integrated App Store candidate

Prepared on 13 November 2026 from `cad3156f`. This is a signed, Apple-validated
candidate, not an uploaded or publicly released version.

## Included

- Monthly LIMITLESS checkout using StoreKit's localized price. The current USA
  product is USD 2.99 for one month. Existing weekly purchases remain restorable.
- The subscription delivery and verification repairs through build 237.
- Unity reward integration: three daily free generations for enrolled accounts,
  then one generation per verified completed ad. Active LIMITLESS is unlimited.
  Old clients/accounts retain their legacy allowance until supported enrollment.
- Previously prepared FAN/gameplay, synchronization and authentication changes,
  plus four missing completed UI changes: continuous online intro, compact game
  controls, 50 searchable localized theme ideas and readable word cards.
- Existing newer social invitation presentation retained. Prepared server
  achievements and invitation preferences now include their full dependencies.

[Source inventory](source-inventory.md) distinguishes integrated, superseded,
disabled experimental and unfinished dirty-worktree changes.

## Validation

- Signed distribution archive and exported IPA: release gates passed.
- Apple `validate-app`: passed with no errors. This did not upload the build.
- Full unit run: 878 passed, seven skipped and one stale fixture failed; the
  corrected eight-test survey suite then passed. Across the final checked cases,
  879 unit tests passed. The earlier six failures from stale capabilities,
  word splitting and onboarding expectations were repaired in tests only.
- Five relevant UI scenarios passed across the intro run and final header run.
- Four public-release configuration tests passed.
- 81 release-package fixtures and 25 Python script checks passed.
- Exact prepared backend bundles: 168 tests passed, strict typechecks passed;
  seven-file profile/invitation overlay independently passed 30 checks.
- Full-game-core prepared dependency bundle: strict typecheck passed and exact
  unchanged live files preserved.
- Website privacy candidate: 147 tests and production build passed; commit
  `36f61fbc` on `davidganzha/app-store-privacy-238`, not published.

Six opt-in local StoreKit transaction tests stopped at the synthetic canary with
`notEntitled` before app purchase; these are **not** successful purchase tests.
They remain an explicit local environment limitation, preserved in the first
test report. The later broad unit run skipped them; it also skipped one
environment-dependent case. Do not count skipped cases as acceptance.

The public runtime installation and startup evidence are recorded separately.
No actual monthly TestFlight purchase/restore, Game Center entitlement sharing,
or real Unity server callback is claimed by these checks.

## Artifacts and deployment preparation

See [artifact.json](artifact.json) for the IPA path, hash and archive.
The native source hashes bind the archive to the reviewed source snapshot.

- [Monthly and full-game-core package](monthly/README.md)
- [Reward and app-services packages](rewards/README.md)
- [App Store metadata draft](../../release/APP-STORE-238-METADATA.md)
- [Deployment order and remaining gates](../../release/APP-STORE-238-RELEASE-PLAN.md)

## Tooling incident, resolved

A mistaken Base44 `eject --yes` command created a separate SpyClash Copy and
partially deployed it. After disclosure and the user's exact approval, that
copy was deleted; its readback returns 404. The canonical app remains accessible
with unchanged update/publication markers and unchanged pre-snapshotted function
files. See [incident.md](incident.md) and [cleanup receipt](copy-cleanup-receipt.json).
The copy/export was excluded from all deployment candidates.
