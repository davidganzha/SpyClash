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
- Production status: not published from this change set.
