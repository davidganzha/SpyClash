import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
// Reproduce against the isolated, guarded candidate function tree:
// SPYCLASH_CANDIDATE_FUNCTIONS_ROOT=/path/to/candidate/functions deno test --allow-read --allow-env=SPYCLASH_CANDIDATE_FUNCTIONS_ROOT docs/incidents/2026-09-06-reliability/profile-fence-candidate_test.ts
const candidateRoot = Deno.env.get("SPYCLASH_CANDIDATE_FUNCTIONS_ROOT");
assert(
  candidateRoot,
  "Set SPYCLASH_CANDIDATE_FUNCTIONS_ROOT to the exact candidate functions project",
);
const functionURL = new URL("file:///");
functionURL.pathname = `${
  candidateRoot.replace(/\/$/, "")
}/base44/functions/gameRoomAction/`;
const configuration = JSON.parse(
  (await Deno.readTextFile(new URL("function.jsonc", functionURL)))
    .split("\n").filter((line) => !line.trimStart().startsWith("//")).join(
      "\n",
    ),
);
assert(
  [
    "entry.ts",
    "main.ts",
    "base44/functions/gameRoomAction/entry.ts",
    "base44/functions/gameRoomAction/main.ts",
  ].includes(configuration.entry),
);
const entryURL = new URL(configuration.entry, functionURL);
const runtimeURL = new URL("./", entryURL);
const {
  acquireBillingDeletionMarker,
  billingIdentitySubjectKey,
  BillingIdentityLifecycleError,
  isBillingIdentityLeaseActive,
} = await import(new URL("billing-identity-lifecycle.ts", runtimeURL).href);
const { assertRoomWriterLeaseForUser, withRoomWriteLeases } = await import(
  new URL("room-write-lifecycle.ts", runtimeURL).href
);
const { fanoutCommunityProfileInvalidations } = await import(
  new URL("community-profile-signal.ts", runtimeURL).href
);
const { repairCommunityProfileRecipients, runCommunityProfileRepair } =
  await import(
    new URL("community-profile-repair-queue.ts", runtimeURL).href
  );

type Row = Record<string, any>;
const source = await Deno.readTextFile(entryURL);
// Execute the exact staged entry's repair implementation with real admission,
// per-write assertion, recipient scheduling and signal persistence helpers.
const fragment = source.slice(
  source.indexOf("function profileRepairLifecycleIsGone("),
  source.indexOf("async function repairFinishedCommunityProfilesAndSignals("),
);
assert(fragment.includes("[profileUserID, recipientUserID]"));
const dependencies = {
  BillingIdentityLifecycleError,
  withRoomWriteLeases,
  assertRoomWriterLeaseForUser,
  fanoutCommunityProfileInvalidations,
  repairCommunityProfileRecipients,
  runCommunityProfileRepair,
  clean: (value: unknown) => String(value ?? "").trim(),
  uniqueStrings: (values: unknown[]) => [
    ...new Set(
      values.map((value) => String(value ?? "").trim()).filter(Boolean),
    ),
  ],
  reconcileCommunityProfileMirrors: () =>
    Promise.resolve([{ status: "updated" }]),
};
function implementations(history: () => Promise<Row[]>, overrides: Row = {}): {
  repair: (base44: Row, source: Row) => Promise<boolean>;
  run: (base44: Row, sources: Row[], options?: Row) => Promise<Row[]>;
} {
  const values = {
    ...dependencies,
    ...overrides,
    rankedHistoryForMatch: history,
  };
  return new Function(
    ...Object.keys(values),
    `${fragment};return {repair: repairCommunityProfileHistorySource, run: runProfileRepairSources};`,
  )(...Object.values(values));
}
class Store {
  rows: Row[] = [];
  filter(query: Row) {
    return Promise.resolve(
      structuredClone(
        this.rows.filter((row) =>
          Object.entries(query).every(([key, value]) =>
            value && typeof value === "object" && "$exists" in value
              ? (row[key] !== undefined) === value.$exists
              : row[key] === value
          )
        ),
      ),
    );
  }
  updateMany(query: Row, update: Row) {
    let updated = 0;
    for (const row of this.rows) {
      if (Object.entries(query).every(([key, value]) => row[key] === value)) {
        Object.assign(row, structuredClone(update.$set));
        ++updated;
      }
    }
    return Promise.resolve({ updated });
  }
}
async function exercise(
  mode:
    | "healthy"
    | "delete_after_mirror"
    | "concurrent_delete"
    | "invalidate_before_create"
    | "invalidate_before_update",
) {
  const lifecycle = new Store();
  const signalRows: Row[] = [];
  let writes = 0;
  let deletionConflicts = 0;
  const ids = ["profile-owner", "recipient-a", "recipient-b"];
  for (const id of ids) {
    lifecycle.rows.push({
      id,
      subject_key: await billingIdentitySubjectKey(id),
      state: "active",
      revision: `initial-${id}`,
      lease_token: "released:initial",
      lease_until: new Date(Date.now() - 10000).toISOString(),
      created_date: new Date().toISOString(),
    });
  }
  const owner = lifecycle.rows[0];
  const history = async () => {
    if (mode === "delete_after_mirror") {
      await acquireBillingDeletionMarker(lifecycle, "profile-owner");
    }
    return [{ player_user_id: "recipient-a" }, {
      player_user_id: "recipient-b",
    }];
  };
  const signalStore = {
    filter: async (query: Row) => {
      const recipient = lifecycle.rows.find((row) =>
        row.id === query.recipient_user_id
      )!;
      assert(
        isBillingIdentityLeaseActive(owner.lease_until),
        "profile owner lease must cover the signal read/write window",
      );
      assert(
        isBillingIdentityLeaseActive(recipient.lease_until),
        "recipient lease must cover the same window",
      );
      if (mode === "concurrent_delete") {
        const error = await assertRejects(
          () => acquireBillingDeletionMarker(lifecycle, "profile-owner"),
          BillingIdentityLifecycleError,
        );
        assertEquals((error as Error & { code: string }).code, "active_lease");
        ++deletionConflicts;
      }
      if (mode.startsWith("invalidate_before")) {
        Object.assign(owner, {
          state: "deleting",
          revision: "replacement-deletion",
          lease_token: "deleting:replacement",
        });
      }
      return mode === "invalidate_before_update"
        ? [{ id: "old-signal", ...query }]
        : [];
    },
    create: async (row: Row) => {
      ++writes;
      const saved = { id: `signal-${writes}`, ...row };
      signalRows.push(saved);
      return saved;
    },
    update: async (_id: string, row: Row) => {
      ++writes;
      signalRows.push(row);
      return row;
    },
  };
  const { repair } = implementations(history);
  const completed = await repair({
    asServiceRole: {
      entities: {
        BillingIdentityLifecycle: lifecycle,
        GameHistory: {},
        User: {},
        CommunityProfileSignal: signalStore,
      },
    },
  }, { player_user_id: "profile-owner", match_id: "test-match" });
  return { completed, writes, deletionConflicts };
}
Deno.test("exact staged repair serializes healthy paired recipient leases without losing a recipient", async () =>
  assertEquals(await exercise("healthy"), {
    completed: true,
    writes: 2,
    deletionConflicts: 0,
  }));
