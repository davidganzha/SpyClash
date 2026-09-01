import {
  assert,
  assertEquals,
  assertInstanceOf,
  assertStringIncludes,
  assertThrows,
} from "jsr:@std/assert@1";
import {
  type FriendshipPairEntity,
  FriendshipPairPolicyError,
  type FriendshipPairResolution,
  type FriendshipStateProjection,
  projectFriendshipStateForActor,
  resolveFriendshipPair,
} from "./friendship-pair-policy.ts";

function relationship(
  id: string,
  requesterID: string,
  addresseeID: string,
  status: string,
  fields: FriendshipPairEntity = {},
): FriendshipPairEntity {
  return {
    id,
    requester_id: requesterID,
    addressee_id: addresseeID,
    status,
    created_at: "2026-01-01T00:00:00.000Z",
    updated_at: "2026-01-01T00:00:00.000Z",
    ...fields,
  };
}

function ids(rows: FriendshipPairEntity[]): string[] {
  return rows.map((row) => String(row.id));
}

function pairSnapshot(pair: FriendshipPairResolution) {
  return {
    actorID: pair.actorID,
    counterpartID: pair.counterpartID,
    rows: ids(pair.rows),
    representative: pair.representative?.id ?? null,
    effectiveStatus: pair.effectiveStatus,
    blockers: ids(pair.blockers),
    blockerOwnerIDs: pair.blockerOwnerIDs,
    unknownBlockerOwnerIDs: pair.unknownBlockerOwnerIDs,
    hasBlock: pair.hasBlock,
    hasOwnBlock: pair.hasOwnBlock,
    hasForeignBlock: pair.hasForeignBlock,
    accepted: ids(pair.accepted),
    hasAccepted: pair.hasAccepted,
    pending: ids(pair.pending),
    pendingOutgoing: ids(pair.pendingOutgoing),
    pendingIncoming: ids(pair.pendingIncoming),
    hasPending: pair.hasPending,
    hasPendingOutgoing: pair.hasPendingOutgoing,
    hasPendingIncoming: pair.hasPendingIncoming,
    declined: ids(pair.declined),
  };
}

function projectionSnapshot(projection: FriendshipStateProjection) {
  return {
    pairs: projection.pairs.map((pair) => pair.counterpartID),
    friends: projection.friends.map((pair) => pair.counterpartID),
    incoming: projection.incoming.map((pair) => pair.counterpartID),
    outgoing: projection.outgoing.map((pair) => pair.counterpartID),
    blocked: projection.blocked.map((pair) => pair.counterpartID),
    hidden: projection.hidden.map((pair) => pair.counterpartID),
    declined: projection.declined.map((pair) => pair.counterpartID),
    details: projection.pairs.map(pairSnapshot),
  };
}

function permutations<T>(items: T[]): T[][] {
  if (items.length <= 1) return [items];
  return items.flatMap((item, index) =>
    permutations([...items.slice(0, index), ...items.slice(index + 1)]).map(
      (suffix) => [item, ...suffix],
    )
  );
}

function assertPolicyUnavailable(action: () => unknown) {
  const error = assertThrows(action, FriendshipPairPolicyError);
  assertInstanceOf(error, FriendshipPairPolicyError);
  assertEquals(error.status, 503);
  assertEquals(error.code, "friendship_pair_unavailable");
}

Deno.test("Friendship pair blocks dominate accepted and pending in either orientation", () => {
  const foreignBlock = [
    relationship("accepted-out", "user-a", "user-b", "accepted"),
    relationship("pending-out", "user-a", "user-b", "pending", {
      request_event_id: "event-a",
    }),
    relationship("blocked-in", "user-b", "user-a", "blocked", {
      blocked_by_id: "user-b",
    }),
  ];
  const foreign = resolveFriendshipPair(foreignBlock, "user-a", "user-b");
  assertEquals(foreign.representative?.id, "blocked-in");
  assertEquals(foreign.effectiveStatus, "blocked");
  assertEquals(foreign.hasBlock, true);
  assertEquals(foreign.hasForeignBlock, true);
  assertEquals(foreign.hasOwnBlock, false);
  assertEquals(foreign.hasAccepted, true);
  assertEquals(foreign.hasPendingOutgoing, true);

  const ownBlock = [
    relationship("accepted-in", "user-b", "user-a", "accepted"),
    relationship("pending-in", "user-b", "user-a", "pending", {
      request_event_id: "event-b",
    }),
    relationship("blocked-out", "user-a", "user-b", "blocked", {
      blocked_by_id: "user-a",
    }),
  ];
  const own = resolveFriendshipPair(ownBlock, "user-a", "user-b");
  assertEquals(own.representative?.id, "blocked-out");
  assertEquals(own.effectiveStatus, "blocked");
  assertEquals(own.hasOwnBlock, true);
  assertEquals(own.hasForeignBlock, false);
  assertEquals(own.hasAccepted, true);
  assertEquals(own.hasPendingIncoming, true);
});

