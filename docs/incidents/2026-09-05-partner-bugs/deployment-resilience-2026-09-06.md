# Production contention and conflict recovery update: 2026-09-06

The user approved the exact previously specified `gameRoomAction` and `generateWordPack` deployment with “Подтверждаю” in the current chat. Deployment completed at approximately **07:47:43 UTC / 09:47:43 Europe/Bratislava**, based on the completed CLI log timestamp; exit status 0 was confirmed at 07:49:09 UTC. This approval covered this operation only.

Target: SpyClash Base44 app `69a0e57fa939f578082f8091`.
Verified source checkpoint: `3009f6388010e16336829a8ed98b98256330eea7`, branch `davidganzha/partner-bugfix-143`.
Deploy root: `/var/folders/4j/wkjrm6cn0z9f5v932wqlmfz40000gn/T/spyclash-resilience-144-8uyzns5h/deploy`.

The targeted command was `npx base44 functions deploy gameRoomAction generateWordPack`. Both app-ID environment overrides were removed for CLI calls, and the canonical local binding was verified.

```text
Found 2 functions to deploy
[1/2] Deploying generateWordPack...
generateWordPack deployed (19.3s)
[2/2] Deploying gameRoomAction...
gameRoomAction deployed (6.5s)
2 deployed
```

## Verification and exact scope

- Authentication succeeded. A new preflight pull of all 17 functions passed the committed baseline guard: **61 runtime files and two configurations** for the targeted functions. The isolated candidate passed its **62-file and two-configuration** guard before deployment.
- A new postflight pull matched all **62/62 candidate runtime files and 2/2 configurations**. Only the source entry path is normalized for configuration comparison.
- Independent comparison confirmed the other **15 functions, 128 runtime files and 15 configurations were unchanged** relative to this run's preflight. Inventory remained **17 → 17**, with no unexpected drift.
- The exact five runtime changes are `gameRoomAction/entry.ts`, `game-room-signal.ts`, `room-write-lifecycle.ts`, `generateWordPack/entry.ts`, and the new `generation-retry-contract.ts`. Their reviewed identity is preserved in the [manifest](resilience-144-runtime-manifest.json) and [patch](resilience-144-runtime.patch).
- The [locally verified behavior and test results](resilience-144.md) apply to this candidate. No code changed after those checks; this checkpoint changes deployment documentation only.
- No schema, secret, site, automation, payment configuration or additional function was deployed. The account lease requirement and ten-minute TTL remain intact.
- The first immediate read-only log query returned no matching records. A subsequent query covering the deployment window showed `gameRoomAction` and `pushNotificationAction` each returning **HTTP 200 at 07:49:34 UTC**. No error entries appeared in that result. These summary logs do not identify a complete multiplayer scenario or prove generation/regeneration acceptance.

Raw local evidence is under `/var/folders/4j/wkjrm6cn0z9f5v932wqlmfz40000gn/T/spyclash-approved-144-kqsvmp8q/`: `deploy.log`, `preflight/`, `postflight/`, `postflight-pull.log`, and the immediate log queries. Temporary evidence may expire; the committed manifest, patch and guard retain the deployed runtime identity.

## Remaining acceptance

The server now performs bounded parallel lease validation/cleanup, atomic signal-row updates, and explicit pre-effect retry classification for generation. The iOS exit receipts and bounded automatic generation retry require **Build 144**; this server deployment does not deliver that client build. Both project version values remain 1.0.1 / 144.

No physical-device installation, TestFlight/App Store upload, authenticated gameplay mutation or paid AI generation was performed. A real session still needs create/join/rejoin, generation/regeneration at different counts, pack save and room close checks. An actual process kill can still leave a lease until expiry, and provider work across a crash is not proven exactly once. Legitimate revision and membership conflicts remain enforced; this deployment does not guarantee the absence of every HTTP 409.
