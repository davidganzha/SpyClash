import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import { lobbyHostTransferTransition } from "./lobby-host-transfer-policy.ts";
import { writeRoomWithCAS } from "./room-write-cas.ts";

const actor = { id: "host-id", email: "host@example.com" };
const target = {
  target_user_id: "guest-id",
  target_email: "guest@example.com",
  expected_target_membership_id: "guest-membership-1",
  expected_membership_id: "host-membership-1",
  expected_revision: 8,
};

function room(overrides: Record<string, unknown> = {}): Record<string, any> {
  return {
    id: "room-transfer",
    room_revision: 8,
    status: "ready_voting",
    host_email: "host@example.com",
    players: [
      {
        user_id: "host-id",
        email: "host@example.com",
        membership_id: "host-membership-1",
      },
      {
        user_id: "guest-id",
        email: "guest@example.com",
        membership_id: "guest-membership-1",
      },
      {
        user_id: "third-id",
        email: "third@example.com",
        membership_id: "third-membership-1",
      },
    ],
    participant_user_ids: ["host-id", "guest-id", "third-id"],
    ready_players: ["host@example.com", "guest@example.com"],
    lobby_revision: 4,
    lobby_spy_count: 1,
    lobby_word_pool: [{ id: "secret", word: "Train", enabled: true }],
    lobby_theme: "Transport",
    game_mode: "associations",
    game_duration_seconds: 900,
    ...overrides,
  };
}

function expectCode(fn: () => unknown, code: string) {
  const error = assertThrows(fn) as Error & {
    code?: string;
    retryable?: boolean;
  };
  assertEquals(error.code, code);
  assertEquals(error.retryable, false);
}

Deno.test("transfer changes only host and ready-check state without mutating the input", () => {
  for (const status of ["waiting", "ready_voting"]) {
    const original = room({ status });
    const before = structuredClone(original);
    const transition = lobbyHostTransferTransition(original, actor, target);
    assertEquals(transition.patch, {
      host_email: "guest@example.com",
      status: "waiting",
      ready_players: [],
    });
    assertEquals(transition.targetPlayer, original.players[1]);
    assertEquals(transition.targetMembershipID, "guest-membership-1");
    assertEquals(original, before);
    const updated = { ...original, ...transition.patch };
    for (
      const key of Object.keys(original).filter((key) =>
        !["host_email", "status", "ready_players"].includes(key)
      )
    ) {
      assertEquals(
        updated[key],
        original[key],
        `${key} must survive host transfer`,
      );
    }
  }
});

Deno.test("transfer requires authenticated current host identity in the roster", () => {
  for (
    const candidate of [
      { id: "guest-id", email: "guest@example.com" },
      { id: "", email: actor.email },
      { id: actor.id, email: "" },
    ]
  ) {
    expectCode(
      () => lobbyHostTransferTransition(room(), candidate, target),
      "transfer_host_required",
    );
  }
  for (
    const candidate of [
      { id: "wrong-id", email: actor.email },
      { id: actor.id, email: actor.email },
    ]
  ) {
    const source = room();
    if (candidate.id === actor.id) source.players.shift();
    expectCode(
      () => lobbyHostTransferTransition(source, candidate, target),
      "transfer_actor_identity_conflict",
    );
  }
  const duplicated = room();
  duplicated.players.push({ ...duplicated.players[0], user_id: "shadow-host" });
  expectCode(
    () => lobbyHostTransferTransition(duplicated, actor, target),
    "transfer_actor_identity_conflict",
  );
});

Deno.test("transfer accepts canonical email casing and whitespace", () => {
  const result = lobbyHostTransferTransition(
    room({ host_email: " HOST@EXAMPLE.COM " }),
    { id: actor.id, email: " HOST@example.com " },
    { ...target, target_email: " GUEST@EXAMPLE.COM " },
  );
  assertEquals(result.patch.host_email, "guest@example.com");
});

Deno.test("transfer is unavailable outside an explicit lobby state", () => {
  for (
    const status of ["roulette", "playing", "finished", "", null, "unknown"]
  ) {
    expectCode(
      () => lobbyHostTransferTransition(room({ status }), actor, target),
      "transfer_status_invalid",
    );
  }
});

Deno.test("transfer requires a strict matching room revision", () => {
  for (
    const expected_revision of [
      undefined,
      null,
      "8",
      false,
      -1,
      1.1,
      Number.MAX_SAFE_INTEGER + 1,
    ]
  ) {
    expectCode(
      () =>
        lobbyHostTransferTransition(room(), actor, {
          ...target,
          expected_revision,
        }),
      "transfer_revision_required",
    );
  }
  for (const room_revision of [7, 9, undefined, null, "8", -1, 1.1]) {
    expectCode(
      () => lobbyHostTransferTransition(room({ room_revision }), actor, target),
      "transfer_revision_conflict",
    );
  }
});

