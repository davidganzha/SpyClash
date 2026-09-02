import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import {
  allowsOrphanedActorIdentityRebind,
  canRebindOrphanedActorIdentity,
  roomIdentityLifecycleUserIDs,
  roomParticipantIdentityBackfillPlan,
  storedRoomParticipantUserIDs,
} from "./room-participant-identity.ts";
import { withRoomWriteLeases } from "./room-write-lifecycle.ts";

const players = [
  { user_id: "user-a", email: "a@spyclash.test" },
  { user_id: "user-b", email: "b@spyclash.test" },
];

Deno.test("stable room participant IDs bypass legacy email resolution", () => {
  assertEquals(
    storedRoomParticipantUserIDs({
      players,
      participantUserIDs: ["user-b", "user-a"],
      hostEmail: "A@SpyClash.Test",
      actor: { id: "user-b", email: "b@spyclash.test" },
    }),
    ["user-a", "user-b"],
  );
});

Deno.test("incomplete participant index falls back to migration", () => {
  assertEquals(
    storedRoomParticipantUserIDs({
      players,
      participantUserIDs: ["user-a"],
      hostEmail: "a@spyclash.test",
    }),
    null,
  );
});

Deno.test("stable actor mismatch fails closed", () => {
  const error = assertThrows(() =>
    storedRoomParticipantUserIDs({
      players,
      participantUserIDs: ["user-a", "user-b"],
      hostEmail: "a@spyclash.test",
      actor: { id: "attacker", email: "b@spyclash.test" },
    })
  );
  assertEquals((error as Error & { status?: number }).status, 409);
  assertEquals(
    (error as Error & { code?: string }).code,
    "participant_identity_mismatch",
  );
});

Deno.test("explicit actor migration falls back to verified resolution", () => {
  assertEquals(
    storedRoomParticipantUserIDs({
      players,
      participantUserIDs: ["user-a", "user-b"],
      hostEmail: "a@spyclash.test",
      actor: { id: "user-b-new", email: "b@spyclash.test" },
      allowActorIdentityMigration: true,
    }),
    null,
  );
});

Deno.test("duplicate room identity fails before legacy migration", () => {
  const error = assertThrows(() =>
    storedRoomParticipantUserIDs({
      players: [
        { user_id: "user-a", email: "a@spyclash.test" },
        { user_id: "", email: "a@spyclash.test" },
      ],
      participantUserIDs: ["user-a"],
      hostEmail: "a@spyclash.test",
      allowActorIdentityMigration: true,
    })
  );
  assertEquals(
    (error as Error & { code?: string }).code,
    "ambiguous_participant",
  );
});

Deno.test("only explicit join and leave may request an orphan rebind", () => {
  assertEquals(allowsOrphanedActorIdentityRebind("join_room"), true);
  assertEquals(allowsOrphanedActorIdentityRebind("leave_room"), true);
  assertEquals(allowsOrphanedActorIdentityRebind("get_room"), false);
  assertEquals(allowsOrphanedActorIdentityRebind("mark_role_card_read"), false);
});

Deno.test("verified actor may reclaim only its own orphaned room identity", () => {
  const input = {
    player: { user_id: "user-b-old", email: "b@spyclash.test" },
    actor: {
      id: "user-b-new",
      email: "B@SpyClash.Test",
      is_verified: true,
    },
    hostEmail: "a@spyclash.test",
    resolvedUserID: "user-b-new",
    storedUserExists: false,
  };
  assertEquals(canRebindOrphanedActorIdentity(input), true);
  assertEquals(
    canRebindOrphanedActorIdentity({ ...input, storedUserExists: true }),
    false,
  );
  assertEquals(
    canRebindOrphanedActorIdentity({
      ...input,
      actor: { ...input.actor, email: "attacker@spyclash.test" },
    }),
    false,
  );
  assertEquals(
    canRebindOrphanedActorIdentity({
      ...input,
      actor: { ...input.actor, is_verified: false },
    }),
    false,
  );
  assertEquals(
    canRebindOrphanedActorIdentity({
      ...input,
      resolvedUserID: "different-user",
    }),
    false,
  );
  assertEquals(
    canRebindOrphanedActorIdentity({
      ...input,
      hostEmail: "b@spyclash.test",
    }),
    false,
  );
});

Deno.test("identity migration leases both the former and current actor IDs", () => {
  assertEquals(
    roomIdentityLifecycleUserIDs({
      participantUserIDs: ["user-a", "user-b-new"],
      persistedParticipantUserIDs: ["user-a", "user-b-old", "indexed-old"],
      players: [
        { user_id: "user-a", email: "a@spyclash.test" },
        { user_id: "user-b-old", email: "b@spyclash.test" },
      ],
      actor: { id: "user-b-new", email: "b@spyclash.test" },
      allowActorIdentityMigration: true,
    }),
    ["user-a", "user-b-new", "user-b-old", "indexed-old"],
  );
  assertEquals(
    roomIdentityLifecycleUserIDs({
      participantUserIDs: ["user-a", "user-b-new"],
      players,
      actor: { id: "user-b-new", email: "b@spyclash.test" },
      allowActorIdentityMigration: false,
    }),
    ["user-a", "user-b-new"],
  );
});

