import {
  assert,
  assertEquals,
  assertMatch,
  assertNotMatch,
  assertRejects,
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
const flattenHelper = new URL(
  "scripts/flatten-base44-pulled-function.sh",
  root,
);
const pulledFunctionFixture = new URL(
  "base44/tests/fixtures/lobby-mode-realtime-pilot/pulled-game-room-action-baseline.tar.gz",
  root,
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

const filePath = (url: URL): string => decodeURIComponent(url.pathname);

async function copyDirectory(source: string, destination: string) {
  await Deno.mkdir(destination, { recursive: true });
  for await (const entry of Deno.readDir(source)) {
    const sourcePath = `${source}/${entry.name}`;
    const destinationPath = `${destination}/${entry.name}`;
    if (entry.isDirectory) {
      await copyDirectory(sourcePath, destinationPath);
    } else if (entry.isFile) {
      await Deno.copyFile(sourcePath, destinationPath);
    } else {
      throw new Error(`unsupported fixture entry: ${sourcePath}`);
    }
  }
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    Uint8Array.from(bytes).buffer,
  );
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function treeHash(directory: string): Promise<string> {
  const files: string[] = [];
  async function collect(current: string, prefix: string) {
    for await (const entry of Deno.readDir(current)) {
      const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory) {
        await collect(`${current}/${entry.name}`, relative);
      } else if (entry.isFile) {
        files.push(relative);
      } else {
        throw new Error(`unsupported tree entry: ${relative}`);
      }
    }
  }
  await collect(directory, "");
  files.sort();
  const records: string[] = [];
  for (const relative of files) {
    records.push(
      `${relative}\t${await sha256(
        await Deno.readFile(`${directory}/${relative}`),
      )}\n`,
    );
  }
  return await sha256(new TextEncoder().encode(records.join("")));
}

async function projectPulledTree(
  flatFunction: string,
  pulledConfig: string,
  destination: string,
) {
  const runtime = `${destination}/base44/functions/gameRoomAction`;
  await Deno.mkdir(runtime, { recursive: true });
  await Deno.copyFile(pulledConfig, `${destination}/function.jsonc`);
  for await (const entry of Deno.readDir(flatFunction)) {
    if (entry.isFile && entry.name !== "function.jsonc") {
      await Deno.copyFile(
        `${flatFunction}/${entry.name}`,
        `${runtime}/${entry.name}`,
      );
    }
  }
}

async function run(command: string, args: string[], cwd?: string) {
  const output = await new Deno.Command(command, {
    args,
    cwd,
    stdout: "piped",
    stderr: "piped",
  }).output();
  assert(
    output.success,
    new TextDecoder().decode(output.stderr) ||
      new TextDecoder().decode(output.stdout),
  );
}

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
  assertMatch(prepare, /flatten-base44-pulled-function\.sh/);
  assertMatch(verify, /base44_cli functions pull/);
  assertMatch(verify, /entity-schemas/);
  assertMatch(prepare, /production_mutated: false/);
  assertMatch(verify, /READY_FOR_APPROVAL/);
  assertMatch(verify, /POSTFLIGHT_VERIFIED/);
  assertMatch(verify, /verification_mutated_production=false/);
  assertMatch(verify, /candidate-postflight/);
  assertMatch(verify, /rollback-preflight/);
  assertMatch(verify, /rollback-postflight/);
  assertMatch(prepare, /manifest_version: 2/);
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

Deno.test("pulled gameRoomAction fixture flattens into exact deploy and pull-back layouts", async () => {
  const fixtureRoot = await Deno.makeTempDir({
    prefix: "spyclash-lobby-mode-package-",
  });
  try {
    await run("tar", [
      "-xzf",
      filePath(pulledFunctionFixture),
      "-C",
      fixtureRoot,
    ]);
    const pulled = `${fixtureRoot}/gameRoomAction`;
    const pulledRuntime = `${pulled}/base44/functions/gameRoomAction`;
    const packageRoot = `${fixtureRoot}/package`;
    const rollback = `${packageRoot}/rollback/base44/functions/gameRoomAction`;
    const candidate =
      `${packageRoot}/candidate/base44/functions/gameRoomAction`;

    assertEquals(
      await treeHash(pulled),
      "61981ace27453bc04c013533519dbc49cd6a6d70bca85b68427ea75db2df1991",
    );
    await run("/bin/bash", [
      filePath(flattenHelper),
      pulled,
      rollback,
      "gameRoomAction",
      "43",
    ]);
    await Deno.copyFile(
      filePath(
        new URL(
          "cutovers/lobby-mode-realtime-pilot/overlays/projection-safe-game-room-signal.ts",
          root,
        ),
      ),
      `${rollback}/game-room-signal.ts`,
    );
    await copyDirectory(rollback, candidate);
    await run("git", [
      "apply",
      "--check",
      filePath(
        new URL(
          "cutovers/lobby-mode-realtime-pilot/overlays/enable-direct-mode.patch",
          root,
        ),
      ),
    ], `${packageRoot}/candidate`);
    await run("git", [
      "apply",
      filePath(
        new URL(
          "cutovers/lobby-mode-realtime-pilot/overlays/enable-direct-mode.patch",
          root,
        ),
      ),
    ], `${packageRoot}/candidate`);

    for (const deployFunction of [candidate, rollback]) {
      const entries = await Array.fromAsync(Deno.readDir(deployFunction));
      assertEquals(entries.length, 44);
      assert(entries.every((entry) => entry.isFile));
      const config = JSON.parse(
        await Deno.readTextFile(`${deployFunction}/function.jsonc`),
      );
      assertEquals(config, { name: "gameRoomAction", entry: "entry.ts" });
      assert(entries.some((entry) => entry.name === config.entry));
    }

    const baselineRuntimeFiles = await Array.fromAsync(
      Deno.readDir(pulledRuntime),
    );
    assertEquals(baselineRuntimeFiles.length, 43);
    assert(baselineRuntimeFiles.every((entry) => entry.isFile));
    for (const entry of baselineRuntimeFiles) {
      if (entry.name !== "game-room-signal.ts") {
        assertEquals(
          await Deno.readFile(`${pulledRuntime}/${entry.name}`),
          await Deno.readFile(`${rollback}/${entry.name}`),
        );
      }
      if (entry.name !== "entry.ts") {
        assertEquals(
          await Deno.readFile(`${rollback}/${entry.name}`),
          await Deno.readFile(`${candidate}/${entry.name}`),
        );
      }
    }

    assertEquals(
      await treeHash(candidate),
      "d3ab984fe018e2d63bd64e1a770f012dd7ba8ed2d6a9b74a22e00edfa41e67dc",
    );
    assertEquals(
      await treeHash(rollback),
      "d5b2ce0d33ba4d1fd2039e30022e6d8499db4329092b9e038f7ff3e117edf575",
    );

    const expectedCandidatePull = `${fixtureRoot}/expected-candidate-pull`;
    const expectedRollbackPull = `${fixtureRoot}/expected-rollback-pull`;
    await projectPulledTree(
      candidate,
      `${pulled}/function.jsonc`,
      expectedCandidatePull,
    );
    await projectPulledTree(
      rollback,
      `${pulled}/function.jsonc`,
      expectedRollbackPull,
    );
    assertEquals(
      await treeHash(expectedCandidatePull),
      "604776d49063a86841465c9361e7d9866bbf137a1502972cebc164c267b1401a",
    );
    assertEquals(
      await treeHash(expectedRollbackPull),
      "d8a8e7f9080618de4b1f248a534c6a094bae3de2d9021b588381f4ed377d11d0",
    );
  } finally {
    await Deno.remove(fixtureRoot, { recursive: true });
  }
});

Deno.test("pilot verifier rejects unknown phases before any remote read", async () => {
  const output = await new Deno.Command("/bin/bash", {
    args: [
      filePath(
        new URL(
          "scripts/verify-base44-lobby-mode-pilot.sh",
          root,
        ),
      ),
      "/tmp/does-not-need-to-exist",
      "unexpected-phase",
    ],
    stdout: "piped",
    stderr: "piped",
  }).output();
  assertEquals(output.code, 64);
  assertMatch(
    new TextDecoder().decode(output.stderr),
    /preflight\|candidate-postflight\|rollback-preflight\|rollback-postflight/,
  );
});

Deno.test("flatten helper fails closed on a large nested pulled runtime", async () => {
  const fixtureRoot = await Deno.makeTempDir({
    prefix: "spyclash-lobby-mode-nested-",
  });
  try {
    await run("tar", [
      "-xzf",
      filePath(pulledFunctionFixture),
      "-C",
      fixtureRoot,
    ]);
    const pulled = `${fixtureRoot}/gameRoomAction`;
    const pulledRuntime = `${pulled}/base44/functions/gameRoomAction`;
    for (let index = 0; index < 256; index += 1) {
      await Deno.mkdir(
        `${pulledRuntime}/nested-${index.toString().padStart(3, "0")}`,
      );
    }
    const destination = `${fixtureRoot}/deploy/gameRoomAction`;
    const output = await new Deno.Command("/bin/bash", {
      args: [
        filePath(flattenHelper),
        pulled,
        destination,
        "gameRoomAction",
        "43",
      ],
      stdout: "piped",
      stderr: "piped",
    }).output();
    assertEquals(output.code, 77);
    assertMatch(
      new TextDecoder().decode(output.stderr),
      /Nested directory in pulled function runtime/,
    );
    await assertRejects(() => Deno.stat(destination), Deno.errors.NotFound);
  } finally {
    await Deno.remove(fixtureRoot, { recursive: true });
  }
});

Deno.test("pilot package expires, remains unlinked, and requires two-device evidence", () => {
  assertMatch(prepare, /max_age_seconds: 120/);
  assertMatch(verify, /BLOCKED_STALE_CUTOVER_PACKAGE/);
  assertMatch(verify, /BLOCKED_REMOTE_ENTITY_STATE_DRIFT/);
  assertMatch(verify, /BLOCKED_REMOTE_FUNCTION_HASH_DRIFT/);
  assertMatch(
    prepare,
    /cp -R "\$REMOTE_FUNCTIONS\/base44\/functions\/\."/,
  );
  assertMatch(runbook, /Preflight-разрешение stage действительно 2 минуты/);
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
