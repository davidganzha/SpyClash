# Account-scoped deletion readiness for client 200

The public client remains 1.0.3 (200), source `da2e8584`. This backend checkpoint
204 changes readiness/configuration and adds regression evidence; it does not
replace the signed client or weaken runtime ownership checks.

## Reassessment of the four Apple records

All four unmatched archived Apple credentials still exist in the canonical
Base44 app. Their opaque identity/subject values match their archive copies.
They have no immutable user owner, remain pending and have encrypted credential
material. Each corresponding lifecycle is active and released, with its last
update adjacent to credential issuance on 19, 25 or 28 August. There is no later
tracked deletion transition. Narrow historical log queries returned no events.
These facts do not establish abandoned registration, a deleted user, revocation
or ownership by any current account. No such classification is asserted.

The current pseudonym key positively matches a historically bound credential
and 24 additional unbound records belonging to verified User aliases. Matching
records occur both before and after the four unmatched records. The selector
algorithm and namespace are unchanged since 26 July. No concrete key-version
mismatch, current-owner conflict or additional verified alias was found.

The earlier global stop was a conservative operational policy, not a requirement
of the account-scoped protocol. It is superseded here: readiness certifies the
positive historical-key compatibility test. It does not claim that every
credential in the entire database has an inventoried owner. The four records
remain untouched and unassigned. A concrete ownership conflict still blocks
the affected deletion request.

## Unchanged deletion boundaries

- The authenticated immutable Base44 ID must match the private Supabase link.
- Historical aliases come from archived User records for that ID and a signed
  server request; current alias reassignment and conflicting owners fail closed.
- A foreign nonempty credential owner takes precedence over selector equality.
- Only exact owned IDs/selectors enter revocation and archive erasure. Shared
  containers retain other participants and unrelated pending credentials.
- Durable provider receipts must confirm User deletion before Supabase erasure.
- No usable owned Apple token produces the existing manual-revocation notice;
  it is not a reason to refuse account deletion globally. Client 200 displays
  that notice after logout and already warns Apple subscribers about billing.