Deno.test("profile deletion after mirror blocks all later signal recreation", async () =>
  assertEquals(await exercise("delete_after_mirror"), {
    completed: true,
    writes: 0,
    deletionConflicts: 0,
  }));
Deno.test("concurrent deletion cannot acquire while either recipient signal owns the profile lease", async () =>
  assertEquals(await exercise("concurrent_delete"), {
    completed: true,
    writes: 2,
    deletionConflicts: 2,
  }));
for (
  const mode of [
    "invalidate_before_create",
    "invalidate_before_update",
  ] as const
) {
  Deno.test(`per-write owner reassertion blocks ${mode}`, async () => {
    const result = await exercise(mode);
    assertEquals(result.writes, 0);
    assertEquals(result.completed, false);
  });
}

function gate() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
async function deadline<T>(value: Promise<T>): Promise<T> {
  let timeout!: ReturnType<typeof setTimeout>;
  try {
    return await Promise.race([
      value,
      new Promise<never>((_resolve, reject) => {
        timeout = setTimeout(
          () => reject(new Error("Profile batch did not settle")),
          1000,
        );
      }),
    ]);
  } finally {
    clearTimeout(timeout);
  }
}
async function batchFixture() {
  const lifecycle = new Store();
  for (const id of ["profile-a", "profile-b", "recipient"]) {
    lifecycle.rows.push({
      id,
      subject_key: await billingIdentitySubjectKey(id),
      state: "active",
      revision: `initial-${id}`,
      lease_token: "released:initial",
      lease_until: new Date(Date.now() - 10000).toISOString(),
      created_date: new Date().toISOString(),
    });
  }
  const history = new Store();
  history.rows = ["profile-a", "profile-b"].map((id) => ({
    id: `history-${id}`,
    player_user_id: id,
    match_id: "test-match",
    profile_repair_state: "pending",
    profile_repair_attempt_count: 0,
  }));
  const signals: Row[] = [];
  let writes = 0;
  const signalStore = {
    filter: (query: Row) =>
      Promise.resolve(
        structuredClone(signals.filter((row) =>
          row.recipient_user_id === query.recipient_user_id
        )),
      ),
    create: (row: Row) => {
      writes++;
      const saved = { id: "shared-signal", ...row };
      signals.push(saved);
      return Promise.resolve(saved);
    },
    update: (_id: string, row: Row) => {
      writes++;
      Object.assign(signals[0], row);
      return Promise.resolve(signals[0]);
    },
  };
  return {
    lifecycle,
    history,
    signalStore,
    writes: () => writes,
    base44: {
      asServiceRole: {
        entities: {
          BillingIdentityLifecycle: lifecycle,
          GameHistory: history,
          User: {},
          CommunityProfileSignal: signalStore,
        },
      },
    },
  };
}

