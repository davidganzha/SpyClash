# Build 178 delivery and backend execution — 2026-10-17

The user explicitly approved updating only `checkSubscription` in Base44 app `69a0e57fa939f578082f8091`, and signing/uploading main SpyClash 1.0.3 (178) as TestFlight Internal Only for David and Dima. Source remains the verified, pushed commit `905c110ca64caef5af1ba72360eb71a4d0380ca6`. This execution report supplements the earlier [preparation report](APPLE-LIMITLESS-178.md).

## Current result

- **Build 178 has not been signed or uploaded.** Compilation/precompilation succeeded. The existing Apple Distribution private key cannot currently perform a signature because the login keychain fails operational unlock/decryption. The user uses Touch ID and has not supplied a local credential. No keychain reset, ACL change, private-key export, certificate replacement, logout or restart was performed.
- **LIMITLESS remains unresolved.** Base44 accepts and returns the modern `checkSubscription` source, but credential-free public GET/POST calls still return the old `200 {active: false}` contract instead of 405/401. An affected-account reconciliation or purchase was not attempted.
- **The original Apple device failure remains unresolved.** Build 178 retains the full, persistent support-code alert needed to identify the native handoff branch. Current broker protocol probes pass 12/12; that does not prove successful Apple login on a phone.
- **A temporary backend incident was recovered.** Sandbox synchronization unexpectedly reduced the function inventory from 17 to 5. After separate explicit user approval, the other 16 functions were restored. The final inventory is 17, all restored handler/helper bytes and automation metadata match the saved versions, and the Apple broker again passes 12/12 probes.

## Backend execution and recovery

The initial named `functions deploy checkSubscription` was skipped as unchanged. A comment-only rebuild marker then produced a successful single-function deployment, and all eight readback hashes matched. Public runtime behavior nevertheless stayed old.

Read-only sandbox inspection found an old 1,110-byte Stripe-only handler matching that public behavior. The user explicitly granted the additional Base44 `sandbox:write` OAuth scope. Following the installed Base44 Sandbox instructions, seven reviewed helpers were written and their exact remote SHA-256 values checked before the entry was replaced. All eight remote files matched the reviewed package. A checkpoint was saved: `6ad3bba946db5d9dc56e71b6`, commit `7cdade8a55e05ddc37a3fd0644694d6963bc117a`.

Despite restricting writes to `base44/functions/checkSubscription`, Base44 synchronized its stale five-function sandbox inventory over the 17-function management inventory. At 18:19:52 UTC, all twelve credential-free Apple probes returned 404. Further sandbox writes were stopped, the user was informed, and a concrete restoration package was prepared and verified before asking for permission to restore the other sixteen functions.

The user explicitly approved that restoration. The package used the complete retained 2026-10-13 API snapshot, with the Apple broker replaced by the later approved build-176 code, independently matched to the build-177 readback. Google 175 changed only hosted frontend assets. The restoration package contained 194 files; every byte and relative import was verified. Its frozen manifest SHA-256 is `d155ea963c6a3162bc0faaa917304bb03db6d1223a9fb2ca512648f15d552901`.

The named sixteen-function deployment finished with **15 deployed, 1 unchanged**. No broad deployment, site publication, secret update or rollout-flag change was performed. At 18:24:03 UTC the Apple broker again passed all 12 probes. Management readback confirmed all 17 functions and all sixteen restored handlers/helpers/automations. Base44 normalized `appleAuthCallback/main.ts` to byte-identical `entry.ts` and omitted the unreachable `headers_test.ts` fixture; 193 files are returned. This representation difference is explicitly preserved in the verification evidence rather than described as strict package equality.

**Do not write to the stale remote sandbox again without reconciling its complete inventory first.** Its automatic synchronization can prune functions outside the edited directory. The recovered management inventory and the stale sandbox inventory are distinct states. Future work must preserve the recovered functions and use scoped, named operations.

The final billing probe after restoration, at 18:27:09 UTC, still returned old `active`-only 200 responses on all three public routes. The eight modern source hashes remain present in management readback. No relaxed validator, free-access fallback or speculative authentication change was introduced.

One further bounded delivery diagnostic was prepared and deployed through the named CLI operation only: a fixed `X-SpyClash-Contract-Version: 178` header on the existing 405 response. POST, authentication, membership and purchase behavior were unchanged. The [official compiler](https://github.com/base44/cli/blob/main/packages/functions-compiler/src/deno-bundle.ts) minifies its output, so a comment-only marker does not guarantee a changed executable artifact; the observable response header does. This public source supports the diagnostic choice but does not prove which compiler revision production runs.

The actual-handler/bridge suite passed 17 steps with no network/environment permissions, and the real-SDK typecheck passed. The single-function deployment reported one deployed in 4.7 seconds. At 18:33:36 UTC, management readback contained the exact eight candidate files (entry SHA-256 `774fc79afa99bbc1cd4e9b591bfb6d912dc86fe41df78661c3c6827d2c2d7325`), all seventeen function entries, and unchanged restored handler/helper/automation content for the other sixteen. Deployment ID: `019f6954a4b54622aadd3de5bdcc9d25`. The Apple broker still passed 12/12 runtime checks.

Nevertheless, all six credential-free billing probes still returned 200 with only `active`, with no new header. This attempt did not repair the runtime. Read-only checks also found source/runtime disagreement in three other original sandbox functions, no duplicate legacy function directory, and no recent unfiltered runtime logs. The platform serving inconsistency remains unresolved; no further speculative production edits were performed. The tracked [deployed-entry patch](evidence/full-app/build178/delivery/checkSubscription-deployed.patch) reproduces the exact final entry from the earlier candidate.

## Signing and TestFlight boundary

The immutable signing snapshot is recorded locally in `.local/apple-limitless178/signing-paths.json`. App and widget are 1.0.3 (178), target team is `3Z64QKNL54`, and the export configuration specifies TestFlight Internal Only. Read-only App Store Connect preflight found build 178 absent and the private LIMITLESS Internal QA group containing exactly David and Dima, with automatic build access off.

The signed archive fails at widget codesigning with `errSecInternalComponent`. A separate tiny-file signing probe using the explicit login keychain fails too, so this is not an app compilation error. Public certificate enumeration succeeds, but keychain settings/ACL reads fail with `errSecAuthFailed`. Current logs show a prior failed `SecKeychainLogin`/keybag unlock and subsequent decoding/authorization failures. Keychain Access's apparent unlocked state does not establish usable private-key access.

The user normally unlocks through Touch ID. Do not restart or log out if the user does not know the Mac login password: [Apple requires password entry after startup](https://support.apple.com/en-la/102356). Do not reset the keychain or replace the signing key to bypass this failure. Local user authentication must be resolved before repeating the minimal signing probe, finishing the signed archive/export, auditing the IPA, uploading, checking processing, and assigning exactly the approved internal group.

## Evidence

Sanitized execution, restoration, runtime and signing evidence is in [delivery](evidence/full-app/build178/delivery/). Detailed local packages and raw receipts remain under `.local/apple-limitless178`; no credentials or private-key material are included in the tracked evidence.

No TestFlight availability, real-device Apple login, real linked-account membership refresh, purchase or restore acceptance is claimed.
