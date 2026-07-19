# Managed Base44 site patches

The published SpyClash web client is managed in Base44 and is not exported into
this repository. This directory records small, release-critical sandbox changes
so they remain reviewable alongside the native and backend code.

Apply patches from the Base44 app root, verify them in the remote sandbox, and
only publish after a separate production-release approval.

## 2026-07-16 LIMITLESS price

- App ID: `69a0e57fa939f578082f8091`
- Pre-change checkpoint: `6a5811e689428f7e783fd4c7`
- Checkpoint git hash: `6e515e16fd2193880cfd3230f6063f7cbf2f4893`
- Patch: `2026-07-16-limitless-weekly-price.patch`
- Validation: remote sandbox `npm run build` passed and no `$3.99` remained.
- Production status: published and verified on 2026-07-16. The live web client
  exposes `$2.99` and no longer contains `$3.99`.

## 2026-07-16 push and Live Activities privacy disclosure

- App ID: `69a0e57fa939f578082f8091`
- Pre-change checkpoint: `6a58c8fc53834a7b0ee3c163`
- Checkpoint git hash: `7f08e955b24ea0bf16bb570903a9b3821adff950`
- Patch: `2026-07-16-push-privacy-policy.patch`
- Reason: disclose the push-device and Live Activity identifiers introduced by
  the notifications release.
- Validation: remote sandbox `npm run build` passed and the updated policy was
  read back successfully.
- Production status: published and verified on 2026-07-16 at
  `https://spyclash.com/privacypolicy`.

## 2026-07-16 public legal and support routes

- App ID: `69a0e57fa939f578082f8091`
- Pre-change checkpoint: `6a59049c82c09d1f3436cf7b`
- Checkpoint git hash: `a2d561e2662d425e919dfdaf444b5d0720be3c5d`
- Patch: `2026-07-16-public-legal-support-routes.patch`
- Reason: App Store review, privacy disclosure, subscription help, and account
  deletion guidance must remain available without an authenticated web session.
- Validation: remote sandbox `npm run build` passed. The production
  `/privacypolicy` and `/support` routes return the expected public content.
- Production status: published and verified on 2026-07-16. A monitored support
  email still needs to be configured before App Review submission.