Deno.test("exact staged parallel mirrors release before ordered fanout and await every started write", async () => {
  const fixture = await batchFixture();
  const mirrorStarted = new Set<string>();
  const mirrorCompleted = new Set<string>();
  const bothStarted = gate();
  const releaseA = gate();
  const releaseB = gate();
  const firstSignal = gate();
  const releaseSignal = gate();
  let signalsStarted = 0;
  let activeWrites = 0;
  let maximumActiveWrites = 0;
  let batchSettled = false;
  const persist = async (row: Row) => {
    assertEquals(
      mirrorCompleted.size,
      2,
      "No fanout may overlap a sibling mirror",
    );
    ++signalsStarted;
    ++activeWrites;
    maximumActiveWrites = Math.max(maximumActiveWrites, activeWrites);
    if (signalsStarted === 1) {
      firstSignal.resolve();
      await releaseSignal.promise;
    }
    --activeWrites;
    return { id: "shared-signal", ...row };
  };
  fixture.signalStore.create = persist;
  fixture.signalStore.update = (_id: string, row: Row) => persist(row);
  const { run } = implementations(
    async () => [{ player_user_id: "recipient" }],
    {
      reconcileCommunityProfileMirrors: async (input: Row) => {
        const id = input.playerUserIDs[0];
        mirrorStarted.add(id);
        if (mirrorStarted.size === 2) bothStarted.resolve();
        await (id === "profile-a" ? releaseA.promise : releaseB.promise);
        mirrorCompleted.add(id);
        return [{ status: "updated" }];
      },
    },
  );
  const batch = run(fixture.base44, fixture.history.rows, { concurrency: 2 })
    .finally(() => {
      batchSettled = true;
    });
  try {
    await deadline(bothStarted.promise);
    releaseA.resolve();
    await new Promise((resolve) => setTimeout(resolve, 0));
    assertEquals(
      signalsStarted,
      0,
      "The first finished mirror must wait for the second",
    );
    assertEquals(batchSettled, false);
    releaseB.resolve();
    await deadline(firstSignal.promise);
    await new Promise((resolve) => setTimeout(resolve, 0));
    assertEquals(
      signalsStarted,
      1,
      "Shared-recipient fanout must stay serialized",
    );
    assertEquals(
      batchSettled,
      false,
      "Started writes must settle before batch returns",
    );
    releaseSignal.resolve();
    const outcomes = await deadline(batch);
    assertEquals(outcomes.map((result: Row) => result.outcome), [
      "performed",
      "performed",
    ]);
    assertEquals(signalsStarted, 2);
    assertEquals(maximumActiveWrites, 1);
    assertEquals(fixture.history.rows.map((row) => row.profile_repair_state), [
      "completed",
      "completed",
    ]);
    assert(
      fixture.lifecycle.rows.every((row) =>
        !isBillingIdentityLeaseActive(row.lease_until)
      ),
    );
  } finally {
    releaseA.resolve();
    releaseB.resolve();
    releaseSignal.resolve();
    await deadline(batch);
  }
});

for (
  const mode of ["already_completed", "mirror_failed", "claim_failed"] as const
) {
  Deno.test(`exact staged mirror barrier settles sibling when one source is ${mode}`, async () => {
    const fixture = await batchFixture();
    if (mode === "already_completed") {
      fixture.history.rows[0].profile_repair_state = "completed";
    }
    if (mode === "claim_failed") {
      const filter = fixture.history.filter.bind(fixture.history);
      fixture.history.filter = (query: Row) =>
        query.id === "history-profile-a"
          ? Promise.reject(new Error("Injected claim read failure"))
          : filter(query);
    }
    const { run } = implementations(
      async () => [{ player_user_id: "recipient" }],
      {
        reconcileCommunityProfileMirrors: (input: Row) =>
          mode === "mirror_failed" && input.playerUserIDs[0] === "profile-a"
            ? Promise.reject(new Error("Injected mirror failure"))
            : Promise.resolve([{ status: "updated" }]),
      },
    );
    const outcomes = await deadline(
      run(fixture.base44, fixture.history.rows, { concurrency: 2 }),
    );
    assertEquals(outcomes.map((result: Row) => result.outcome), [
      mode === "already_completed" ? "completed" : "failed",
      "performed",
    ]);
    assertEquals(fixture.writes(), 1);
    assertEquals(fixture.history.rows[1].profile_repair_state, "completed");
    assert(
      fixture.lifecycle.rows.every((row) =>
        !isBillingIdentityLeaseActive(row.lease_until)
      ),
    );
  });
}
