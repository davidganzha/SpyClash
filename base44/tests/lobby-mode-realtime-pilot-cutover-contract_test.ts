import {
  assert,
  assertEquals,
  assertMatch,
  assertNotMatch,
} from "jsr:@std/assert@1";

const root = new URL("../../", import.meta.url);
const prepare = await Deno.readTextFile(
  new URL("scripts/prepare-base44-lobby-mode-pilot.sh", root),
);
const verify = await Deno.readTextFile(
  new URL("scripts/verify-base44-lobby-mode-pilot.sh", root),
);
const runbook = await Deno.readTextFile(
  new URL("cutovers/lobby-mode-realtime-pilot/README.md", root),
);
const entryPatch = await Deno.readTextFile(
  new URL(
    "cutovers/lobby-mode-realtime-pilot/overlays/enable-direct-mode.patch",
    root,
  ),
);
const safeSignal = await Deno.readTextFile(
  new URL(
    "cutovers/lobby-mode-realtime-pilot/overlays/projection-safe-game-room-signal.ts",
    root,
  ),
);
const projectionFields = JSON.parse(
  await Deno.readTextFile(
    new URL(
      "cutovers/lobby-mode-realtime-pilot/overlays/game-room-signal-projection-fields.json",
      root,
    ),
  ),
);

Deno.test("lobby mode pilot preparation is read-only and fixed to canonical Production", () => {
  for (const source of [prepare, verify]) {
    assertMatch(source, /69a0e57fa939f578082f8091/);
    assertMatch(source, /base44@\$EXPECTED_CLI_VERSION|base44@0\.0\.56/);
    assertNotMatch(source, /base44_cli[ \t]+entities[ \t]+push/);
    assertNotMatch(source, /base44_cli[ \t]+functions[ \t]+deploy/);
    assertNotMatch(source, /base44_cli[ \t]+deploy/);
    assertNotMatch(source, /--force/);
  }
  assertMatch(prepare, /base44_cli functions list/);
  assertMatch(prepare, /base44_cli functions pull/);
  assertMatch(verify, /base44_cli functions pull/);
  assertMatch(verify, /entity-schemas/);
  assertMatch(prepare, /production_mutated: false/);
  assertMatch(verify, /READY_FOR_APPROVAL/);
  assertMatch(verify, /production_mutated=false/);
});

Deno.test("pilot schema adds exactly five optional safe projection fields", () => {
  assertEquals(Object.keys(projectionFields).sort(), [
    "projected_game_mode",
    "projection_committed_at",
    "projection_emitted_at",
    "projection_id",
    "projection_kind",
  ]);
  assertEquals(projectionFields.projection_kind.enum, [
    "none",
    "lobby_mode_v1",
  ]);
  assertEquals(projectionFields.projected_game_mode.enum, [
    "questions",
    "associations",
  ]);
  assertEquals(projectionFields.projection_id.format, "uuid");
  assertEquals(projectionFields.projection_committed_at.format, "date-time");
  assertEquals(projectionFields.projection_emitted_at.format, "date-time");
  assertMatch(verify, /Expected exactly one entity change/);
  assertMatch(verify, /Non-target entity changed/);
  assertMatch(verify, /five optional projection fields/);
});

Deno.test("candidate enables only host waiting mode fast path and rollback stays compatibility-off", () => {
  assertMatch(entryPatch, /\+  "update_game_mode",/);
  assertMatch(entryPatch, /normalizedStatus\(room\) !== "waiting"/);
  assertMatch(
    entryPatch,
    /clean\(room\?\.host_email\) !== clean\(user\?\.email\)/,
  );
  assertMatch(entryPatch, /lobbyModeSignalProjectionForRoom\(result\)/);
  assertEquals(entryPatch.match(/^\+  "[^"]+",$/gm), [
    '+  "update_game_mode",',
  ]);

  assertMatch(
    safeSignal,
    /projection_kind: safeProjection\?\.projection_kind \|\| "none"/,
  );
  assertMatch(safeSignal, /projectedLobbyModeFromSignal/);
  assertNotMatch(safeSignal, /lobbyModeSignalProjectionForRepair/);
  assertNotMatch(safeSignal, /close_intent_id|close_match_id|close_completion/);
  assertMatch(verify, /Rollback must never push entity schemas/);
  assertMatch(verify, /Rollback changed unexpected runtime file/);
});

Deno.test("pilot package expires, remains unlinked, and requires two-device evidence", () => {
  assertMatch(prepare, /max_age_seconds: 120/);
  assertMatch(verify, /BLOCKED_STALE_CUTOVER_PACKAGE/);
  assertMatch(verify, /BLOCKED_REMOTE_ENTITY_BASELINE_DRIFT/);
  assertMatch(verify, /BLOCKED_REMOTE_FUNCTION_HASH_DRIFT/);
  assertMatch(
    prepare,
    /cp -R "\$REMOTE_FUNCTIONS\/base44\/functions\/\."/,
  );
  assertMatch(runbook, /Stage действителен 2 минуты/);
  assertMatch(prepare, /must remain unlinked from every Base44 app/);
  assertMatch(verify, /must remain unlinked from every Base44 app/);
  assertMatch(runbook, /два физических iPhone/);
  assertMatch(runbook, /30\/30 `direct_apply=true`/);
  assertMatch(runbook, /p50 не больше 250 ms/);
  assertMatch(runbook, /p95 не больше 500 ms/);
  assertMatch(runbook, /Rollback — отдельная production mutation/);
  assert(
    runbook.includes("новое однозначное\nподтверждение пользователя"),
    "runbook must require fresh approval immediately before mutation",
  );
});