Deno.test("a deleting former identity blocks rebind before room mutation", async () => {
  const userIDs = roomIdentityLifecycleUserIDs({
    participantUserIDs: ["user-a", "user-b-new"],
    players: [
      { user_id: "user-a", email: "a@spyclash.test" },
      { user_id: "user-b-old", email: "b@spyclash.test" },
    ],
    actor: { id: "user-b-new", email: "b@spyclash.test" },
    allowActorIdentityMigration: true,
  });
  let actionCalls = 0;
  const error = await assertRejects(
    () =>
      withRoomWriteLeases({
        lifecycleStore: {},
        userIDs,
        acquire: (_store, userID) => {
          if (userID === "user-b-old") {
            throw new BillingIdentityLifecycleError(
              "deletion_in_progress",
              "former identity is deleting",
            );
          }
          return Promise.resolve({
            recordID: `${userID}-record`,
            subjectKey: `${userID}-subject`,
            state: "active" as const,
            leaseToken: `${userID}-lease`,
            leaseUntil: "2099-01-01T00:00:00.000Z",
            revision: `${userID}-revision`,
          });
        },
        release: () => Promise.resolve(),
        action: () => {
          actionCalls += 1;
          return Promise.resolve();
        },
      }),
    BillingIdentityLifecycleError,
  );
  assertEquals(error.code, "deletion_in_progress");
  assertEquals(actionCalls, 0);
});

Deno.test("the authorized actor is the only identity replaced by the plan", () => {
  const plan = roomParticipantIdentityBackfillPlan({
    players: [
      { user_id: "user-a", email: "a@spyclash.test" },
      { user_id: "actor-old", email: "actor@spyclash.test" },
    ],
    persistedParticipantUserIDs: ["user-a", "actor-old"],
    expectedParticipantUserIDs: ["user-a", "actor-new"],
    resolvedUserIDsByEmail: [
      { email: "a@spyclash.test", userID: "user-a" },
      { email: "actor@spyclash.test", userID: "actor-new" },
    ],
    authorizedActorRebind: {
      playerEmail: "actor@spyclash.test",
      storedUserID: "actor-old",
      resolvedUserID: "actor-new",
    },
  });
  assertEquals(plan.needsWrite, true);
  assertEquals(plan.expectedUserIDs, ["actor-new", "user-a"]);
  assertEquals(plan.patch.participant_user_ids, ["actor-new", "user-a"]);
  assertEquals(
    (plan.patch.players as Array<{ user_id: string }>).map((player) =>
      player.user_id
    ),
    ["user-a", "actor-new"],
  );
});

Deno.test("a second participant mismatch invalidates the complete rebind plan", () => {
  const error = assertThrows(() =>
    roomParticipantIdentityBackfillPlan({
      players: [
        { user_id: "user-a", email: "a@spyclash.test" },
        { user_id: "actor-old", email: "actor@spyclash.test" },
        { user_id: "other-old", email: "other@spyclash.test" },
      ],
      persistedParticipantUserIDs: [
        "user-a",
        "actor-old",
        "other-old",
      ],
      expectedParticipantUserIDs: [
        "user-a",
        "actor-new",
        "other-new",
      ],
      resolvedUserIDsByEmail: [
        { email: "a@spyclash.test", userID: "user-a" },
        { email: "actor@spyclash.test", userID: "actor-new" },
        { email: "other@spyclash.test", userID: "other-new" },
      ],
      authorizedActorRebind: {
        playerEmail: "actor@spyclash.test",
        storedUserID: "actor-old",
        resolvedUserID: "actor-new",
      },
    })
  );
  assertEquals(
    (error as Error & { code?: string }).code,
    "participant_identity_mismatch",
  );
});

Deno.test("rebind patch is guarded by both old and new lifecycle leases", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const authorization = source.slice(
    source.indexOf("async function authorizeOrphanedActorIdentityRebind"),
    source.indexOf("async function prepareRoomParticipantIdentityBackfill"),
  );
  assertEquals(
    authorization.includes(
      "assertRoomWriterLeaseForUser(leaseContext, suppliedUserID)",
    ),
    true,
  );
  assertEquals(
    authorization.includes(
      "assertRoomWriterLeaseForUser(leaseContext, resolvedUserID)",
    ),
    true,
  );
  assertEquals(
    source.includes("roomIdentityLifecycleUserIDs({"),
    true,
  );

  const actionStart = source.indexOf("const authorizedActorRebind =");
  const actionEnd = source.indexOf("markActionStarted();", actionStart);
  const actionPath = source.slice(actionStart, actionEnd);
  const authorizeIndex = actionPath.indexOf(
    "authorizeOrphanedActorIdentityRebind",
  );
  const prepareIndex = actionPath.indexOf(
    "prepareRoomParticipantIdentityBackfill",
  );
  const revisionIndex = actionPath.indexOf("backfillRoomWriteRevision");
  const applyIndex = actionPath.indexOf(
    "applyRoomParticipantIdentityBackfill",
  );
  assertEquals(
    authorizeIndex >= 0 && authorizeIndex < prepareIndex &&
      prepareIndex < revisionIndex && revisionIndex < applyIndex,
    true,
  );

  const prepareDefinition = source.slice(
    source.indexOf("async function prepareRoomParticipantIdentityBackfill"),
    source.indexOf("async function applyRoomParticipantIdentityBackfill"),
  );
  assertEquals(prepareDefinition.includes("updateRoom("), false);
});