Deno.test("Friendship pair retains all blocker owners and foreign block wins representative", () => {
  const rows = [
    relationship("own-block", "user-a", "user-b", "blocked", {
      blocked_by_id: "user-a",
      updated_at: "2026-04-02T00:00:00.000Z",
    }),
    relationship("foreign-block", "user-b", "user-a", "blocked", {
      blocked_by_id: "user-b",
      updated_at: "2026-04-01T00:00:00.000Z",
    }),
    relationship("unknown-block", "user-a", "user-b", "blocked", {
      blocked_by_id: "legacy-owner",
      updated_at: "2026-03-01T00:00:00.000Z",
    }),
  ];
  const pair = resolveFriendshipPair(rows, "user-a", "user-b");

  assertEquals(pair.representative?.id, "foreign-block");
  assertEquals(pair.blockerOwnerIDs, [
    "legacy-owner",
    "user-a",
    "user-b",
  ]);
  assertEquals(pair.unknownBlockerOwnerIDs, ["legacy-owner"]);
  assertEquals(pair.hasOwnBlock, true);
  assertEquals(pair.hasForeignBlock, true);
  assertEquals(ids(pair.blockers), [
    "foreign-block",
    "unknown-block",
    "own-block",
  ]);
});

Deno.test("Accepted Friendship deterministically dominates pending and declined", () => {
  const rows = [
    relationship("pending-out", "user-a", "user-b", "pending", {
      request_event_id: "event-out",
      updated_at: "2026-05-04T00:00:00.000Z",
    }),
    relationship("pending-in", "user-b", "user-a", "pending", {
      request_event_id: "event-in",
      updated_at: "2026-05-03T00:00:00.000Z",
    }),
    relationship("accepted", "user-b", "user-a", "accepted", {
      updated_at: "2026-01-01T00:00:00.000Z",
    }),
    relationship("declined", "user-a", "user-b", "declined", {
      updated_at: "2026-06-01T00:00:00.000Z",
    }),
  ];

  for (const input of permutations(rows)) {
    const pair = resolveFriendshipPair(input, "user-a", "user-b");
    assertEquals(pair.representative?.id, "accepted");
    assertEquals(pair.effectiveStatus, "accepted");
    assertEquals(pair.hasAccepted, true);
    assertEquals(pair.hasPending, true);
    assertEquals(pair.hasPendingOutgoing, true);
    assertEquals(pair.hasPendingIncoming, true);
  }
});

Deno.test("Outgoing pending with request event is deterministic across every input permutation", () => {
  const rows = [
    relationship("pending-missing", "user-a", "user-b", "pending", {
      updated_at: "2026-07-04T00:00:00.000Z",
    }),
    relationship("pending-event-old", "user-a", "user-b", "pending", {
      request_event_id: "event-old",
      updated_at: "2026-07-01T00:00:00.000Z",
    }),
    relationship("pending-event-new", "user-a", "user-b", "pending", {
      request_event_id: "event-new",
      updated_at: "2026-07-03T00:00:00.000Z",
    }),
    relationship("pending-incoming", "user-b", "user-a", "pending", {
      request_event_id: "event-incoming",
      updated_at: "2026-07-05T00:00:00.000Z",
    }),
  ];
  const expected = pairSnapshot(
    resolveFriendshipPair(rows, "user-a", "user-b"),
  );
  assertEquals(expected.representative, "pending-event-new");
  assertEquals(expected.pendingOutgoing, [
    "pending-event-new",
    "pending-event-old",
    "pending-missing",
  ]);
  assertEquals(expected.pendingIncoming, ["pending-incoming"]);

  for (const input of permutations(rows)) {
    assertEquals(
      pairSnapshot(resolveFriendshipPair(input, "user-a", "user-b")),
      expected,
    );
  }
});