Deno.test("transfer validates stable target id and email without fallback lookup", () => {
  for (
    const invalid of [
      { target_user_id: "" },
      { target_user_id: "bad id" },
      { target_user_id: 123 },
      { target_email: "" },
      { target_email: "bad-email" },
      { target_email: undefined },
    ]
  ) {
    expectCode(
      () =>
        lobbyHostTransferTransition(room(), actor, { ...target, ...invalid }),
      "transfer_target_invalid",
    );
  }
  expectCode(
    () =>
      lobbyHostTransferTransition(room(), actor, {
        ...target,
        target_user_id: "unknown-id",
      }),
    "transfer_target_unknown",
  );
  expectCode(
    () =>
      lobbyHostTransferTransition(room(), actor, {
        ...target,
        target_email: "third@example.com",
      }),
    "transfer_target_identity_conflict",
  );
});

Deno.test("transfer fails closed for duplicate or conflicting target identities", () => {
  for (
    const duplicate of [
      { user_id: "guest-id", email: "guest@example.com" },
      { user_id: "guest-id", email: "other@example.com" },
      { user_id: "other-id", email: "GUEST@example.com" },
    ]
  ) {
    const source = room();
    source.players.push(duplicate);
    expectCode(
      () => lobbyHostTransferTransition(source, actor, target),
      "transfer_target_ambiguous",
    );
  }
});

Deno.test("transfer cannot select the host themselves", () => {
  expectCode(() =>
    lobbyHostTransferTransition(room(), actor, {
      ...target,
      target_user_id: actor.id,
      target_email: actor.email,
      expected_target_membership_id: "host-membership-1",
    }), "transfer_self_forbidden");
});

Deno.test("transfer fences a target and actor that left and rejoined", () => {
  expectCode(
    () =>
      lobbyHostTransferTransition(room(), actor, {
        ...target,
        expected_target_membership_id: "",
      }),
    "transfer_target_membership_required",
  );
  const targetRejoined = room();
  targetRejoined.players[1].membership_id = "guest-membership-2";
  expectCode(
    () => lobbyHostTransferTransition(targetRejoined, actor, target),
    "transfer_target_membership_conflict",
  );
  const actorRejoined = room();
  actorRejoined.players[0].membership_id = "host-membership-2";
  expectCode(
    () => lobbyHostTransferTransition(actorRejoined, actor, target),
    "transfer_actor_membership_conflict",
  );
});

Deno.test("legacy membership is fenced by the deterministic stable-id generation", () => {
  const source = room();
  delete source.players[1].membership_id;
  const transfer = lobbyHostTransferTransition(source, actor, {
    ...target,
    expected_target_membership_id: "legacy_room-transfer_guest-id",
    expected_membership_id: undefined,
  });
  assertEquals(transfer.targetMembershipID, "legacy_room-transfer_guest-id");
});

Deno.test("old host cannot repeat transfer after authority changes", () => {
  const source = room();
  const first = lobbyHostTransferTransition(source, actor, target);
  const persisted = { ...source, ...first.patch, room_revision: 9 };
  expectCode(
    () =>
      lobbyHostTransferTransition(persisted, actor, {
        ...target,
        expected_revision: 9,
      }),
    "transfer_host_required",
  );
  const next = lobbyHostTransferTransition(persisted, {
    id: "guest-id",
    email: "guest@example.com",
  }, {
    target_user_id: "third-id",
    target_email: "third@example.com",
    expected_target_membership_id: "third-membership-1",
    expected_revision: 9,
  });
  assertEquals(next.patch.host_email, "third@example.com");
});

Deno.test("a racing ready check cannot be overwritten by the transfer CAS", async () => {
  const source = room({ status: "waiting" });
  const { patch } = lobbyHostTransferTransition(source, actor, target);
  const persisted: Record<string, any> = {
    ...source,
    status: "ready_voting",
    room_revision: 9,
  };
  let writes = 0;
  const error = await assertRejects(() =>
    writeRoomWithCAS({
      room: source,
      patch,
      store: {
        updateMany(filter) {
          writes += 1;
          assertEquals(filter.room_revision, 8);
          return Promise.resolve({
            updated: filter.room_revision === persisted.room_revision ? 1 : 0,
          });
        },
      },
    })
  ) as Error & { code?: string };
  assertEquals(error.code, "cas_contention");
  assertEquals(writes, 1);
  assertEquals(persisted.host_email, actor.email);
  assertEquals(persisted.status, "ready_voting");
});
