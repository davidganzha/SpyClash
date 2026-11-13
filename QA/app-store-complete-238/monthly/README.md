# Monthly LIMITLESS candidate

Prepared locally on 13 November 2026. No Apple configuration, production flag,
server deployment, upload, or submission was performed by this work.

The new client selects `com.spyclash.ios.limitless.monthly` and validates a
one-month auto-renewable product. Both price displays still use Apple's
`Product.displayPrice`; no live price is fabricated. The period and renewal
copy use month/monthly in English, Russian, Spanish and Ukrainian. A weekly
product returned by an older server cannot authorize the monthly checkout.

Existing weekly transactions remain supported. Restore acknowledges only
verified canonical results, preserves account ownership, and does not purchase
monthly or transfer a subscription to another SpyClash account. Existing paid
access continues to block a second checkout; this change does not automatically
change an existing subscriber's billing period.

## Server contract

- Native verification uses a fixed weekly/monthly product allowlist. Both the
  submitted JWS and Apple's current status must identify supported products,
  the configured app/environment, the same original transaction chain and the
  same account binding. Crossgrades retain the exact submitted product in the
  response while storing Apple's current product, including its database column.
- Monthly preparation requires the existing master purchase gate and the
  additional exact string `SPYCLASH_LIMITLESS_APPLE_MONTHLY_PURCHASE_ENABLED=true`.
  Missing/false/malformed values disable new monthly checkout. Restore does not
  depend on either new-purchase gate.
- The legacy Supabase bridge requires that same monthly gate before calling
  Base44, and matches its preparation response against the requested product.
  Missing selectors retain weekly for older clients. Invalid explicit selectors
  are rejected without falling back to a different product.
- Base44's already-prepared monthly contract uses its own existing master gates
  and the same separate monthly flag. Its `APPLE_IAP_PRODUCT_ID` configuration
  remains the historical weekly ID; it must not be replaced with monthly.
- The X509, mixed-root, OCSP date and immutable-owner repairs remain in place.
  Optional verified Loyalty history accepts the same two supported products.

The Supabase overlay requires `native-apple.ts`, `membership.ts`,
`legacy-billing.ts`, `billing-rules/apple-subscription-status.ts`, and the new
`billing-rules/apple-products.ts`, plus their transitive dependencies. Shared
copies inside the `full-game-core` deployment must be updated too: its history
handler refreshes native membership. The separate rewards changes also add
membership dependencies on `generation-reward-ledger.ts` and `unity-ssv.ts`.

Base44's prepared monthly source consists of `entry.ts`, `apple-entitlement.ts`,
`apple-subscription-status.ts`, and `limitless-rollout.ts`, with optional Loyalty
history dependencies already present in the combined source. Release assembly
must reconcile these against the live bundle, retaining unrelated live fixes.

## Apple read-only evidence and remaining configuration

The ASC audit agent's 13 November snapshots in
`.local/release238-readonly` show the monthly product already exists with
`ONE_MONTH` and state `MISSING_METADATA`. Its current USA price is USD 2.99;
all 800 USA price points were read, and an exact USD 3.00 point was absent.
The candidate keeps that existing USD 2.99 price, approximately the requested
$3, rather than changing it. Other storefronts display Apple's localized price.
The local StoreKit fixture now uses USA/USD 2.99 and is test data only.

The monthly review image is absent in both the subscription and its version
relationship, and review notes are empty. Existing localizations are en-US,
es-ES and ru; Ukrainian is absent. The version is `PREPARE_FOR_SUBMISSION`.
Complete the approved review materials and submit the product with the intended
app release before claiming it is ready for public sale. Monthly gate activation
and both server deployments remain separate approved production operations.

## Validation

- `node-tests.tap`: 51 local Node tests passed, zero failures/skips. Includes
  native and legacy preparation gates, stable account tokens, original request
  replay, incorrect product rejection, weekly/monthly restoration and
  crossgrades, revoked access, immutable owners, and closed app/environment
  identity checks. The product/chain tests start at the verified SDK boundary;
  they do not substitute for the existing signed JWS/OCSP regression suite.
- `base44-tests.log`: 24 Deno tests passed, zero failures. Covers Base44's
  monthly selection, disabled-gate restore, current status, refunds and binding.
- `native-typecheck.log` and `base44-typecheck.log`: strict checks passed for
  native billing and the complete prepared Base44 entitlement entry.
- Swift syntax parsing and `git diff --check` passed. The updated unit tests and
  opt-in local StoreKit integration tests are prepared for the root release run;
  this report does not claim they have executed.
- `full-game-core-manifest.json`: local candidate has 51 files from the fresh
  44-file v16 response in `.local/full-game-core-exact.json`. The baseline was
  written from each raw content string without newline normalization. Four
  shared billing files changed and seven import dependencies were added; all
  40 unchanged files, including every `full-game-core/*` file, match the raw
  response byte for byte. The 11 overlay files retain their previously tested
  bytes. `full-game-core-typecheck.log` records a successful strict cached-only
  check. `full-game-core.patch` and both file manifests describe that exact
  baseline-to-candidate change; applying the patch reproduces all 51 candidate
  files byte for byte. The response identifies v16 bundle SHA-256
  `1b071b6680215b910239112072164993e93eb77c068efecbb4ab22de01115cce`.

Local tests establish contracts and rejection behavior. They do not establish a
real monthly Sandbox purchase, TestFlight restore, approved Apple product, or
public release. The full-game-core pool remains its existing transaction-mode
configuration; changing it was outside this billing overlay.