This follows [Apple TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)
and [account deletion guidance](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion).
[Base44 auth.updateMe](https://docs.base44.com/developers/references/sdk/docs/interfaces/auth#updateme)
does not permit ordinary changes to immutable ID/email. No historical
administrative/provider merge behavior is inferred from that restriction.

If a canonical old-address credential is later positively linked to a current
account, investigate and handle that exact ownership before declaring its
deletion complete. An unrelated unassigned row is not itself such evidence.

## Exact authorized activation

The previously approved public-server package includes these two settings:

1. Original Base44 app `69a0e57fa939f578082f8091`:
   `APP_DELETION_ARCHIVE_KEY_VERIFIED=true`; expect public deletion capabilities
   protocol `spyclash-deletion-receipt-v2` from `deleteAccountPublic`.
2. Main Supabase `bbkfsgnordtdiblgdzkg`:
   `APP_MAIN_ACCOUNT_DELETION_ENABLED=true`; preserve all other values, secrets,
   source graphs and the existing maintenance schedule.

There are no pending deletion intents before activation. This action creates
no deletion request and does not refresh/revoke/delete the four Apple records.
No change to the original `deleteAccount`, editor drafts, billing products or
the frozen client is included. App Review submission is a later separate step.

## Verification

Eight focused prepared-module tests pass, including two new regressions: own
bound/exact-selector pending tokens are removed while an unrelated unbound
pending token stays byte-for-byte intact; no-owned-token deletion completes its
durable receipt only after User removal and retains the manual-revocation flag.
The 116-check checkpoint-203 source verification remains applicable to unchanged
runtime source. Production account deletion, real Game Center login, purchase
and paid AI generation are not established by these fixture tests.

The checkpoint-204 source package has SHA256
`63e480155ac5830c948831523a69235b1125e3d60bbc59fa89731e83c9ec77a2`.
Comparison against the verified checkpoint-203 manifest found exactly one
changed file: the focused test above. No runtime source, dependency graph or
frozen engine/push/worker/policy file changed. The eight tests also pass from
the relocated package, exercising its actual prepared modules.

## Activation readback — 27 October 2026

- Base44: one exact immutable-owner historical probe passed at 15:26 UTC;
  no pseudonym key was read/exported. After the single-key setting, capabilities
  returned 200/v2 and an unsigned request returned 403. All four credential and
  four corresponding lifecycle full-row hashes are unchanged. The existing 47
  secret names are preserved; single-key merge semantics preserve other values
  without exporting them. No Base44 function or editor draft was changed.
- Supabase: exactly `APP_MAIN_ACCOUNT_DELETION_ENABLED` changed among 31 listed
  digests, and its new digest equals `true`. All other digests are unchanged.
  Runtime versions are app-services16, full-game-core12, game-center-session4,
  legacy-session7 and bulk-legacy-migration5; all five source hashes and JWT
  verification settings are unchanged and all functions are ACTIVE.
- Before enabling there were no deletion intents. The maintenance schedule
  remains active. Wrong-worker request returns 401; the authorized empty request
  returns 200 with originalDeletion.configured=true and zero attempted/completed
  original/native deletions. Scheduled responses at 15:34 and 15:35 UTC also
  returned 200 without timeout/error. Push delivery remains disabled.
- Security advisors contain no ERROR; the pre-existing leaked-password
  protection warning remains outside this change. No new privileges or schema
  changes were introduced.

Sanitized readbacks are in `.local/public-deletion204`; the provenance report is
`.local/apple-unmatched-provenance/PROVENANCE-REPORT.json`. Private source rows,
secrets and demo credentials are ignored and must not be committed or printed.

## App Store readiness

Fresh Apple readback confirms main app6793534085, version1.0.3 in
PREPARE_FOR_SUBMISSION, attached build200 VALID and APP_STORE_ELIGIBLE, Game
Center enabled and MANUAL release selected. The five en-US screenshots are
complete. The weekly product used by client200 is APPROVED; an unused monthly
draft is not part of the client catalog. Required contact/demo fields are
populated; one actual demo login and authenticated User read passed with no OTP.
An independent existing-admin read matched exactly one verified demo User with
role `user`; it is not the administrator account excluded from full deletion.
Published privacy labels include User ID, purchases and gameplay; the policy
URL resolves to the current policy. Age ratings are populated. The Apple UI
shows free/paid agreements and DSA compliance Active. No questionnaire,
agreement, product or metadata was modified in this verification.

The existing subscriber deletion warning is displayed above the profile's
deletion controls. No missing-warning client patch is required.

An existing correctly signed Simulator build200 was installed in a new isolated
Simulator `487ABDDD-98AD-461B-B661-CE4AEC27E02E`; the user's existing Simulator
and session were untouched. Its `supabase-public` bundled configuration matches
the signed App Store archive byte-for-byte. Source and installed signature gates
passed, as did 15 installer-gate fixtures. No source change, rebuild or resigning
was required. The actual app passed classic fallback login with the reviewer
demo account, hybrid profile restoration, normal English onboarding completion
and Home display. Terminate/relaunch returned directly to Home without repeating
onboarding. No Keychain identity/storage-failure warnings were found. The new
Simulator was shut down preserving its QA state. The demo account's normal
onboarding completion was the only profile initialization during this check;
no gameplay, messaging, AI call, purchase or account deletion was performed.

Simulator evidence is under `.local/appstore200-review-current/simulator`, with
`QA-RESULT.md`, `QA-RESULT.json`, screenshots and sanitized log summaries. This
is real classic-auth/onboarding verification against the main backend, not
physical-device Game Center or StoreKit acceptance.

At this checkpoint App Review had not yet been submitted. The user subsequently
confirmed the exact version/build, and Apple accepted 1.0.3 (200) on 27 October
2026. See [the submission record](APP-REVIEW-SUBMISSION-200.md). Publication
remains manual after approval.