Deno.test("Crossed pending requests project as incoming for both actors", () => {
  const rows = [
    relationship("a-to-b", "user-a", "user-b", "pending", {
      request_event_id: "event-a",
    }),
    relationship("b-to-a", "user-b", "user-a", "pending", {
      request_event_id: "event-b",
    }),
  ];

  const forA = projectFriendshipStateForActor(rows, "user-a");
  const forB = projectFriendshipStateForActor(rows, "user-b");

  assertEquals(forA.incoming.map((pair) => pair.counterpartID), ["user-b"]);
  assertEquals(forA.outgoing, []);
  assertEquals(ids(forA.incoming[0].pendingIncoming), ["b-to-a"]);
  assertEquals(forA.incoming[0].representative?.id, "a-to-b");

  assertEquals(forB.incoming.map((pair) => pair.counterpartID), ["user-a"]);
  assertEquals(forB.outgoing, []);
  assertEquals(ids(forB.incoming[0].pendingIncoming), ["a-to-b"]);
  assertEquals(forB.incoming[0].representative?.id, "b-to-a");
});

Deno.test("Friendship pair ignores unrelated rows without weakening exact-pair validation", () => {
  const pair = resolveFriendshipPair(
    [
      relationship("accepted", "user-a", "user-b", "accepted"),
      relationship("other-actor", "user-a", "user-c", "blocked", {
        blocked_by_id: "user-c",
      }),
      relationship("other-pair", "user-c", "user-d", "not-a-status"),
    ],
    "user-a",
    "user-b",
  );

  assertEquals(ids(pair.rows), ["accepted"]);
  assertEquals(pair.representative?.id, "accepted");
  assertEquals(pair.hasBlock, false);

  assertPolicyUnavailable(() =>
    resolveFriendshipPair(
      [
        relationship("invalid-exact", "user-a", "user-b", "not-a-status"),
      ],
      "user-a",
      "user-b",
    )
  );
});

Deno.test("Friendship pair invalid actor, pair, row, and conflict fail closed", () => {
  const valid = [relationship("accepted", "user-a", "user-b", "accepted")];
  assertPolicyUnavailable(() => resolveFriendshipPair(valid, "", "user-b"));
  assertPolicyUnavailable(() =>
    resolveFriendshipPair(valid, "user-a", "user-a")
  );
  assertPolicyUnavailable(() =>
    resolveFriendshipPair(
      [{
        requester_id: "user-a",
        addressee_id: "user-b",
        status: "accepted",
      }],
      "user-a",
      "user-b",
    )
  );
  assertPolicyUnavailable(() =>
    resolveFriendshipPair(
      [
        relationship("same", "user-a", "user-b", "accepted"),
        relationship("same", "user-a", "user-b", "blocked", {
          blocked_by_id: "user-a",
        }),
      ],
      "user-a",
      "user-b",
    )
  );
});

Deno.test("Friendship state projection groups pairs and lets block suppress every weaker state", () => {
  const rows = [
    relationship("b-accepted", "user-a", "user-b", "accepted"),
    relationship("b-blocked", "user-b", "user-a", "blocked", {
      blocked_by_id: "user-b",
    }),
    relationship("c-pending", "user-a", "user-c", "pending", {
      request_event_id: "event-c",
    }),
    relationship("c-accepted", "user-c", "user-a", "accepted"),
    relationship("d-incoming", "user-d", "user-a", "pending", {
      request_event_id: "event-d-in",
    }),
    relationship("d-outgoing", "user-a", "user-d", "pending", {
      request_event_id: "event-d-out",
    }),
    relationship("e-incoming", "user-e", "user-a", "pending", {
      request_event_id: "event-e",
    }),
    relationship("f-accepted", "user-a", "user-f", "accepted"),
    relationship("f-blocked", "user-a", "user-f", "blocked", {
      blocked_by_id: "user-a",
    }),
    relationship("g-own-block", "user-a", "user-g", "blocked", {
      blocked_by_id: "user-a",
    }),
    relationship("g-foreign-block", "user-g", "user-a", "blocked", {
      blocked_by_id: "user-g",
    }),
    relationship("i-declined", "user-i", "user-a", "declined"),
    relationship("unrelated", "user-x", "user-y", "blocked", {
      blocked_by_id: "user-x",
    }),
  ];
  const expected = projectionSnapshot(
    projectFriendshipStateForActor(rows, "user-a"),
  );
  assertEquals(expected.pairs, [
    "user-b",
    "user-c",
    "user-d",
    "user-e",
    "user-f",
    "user-g",
    "user-i",
  ]);
  assertEquals(expected.friends, ["user-c"]);
  assertEquals(expected.outgoing, []);
  assertEquals(expected.incoming, ["user-d", "user-e"]);
  assertEquals(expected.blocked, ["user-f"]);
  assertEquals(expected.hidden, ["user-b", "user-g"]);
  assertEquals(expected.declined, ["user-i"]);

  const reordered = [
    [...rows].reverse(),
    [...rows.slice(4), ...rows.slice(0, 4)],
    [
      ...rows.filter((_, index) => index % 2),
      ...rows.filter((_, index) => !(index % 2)),
    ],
  ];
  for (const input of reordered) {
    assertEquals(
      projectionSnapshot(projectFriendshipStateForActor(input, "user-a")),
      expected,
    );
  }
});

