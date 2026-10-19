import {
  playerMembershipGeneration,
  validatedExpectedMembershipGeneration,
} from "./room-membership-generation.ts";

type Room = Record<string, any>;
type Player = Record<string, unknown>;

export type LobbyHostTransferRequest = {
  target_user_id?: unknown;
  target_email?: unknown;
  expected_target_membership_id?: unknown;
  expected_membership_id?: unknown;
  expected_revision?: unknown;
};

export type LobbyHostTransferTransition = {
  patch: Room;
  targetPlayer: Player;
  targetMembershipID: string;
};

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function emailKey(value: unknown): string {
  return clean(value).toLocaleLowerCase();
}

function fail(message: string, status: number, code: string): never {
  throw Object.assign(new Error(message), { status, code, retryable: false });
}

/** A transfer changes authority only; every roster/settings field is preserved. */
export function lobbyHostTransferTransition(
  room: Room,
  user: { id?: unknown; email?: unknown },
  body: LobbyHostTransferRequest,
): LobbyHostTransferTransition {
  const actorID = clean(user?.id);
  const actorEmail = emailKey(user?.email);
  const hostEmail = emailKey(room?.host_email);
  if (!actorID || !actorEmail || actorEmail !== hostEmail) {
    fail(
      "Only the current host can transfer leadership",
      403,
      "transfer_host_required",
    );
  }

  const roster: Player[] = Array.isArray(room?.players)
    ? room.players.filter((player: unknown) =>
      player && typeof player === "object" && !Array.isArray(player)
    )
    : [];
  const actors = roster.filter((player) =>
    clean(player.user_id) === actorID || emailKey(player.email) === actorEmail
  );
  if (
    actors.length !== 1 || clean(actors[0].user_id) !== actorID ||
    emailKey(actors[0].email) !== actorEmail
  ) {
    fail(
      "The current host must be an active room participant",
      403,
      "transfer_actor_identity_conflict",
    );
  }

  const status = clean(room?.status).toLocaleLowerCase();
  if (!["waiting", "ready_voting"].includes(status)) {
    fail(
      "Leadership can only be transferred in the lobby",
      409,
      "transfer_status_invalid",
    );
  }

  const expectedRevision = body?.expected_revision;
  if (
    typeof expectedRevision !== "number" ||
    !Number.isSafeInteger(expectedRevision) || expectedRevision < 0
  ) {
    fail(
      "A valid room revision is required",
      400,
      "transfer_revision_required",
    );
  }
  if (
    typeof room?.room_revision !== "number" ||
    !Number.isSafeInteger(room.room_revision) || room.room_revision < 0 ||
    room.room_revision !== expectedRevision
  ) {
    fail(
      "The lobby changed; refresh before transferring leadership",
      409,
      "transfer_revision_conflict",
    );
  }

  const actorMembership = validatedExpectedMembershipGeneration(
    body?.expected_membership_id,
  );
  if (
    actorMembership &&
    actorMembership !== playerMembershipGeneration(room, actors[0])
  ) {
    fail(
      "The host rejoined; refresh before transferring leadership",
      409,
      "transfer_actor_membership_conflict",
    );
  }

  const targetID = clean(body?.target_user_id);
  const targetEmail = clean(body?.target_email);
  if (
    typeof body?.target_user_id !== "string" ||
    !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(targetID) ||
    typeof body?.target_email !== "string" || targetEmail.length > 254 ||
    !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(targetEmail)
  ) {
    fail(
      "A stable target identity and email are required",
      400,
      "transfer_target_invalid",
    );
  }

  const matches = roster.filter((player) => clean(player.user_id) === targetID);
  if (!matches.length) {
    fail(
      "The selected operative is no longer in this lobby",
      409,
      "transfer_target_unknown",
    );
  }
  const target = matches[0];
  const resolvedEmail = emailKey(target.email);
  if (
    matches.length !== 1 || !resolvedEmail ||
    roster.filter((player) => emailKey(player.email) === resolvedEmail)
        .length !== 1
  ) {
    fail("The target identity is ambiguous", 409, "transfer_target_ambiguous");
  }
  if (emailKey(targetEmail) !== resolvedEmail) {
    fail(
      "The selected operative identity changed",
      409,
      "transfer_target_identity_conflict",
    );
  }
  if (targetID === actorID || resolvedEmail === hostEmail) {
    fail(
      "The host cannot transfer leadership to themselves",
      409,
      "transfer_self_forbidden",
    );
  }

  const expectedMembership = validatedExpectedMembershipGeneration(
    body?.expected_target_membership_id,
  );
  const targetMembershipID = playerMembershipGeneration(room, target);
  if (!expectedMembership) {
    fail(
      "The target membership is required",
      400,
      "transfer_target_membership_required",
    );
  }
  if (!targetMembershipID || expectedMembership !== targetMembershipID) {
    fail(
      "The selected operative rejoined; refresh the lobby",
      409,
      "transfer_target_membership_conflict",
    );
  }

  return {
    patch: {
      host_email: clean(target.email),
      status: "waiting",
      ready_players: [],
    },
    targetPlayer: target,
    targetMembershipID,
  };
}
