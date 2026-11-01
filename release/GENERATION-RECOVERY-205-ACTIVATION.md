# Generation recovery 205 — production activation

Date: 2026-11-01. The user explicitly confirmed the exact commit, migration,
Supabase function and delayed Base44 function deployment in the current chat.
Approved implementation: `3265a0d357abc6a6ac97138014263133e777dfba`.

Status: **both approved server deployments complete and read back verified**.

## Artifact and preflight

The prepared manifest hash is
`d1c05914eb9abc0c440fa86ddfbf3e4017758aeeb284a9e126934e65565b0c51`.
All 156 listed files matched their hashes. A fresh read of Supabase v16 and a
fresh pull of all six Base44 relay files matched the reviewed baseline. An
independent agent verified the exact source scope and preserved live-only files.

## Supabase activation

Target: `bbkfsgnordtdiblgdzkg`.

- Applied the exact reviewed `native_generation_failure_recovery` SQL. The
  management API recorded migration version **20261101132351**; the reviewed
  local source is `20261101130901_native_generation_failure_recovery.sql`.
- Deployed only `app-services`, from v16 to **v17**, with `verify_jwt: true`.
- Bundle SHA256:
  `c33d89c7d5ce9d85bd3068dc084e2029abcab481bbc10aeebdad192de4cdbd0a`.
- Read-back verified all **68 files byte-for-byte**, independently checked by a
  second agent. The live-only push, worker and game-engine files were preserved.
- ACTIVE/source verification time: **13:24:29 UTC / 14:24:29 Europe/Paris**.
  Base44 must not be deployed before **13:34:29 UTC / 14:34:29 Europe/Paris**.
- The new column and both validated constraints were read back. RLS remains
  enabled; anon/authenticated have no SELECT, INSERT or UPDATE privilege on the
  private provider-call table. Advisor results were unchanged from preflight.
- Unsigned `/claim`, `/complete` and `/fail` requests all returned **401
  `invalid_relay_request`**, including passage through the JWT gateway with the
  public anon key. No provider work was invoked by these negative probes.
- Initial versioned logs showed v17 maintenance responses HTTP200 and the
  expected rejected probes. Existing generation rows were left untouched.

## Base44 activation

The drain ended at **13:34:49 UTC**, 10 minutes 20 seconds after v17 source
verification. The available versioned logs for that interval contained only
v17 (13 requests, no 5xx); there were zero active generation leases. Supabase v17
and the fresh Base44 baseline were checked again immediately before publication.

Target: Base44 app `69a0e57fa939f578082f8091`, function
`nativeGameCenterWordPack` only. The isolated CLI deployment reported **1
deployed**, confirmed at **13:35:51 UTC / 14:35:51 Europe/Paris**.

All six runtime files were pulled back and matched the approved candidate
byte-for-byte at **13:36:14 UTC**, also independently verified by a second agent.
The changed file hashes are:

- `handler.ts`:
  `72105336abcb7b20753faa55cc998a4b2b7aac405491c34b8cf8f5a48a0d90c0`
- `relay-protocol.ts`:
  `468fd0dce940a62b6892103c5e86ea84d1f698aea97dd94fc0ccc40950039c9f`

The actual `spyclash.com` relay endpoint rejected an unsigned request with
**401 `invalid_relay_request`** at 13:36:01 UTC. This validates live routing and
fail-closed authentication, not a paid AI generation. No invocation, account
reset, or deletion was used for verification.

The final available log window, 13:34:49–13:37:09 UTC, contained successful v17
maintenance responses and no app-services errors. Generation state counts still
matched the pre-deployment baseline: one completed, one terminal unknown and
two expired pending attempts. These historical rows were not reset by deployment.

## Acceptance boundary

No client binary, App Store/TestFlight entry, secret, account or stored provider
claim was reset. Real authenticated iPhone generation remains unverified.
Already-local 409 recovery still requires the original inputs to reach the
server; the server cannot erase the installed client's durable journal remotely.
See `GENERATION-RECOVERY-205.md` for the tested recovery behavior and rollback
restriction after any new failed provider record is written.
