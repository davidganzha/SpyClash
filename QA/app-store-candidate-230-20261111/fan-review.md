# Candidate 230 — merged iOS and FAN review

Date: 2026-11-11. Source review of the combined worktree: candidate 228 (`60bc0010`) plus FAN extra deals (`154040a8`) and shared word packs (`14b631a2`). After the initial read-only review, the user's requested 2% FAN defaults were implemented in `FanMode.swift`, `SpyModels.swift` and `FanModeTests.swift`. Release build settings are being finalized by the release owner; `project.yml` identifies build 230.

## Findings

No new blocking iOS regression found in the reviewed merge.

- `AppState.swift` adds the new FAN probability fields, lobby synchronization and preview deals. Its existing `membership.onAccessChanged → membershipAccessDidChange()` wiring is intact. `AppState+Membership.swift`, `MembershipStore.swift` and `GenerationRewardStore.swift` are unchanged from candidate 228: membership transitions still invalidate stale reward UI and refresh server-authoritative access.
- `Base44Client.swift` preserves the reward-status enrollment capability and typed JSON payload. A configured public Release can send `supported_reward_provider=unity` and its actual numeric build; Debug, staging identifiers and test-mode configurations cannot enroll. Prepare/claim behavior is unchanged.
- Production Unity configuration/presenter and the provider façade are unchanged from candidate 228. Release and SupabasePublicRelease still enable the Unity provider. No client callback grants generation credit; the existing verified server claim remains the authority. This preservation check does not establish live Unity callbacks or ad inventory.
- FAN adds split-word, unique-word and lone-civilian deals. New settings default to 2% for each of the five surprises and 90% for ordinary play. Explicit saved values, including zero, are preserved. When existing local/wire/room settings contain either old probability, the three missing new probabilities remain zero, preserving v2 compatibility. Completely absent settings use the new defaults. Personal words stay hidden until results, assignments remain stable during a round, and unusual deals finish as unranked draws after an ejection.
- Shared-library Base44 retries require known 409/503 codes, explicit retry permission and `before_effects` with `effects_started=false`. Native generation retries are bounded, retain the journaled request UUID/payload, and check cancellation/account generation before every attempt and after a response. This retry path applies only to `legacy/generate`; membership delivery and reward-status requests keep their own paths. The added native tests cover account changes and cancellation.
- The privacy copy adds shared-word reuse and explains that a successful cached generation spends the same allowance/credit. It retains the existing equivalent-protection paragraph and established typography setting.

## Retest on the merged worktree

Executed from `experiments/supabase-game-core`:

```sh
/Users/davidganzha/.deno/bin/deno test --quiet --config supabase/functions/full-game-core/deno.json tests/full-core-engine
/Users/davidganzha/.deno/bin/deno check --config supabase/functions/full-game-core/deno.json supabase/functions/full-game-core/index.ts
```

Result before the follow-up default change: **36 passed, 0 failed** (14 engine, 19 FAN, 3 leaderboard; 252 ms), and typecheck passed. Includes role/word privacy, odd/even assignment counts, insufficient unique words, v3/v2 compatibility, replay/reset, timer voting and neutral competitive results. The backend owner reruns these after matching the new defaults. Focused Swift assertions now additionally cover the 2/2/2/2/2/90 distribution, missing-settings fallback, stored custom/zero values and legacy room/payload compatibility; the release owner runs the final Simulator checks.

No Simulator tests were started by this reviewer on the merged candidate, to avoid conflicting with the release owner's runs. Earlier branch evidence in `QA/fan-extra-deals-20261111/README.md` is historical evidence, not a new candidate-230 Simulator result.

## Exact focused Simulator test identifiers

FAN/local/online lobby behavior (run in both Debug and the public client's SupabaseDebug configuration as appropriate):

- `SpyClashTests/FanModeTests`
- `SpyClashTests/LocalFanOutcomeTests`
- `SpyClashTests/FanOnlineDrawTests`
- `SpyClashTests/LobbyLatestWinsStateTests`
- `SpyClashTests/LobbySyncFeedbackStateTests`
- `SpyClashTests/WaitingStartActionModeTests`
- `SpyClashTests/LobbyStartGateTests`

Generation and persistence integration:

- `SpyClashTests/LocalWordPoolTests`
- `SpyClashTests/WordGenerationRetryTests`
- `SpyClashTests/WordPackPersistenceIntegrationTests`
- `SpyClashSupabaseStagingTests/SupabaseSharedGenerationRetryTests`
- `SpyClashSupabaseStagingTests/SupabaseAppStoreRetryTests`

Ads/Limitless and public release regression:

- `SpyClashTests/UnityRewardedGenerationAdConfigurationTests`
- `SpyClashTests/GenerationRewardStoreTests`
- `SpyClashTests/MembershipTests`
- `SpyClashPublicReleaseTests/SupabasePublicReleaseTests`

Three focused UI methods:

- `SpyClashSettingsUITests/FanVotingUITests/testAllFanScenariosRevealAPlayfulDrawForHostAndGuest`
- `SpyClashSettingsUITests/FanVotingUITests/testLocalNewDealsRevealTheCorrectWords`
- `SpyClashSettingsUITests/FanVotingUITests/testExpiredFanTimerStillAllowsPlayerVoting`

## Scope and release dependencies

The backend owner separately verifies the combined shared-library and quota/bonus charging paths after resolving the generator conflicts. Online FAN needs the matching Supabase `full-game-core` implementation; this review did not inspect or change live deployment state. Physical-device acceptance, real multiplayer, a completed Unity S2S reward and a real StoreKit purchase are not established by these fixture tests. No upload, deployment or other production operation was performed by this reviewer.
