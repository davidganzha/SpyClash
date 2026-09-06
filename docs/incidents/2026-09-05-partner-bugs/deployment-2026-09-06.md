# Production server hotfix: 2026-09-06

The user approved the previously specified two-function server hotfix with “Обнови пока что сервер” in the current chat. The operation completed successfully at approximately **07:03:57 UTC / 09:03:57 Europe/Bratislava**. This approval covered this deployment only.

Target: SpyClash Base44 app `69a0e57fa939f578082f8091`.
Verified source checkpoint: `6b94e17a0fcdca4719e5b1727315e88cf747e59c`, branch `davidganzha/partner-bugfix-143`.
Deploy root: `/tmp/spyclash-backend-hotfix-143-iBQKJC/deploy`.

The targeted command was `npx base44 functions deploy gameRoomAction pushNotificationAction`. CLI exit status was 0:

```text
Found 2 functions to deploy
[1/2] Deploying gameRoomAction...
gameRoomAction deployed (30.9s)
[2/2] Deploying pushNotificationAction...
pushNotificationAction deployed (9.1s)
2 deployed
```

## Verification

- Authentication was verified before deployment. A new pull of all 17 functions passed the committed baseline guard: 75 runtime files and both targeted function configurations matched the reviewed baseline. The isolated candidate also passed its guard.
- A fresh pull after deployment matched every candidate SHA-256: **48/48 `gameRoomAction` files and 27/27 `pushNotificationAction` files**. Both configurations matched after normalizing only the source entry path to `entry.ts`.
- Independent comparison confirmed the other **15 functions, 114 runtime files and their configurations were unchanged**. Function inventory remained 17 → 17.
- The existing push drain automation was unchanged: active, every 15 minutes, `limit: 64`.
- Only the five runtime changes listed in [the deployment scope](backend-deployment-scope.md) were introduced. No broader integration-branch deployment was performed.
- Immediate logs for the two deployed functions, `generateWordPack` and `wordPackAction`, queried since 07:03:57 UTC returned no matching records. This provides no new live-game acceptance evidence.

Raw local CLI evidence and the before/after pulls are under `/var/folders/4j/wkjrm6cn0z9f5v932wqlmfz40000gn/T/spyclash-approved-143-ehpo6a61/` (`deploy.log`, `preflight/`, `postflight/`, `postflight-logs.log`). These temporary files may expire; the committed [manifest](backend-runtime-manifest.json) and [patch](backend-incident-only.patch) retain the reviewed runtime identity.

## Remaining acceptance

The server now contains the fix for abandoned in-flight work and account writer leases. Actual storage failures still use the existing logged-release-error/lease-expiry behavior. Local regression results are recorded in [the incident report](README.md).

No authenticated room, paid generation or user data mutation was performed as a smoke test. A real session must still verify join/rejoin, generation and regeneration at different counts, pack save, and room close. QR, word-card and Radar iOS fixes remain in local Build 143; no physical-device installation, TestFlight or App Store release occurred in this deployment.

This follow-up checkpoint changes documentation only; iOS version values remain 1.0.1 / 143.
