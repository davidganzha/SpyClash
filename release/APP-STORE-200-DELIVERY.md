# SpyClash 1.0.3 (200): App Store delivery and public backend preparation

The public client was uploaded to the original SpyClash app and attached to
version 1.0.3 on 27 October 2026. Apple processed build 200 as `VALID`. The version
is `PREPARE_FOR_SUBMISSION`, with `MANUAL` release; no App Review submission or
public release has occurred. Build 200 is assigned to none of the three existing
TestFlight groups. The requested delivery route is App Store, not internal beta.

## Verified Apple artifact

- App: `6793534085`; bundle: `com.spyclash.ios`; team: `3Z64QKNL54`.
- Frozen client source: `da2e8584f437f5fd91c2fdb4bffce2e692c1c0fa` in the separate
  `game-center-main` checkout. The signed client still has build number 200.
- Public scheme/configuration: `SpyClash-Supabase-Public` / `SupabasePublicRelease`.
- Game Center enabled on the main Bundle ID and App Store version.
- New App Store profile `QJQ4VM7X82`, named
  `SpyClash App Store Game Center 2026-10-26`, UUID
  `90ce7b7b-a955-4512-a138-40e268f6a78e`. Its main identifier, Apple Sign-In,
  production push and Game Center entitlements were checked before installation.
- Signed archive and exported IPA both passed the unchanged release bundle gate.
  Apple archive validation and upload completed without errors.
- IPA SHA256: `f2ad7bd7a2e7101258bd8546f3def7c9a93f329e70db97a6c1cd612208abe99c`.
- Upload/build ID: `049e9931-16d7-4203-a65f-aa9d2972830e`.
- Version ID: `6c6d03d7-8b84-4ed1-b315-7cf6acb9c5b2`.

The owner accepted the updated Paid Applications Agreement in the browser;
readback shows Active. Existing review contact and login fields were retained.
English release notes and review instructions describe Game Center, standard
sign-in, account-scoped first-time onboarding, weekly LIMITLESS and deletion.
Existing App Privacy declarations include the relevant linked identifiers,
purchase history, game/user content, interaction and diagnostic categories.
No new privacy-label categories were published by this work.

## Public server follow-up: checkpoint 201

The public route requires full legacy-account deletion and a working provider for
native Game Center AI. The previous candidate overlay disabled legacy deletion,
and the main server had no direct OpenAI key. This separate backend checkpoint
adds the public deletion protocol and reuses Base44's existing managed AI service.
Its project version is 201 to comply with the repository checkpoint rule; this
does not alter or replace the uploaded client build 200.

The exact local package is produced by `scripts/package-main-game-center.py
--public`. It pins the live `app-services` v10 and `full-game-core` v7 baseline
exports and preserves the live engine, push, worker and Live Activity policy
byte-for-byte. It includes only the three Supabase function dependency graphs,
four additive private migrations, the prepared Base44 `deleteAccount`, new
`nativeGameCenterWordPack`, and private `AccountDeletionReceipt` schema.

The main targets remain Supabase `bbkfsgnordtdiblgdzkg` and Base44
`69a0e57fa939f578082f8091`. The separate 0000 app/server are unchanged.

The exact public source overlay passed 98 checks (31 native identity/generation,
11 billing, 15 frozen-engine and 41 deletion/relay), with zero failures. Two
unshipped host-transfer cases remain deliberately filtered. All 109 production
file comparisons and four frozen-file hashes passed. Tested archive SHA256:
`78ea8088294e2b60de5c7118d7dae7c92d13a809b7148fe76d48e4081e7b1bfd`.
The archive records its starting Git parent; per-file hashes bind the prepared
source, and the checkpoint record relates those hashes to the resulting commit.

- [Deletion protocol, historical selector probe and rollout](PUBLIC-ACCOUNT-DELETION-SERVER-201.md).
- [Managed AI protocol, configuration and retry limits](../experiments/supabase-game-core/NATIVE-AI-RELAY.md).
- Prepared website change: `experiments/supabase-game-core/base44-prepared/privacy/PrivacyPolicy.jsx`.
  This is one file plus baseline/prepared hashes, not a website deployment.
- The existing local Apple key successfully authenticated read-only App Store
  Server API requests in Production and Sandbox. An invalid-signature control
  failed with 401; authenticated unknown transactions returned 4040010. This
  proves key authentication, not a real purchase/restore reconciliation.
- Supabase CLI was connected with the owner's explicit approval. No Supabase or
  original Base44 production configuration was changed during this preparation.

Before enabling public server behavior, the expanded Base44 functions, server
credentials, historical-key verification, maintenance schedule and website policy
need their exact production action approval. Preserve all existing secrets and
legacy behavior unless explicitly listed in that approved operation. No direct
OpenAI key is required for the selected managed provider.

## Unexpected Base44 CLI side effect

`base44 eject --yes` was invoked to download the original website source. Despite
its help describing a code download, the command also created a new cloud app,
linked the download to it, and started deploying the copy. The process was
interrupted immediately after its deployment behavior was observed.

The new app is `6adfe56fadd4564bb402fcbd` (SpyClash Copy). CLI implementation and
the generated local link both identify that new app as the deployment target.
Fresh original `deleteAccount` source and every support module matched the
preincident read-only snapshot. No claim is made that the unrequested copy was
deleted or that it should be retained. It is not a release target. Never deploy
its generated configuration or use it to update the original website.

## Remaining acceptance

Local unit/integration results and Apple artifact processing do not prove a real
Game Center session on an iPhone, a StoreKit purchase, paid managed AI availability
or live full-account deletion. These must be checked against the final enabled
backend. Do not submit App Review or declare public availability from upload
status alone.