Deno.test("Friendship state projection invalid actor and malformed actor pair fail closed", () => {
  assertPolicyUnavailable(() => projectFriendshipStateForActor([], ""));
  assertPolicyUnavailable(() =>
    projectFriendshipStateForActor([
      relationship("self", "user-a", "user-a", "accepted"),
    ], "user-a")
  );
  assertPolicyUnavailable(() =>
    projectFriendshipStateForActor([{
      id: "missing-counterpart",
      requester_id: "user-a",
      addressee_id: "",
      status: "pending",
    }], "user-a")
  );
});

Deno.test("communityAction applies pair policy to reads, projections, and leased mutations", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const relationshipRead = source.slice(
    source.indexOf("async function relationshipBetween"),
    source.indexOf("async function relationshipsBetween"),
  );
  const stateProjection = source.slice(
    source.indexOf("async function buildState"),
    source.indexOf("async function buildDirectory"),
  );
  const block = source.slice(
    source.indexOf('if (action === "block")'),
    source.indexOf('if (action === "unblock")'),
  );
  const unblock = source.slice(
    source.indexOf('if (action === "unblock")'),
    source.indexOf('if (action === "report")'),
  );
  const rowMutationsStart = source.lastIndexOf(
    "const friendshipID = clean(body.friendship_id);",
  );
  const rowMutations = source.slice(
    rowMutationsStart,
    source.indexOf("} catch (error: any)", rowMutationsStart),
  );

  assertStringIncludes(relationshipRead, "resolveFriendshipPair(");
  assertStringIncludes(relationshipRead, "await relationshipsBetween(");
  assertStringIncludes(stateProjection, "projectFriendshipStateForActor(");
  assertStringIncludes(
    stateProjection,
    "if (!friendship || pair.hasForeignBlock) continue;",
  );
  assertStringIncludes(stateProjection, "pair.pendingIncoming[0]");
  assert(
    stateProjection.lastIndexOf("pair.hasPendingIncoming") <
      stateProjection.lastIndexOf("pair.hasPendingOutgoing"),
    "crossed pending state must prefer its incoming row",
  );
  assertStringIncludes(block, "if (pair.hasForeignBlock)");
  assertStringIncludes(block, "for (const redundant of pair.rows)");
  assert(
    block.indexOf("Friendship.update(") <
      block.indexOf("for (const redundant of pair.rows)"),
    "block must persist the dominant row before deleting duplicates",
  );
  assertStringIncludes(
    unblock,
    "if (pair.hasForeignBlock || !pair.hasOwnBlock)",
  );
  assert(
    unblock.indexOf("for (const redundant of pair.rows)") <
      unblock.lastIndexOf("Friendship.delete("),
    "unblock must keep one own-block sentinel until stale rows are gone",
  );
  assertStringIncludes(rowMutations, "if (pair.hasBlock)");
  assertStringIncludes(
    rowMutations,
    "const selectedPairFriendship = pair.rows.find",
  );
  assertStringIncludes(
    rowMutations,
    "const friendship = selectedPairFriendship;",
  );
  assert(
    !rowMutations.includes("const friendship = pair.representative"),
    "row-addressed actions must validate the selected row",
  );
  assertStringIncludes(rowMutations, "const redundantRows = pair.rows.filter");
  const acceptBranch = rowMutations.slice(
    rowMutations.indexOf('if (action === "accept")'),
    rowMutations.indexOf('} else if (action === "decline")'),
  );
  assert(
    acceptBranch.indexOf("Friendship.delete(") <
      acceptBranch.indexOf("Friendship.update("),
    "accept must delete duplicates before its final accepted update",
  );
});
