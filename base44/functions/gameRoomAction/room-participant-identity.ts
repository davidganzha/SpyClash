type Entity = Record<string, unknown>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function email(value: unknown): string {
  return clean(value).toLocaleLowerCase();
}

function identityError(message: string, code: string): Error {
  return Object.assign(new Error(message), { status: 409, code });
}

/**
 * Uses the service-owned stable IDs only when the player projection and its
 * lookup index agree exactly. Legacy/incomplete rooms return null so callers
 * can perform the slower email migration path.
 */
export function storedRoomParticipantUserIDs(input: {
  players: Entity[];
  participantUserIDs: unknown;
  hostEmail: unknown;
  actor?: Entity | null;
  allowActorIdentityMigration?: boolean;
}): string[] | null {
  if (!input.players.length) return null;
  const rows = input.players.map((player) => ({
    id: clean(player.user_id),
    email: email(player.email),
  }));

  const ids = rows.map((row) => row.id);
  const emails = rows.map((row) => row.email);
  const populatedIDs = ids.filter(Boolean);
  if (
    new Set(populatedIDs).size !== populatedIDs.length ||
    new Set(emails.filter(Boolean)).size !== emails.filter(Boolean).length
  ) {
    throw identityError(
      "Room participant identity is ambiguous",
      "ambiguous_participant",
    );
  }
  if (rows.some((row) => !row.id || !row.email)) return null;

  const hostEmail = email(input.hostEmail);
  if (!hostEmail || !rows.some((row) => row.email === hostEmail)) return null;

  const actorID = clean(input.actor?.id);
  const actorEmail = email(input.actor?.email);
  const actorRow = rows.find((row) => row.email === actorEmail);
  if (actorID && actorRow && actorRow.id !== actorID) {
    if (input.allowActorIdentityMigration) return null;
    throw identityError(
      "Room participant identity does not match its account.",
      "participant_identity_mismatch",
    );
  }

  const indexed = [
    ...new Set(
      (Array.isArray(input.participantUserIDs) ? input.participantUserIDs : [])
        .map(clean)
        .filter(Boolean),
    ),
  ].sort();
  const expected = [...ids].sort();
  if (
    indexed.length !== expected.length ||
    !indexed.every((value, index) => value === expected[index])
  ) return null;

  return [...new Set(ids)];
}

export function allowsOrphanedActorIdentityRebind(action: unknown): boolean {
  return ["join_room", "leave_room"].includes(clean(action));
}

/**
 * A provider-side identity rotation can preserve a verified email while
 * replacing the Base44 user ID. Account-deletion lifecycle markers are checked
 * separately under both old and new writer leases before this can be applied.
 */
export function canRebindOrphanedActorIdentity(input: {
  player: Entity;
  actor: Entity;
  hostEmail: unknown;
  resolvedUserID: unknown;
  storedUserExists: boolean;
}): boolean {
  const storedUserID = clean(input.player?.user_id);
  const resolvedUserID = clean(input.resolvedUserID);
  const actorID = clean(input.actor?.id);
  const playerEmail = email(input.player?.email);
  const actorEmail = email(input.actor?.email);
  const hostEmail = email(input.hostEmail);

  return Boolean(
    storedUserID && resolvedUserID && actorID && playerEmail && actorEmail &&
      hostEmail &&
      storedUserID !== resolvedUserID &&
      resolvedUserID === actorID &&
      playerEmail === actorEmail &&
      playerEmail !== hostEmail &&
      input.actor?.is_verified === true &&
      input.storedUserExists === false,
  );
}

export function roomIdentityLifecycleUserIDs(input: {
  participantUserIDs: unknown[];
  persistedParticipantUserIDs?: unknown;
  players: Entity[];
  actor?: Entity | null;
  allowActorIdentityMigration?: boolean;
}): string[] {
  const actorID = clean(input.actor?.id);
  const persistedParticipantUserIDs = input.allowActorIdentityMigration &&
      Array.isArray(input.persistedParticipantUserIDs)
    ? input.persistedParticipantUserIDs
    : [];
  const storedPlayerUserIDs = input.allowActorIdentityMigration
    ? input.players.map((player) => player?.user_id)
    : [];
  return [
    ...new Set(
      [
        ...input.participantUserIDs,
        ...persistedParticipantUserIDs,
        ...storedPlayerUserIDs,
        actorID,
      ]
        .map(clean)
        .filter(Boolean),
    ),
  ];
}

export type RoomParticipantIdentityBackfillPlan = {
  expectedUserIDs: string[];
  migratedPlayers: Entity[];
  patch: Entity;
  needsWrite: boolean;
};

/**
 * Builds the complete identity patch without mutating the room. Every supplied
 * player ID is compared with the exact email resolution before a caller may
 * perform its first write. The only tolerated replacement is the single actor
 * fingerprint that was separately authorized under lifecycle leases.
 */
export function roomParticipantIdentityBackfillPlan(input: {
  players: Entity[];
  persistedParticipantUserIDs: unknown;
  expectedParticipantUserIDs: unknown[];
  resolvedUserIDsByEmail: Array<{ email: unknown; userID: unknown }>;
  authorizedActorRebind?: Entity | null;
}): RoomParticipantIdentityBackfillPlan {
  const rows = input.players.map((player) => ({
    player,
    email: email(player?.email),
    suppliedUserID: clean(player?.user_id),
  }));
  const playerEmails = rows.map((row) => row.email);
  if (
    rows.some((row) => !row.email) ||
    new Set(playerEmails).size !== playerEmails.length
  ) {
    throw identityError(
      "Room participant identity is ambiguous",
      "ambiguous_participant",
    );
  }

  const resolvedByEmail = new Map<string, string>();
  for (const resolution of input.resolvedUserIDsByEmail) {
    const resolvedEmail = email(resolution?.email);
    const resolvedUserID = clean(resolution?.userID);
    if (
      !resolvedEmail || !resolvedUserID ||
      (resolvedByEmail.has(resolvedEmail) &&
        resolvedByEmail.get(resolvedEmail) !== resolvedUserID)
    ) {
      throw identityError(
        "Room participant identity is ambiguous",
        "ambiguous_participant",
      );
    }
    resolvedByEmail.set(resolvedEmail, resolvedUserID);
  }

  const resolvedUserIDs = rows.map((row) =>
    clean(resolvedByEmail.get(row.email))
  );
  if (resolvedUserIDs.some((userID) => !userID)) {
    throw identityError(
      "Room participant identity is missing",
      "participant_missing",
    );
  }
  if (new Set(resolvedUserIDs).size !== resolvedUserIDs.length) {
    throw identityError(
      "Room participant identity is ambiguous",
      "ambiguous_participant",
    );
  }

  const expectedUserIDs = [
    ...new Set(input.expectedParticipantUserIDs.map(clean).filter(Boolean)),
  ].sort();
  const sortedResolvedUserIDs = [...resolvedUserIDs].sort();
  if (
    expectedUserIDs.length !== rows.length ||
    !expectedUserIDs.every((value, index) =>
      value === sortedResolvedUserIDs[index]
    )
  ) {
    throw identityError(
      "Room participant identity changed during migration",
      "participant_identity_mismatch",
    );
  }

  const authorized = input.authorizedActorRebind || {};
  let authorizedMismatchCount = 0;
  let playersChanged = false;
  const migratedPlayers = rows.map((row, index) => {
    const resolvedUserID = resolvedUserIDs[index];
    if (row.suppliedUserID && row.suppliedUserID !== resolvedUserID) {
      if (
        email(authorized?.playerEmail) !== row.email ||
        clean(authorized?.storedUserID) !== row.suppliedUserID ||
        clean(authorized?.resolvedUserID) !== resolvedUserID
      ) {
        throw identityError(
          "Room participant identity does not match its account.",
          "participant_identity_mismatch",
        );
      }
      authorizedMismatchCount += 1;
    }
    if (row.suppliedUserID !== resolvedUserID) playersChanged = true;
    return { ...row.player, user_id: resolvedUserID };
  });
  if (
    clean(authorized?.storedUserID) && authorizedMismatchCount !== 1
  ) {
    throw identityError(
      "Room participant identity changed during migration",
      "participant_identity_mismatch",
    );
  }

  const currentUserIDs = [
    ...new Set(
      (Array.isArray(input.persistedParticipantUserIDs)
        ? input.persistedParticipantUserIDs
        : []).map(clean).filter(Boolean),
    ),
  ].sort();
  const participantIndexChanged =
    currentUserIDs.length !== expectedUserIDs.length ||
    !currentUserIDs.every((value, index) => value === expectedUserIDs[index]);
  const patch: Entity = {};
  if (participantIndexChanged) patch.participant_user_ids = expectedUserIDs;
  if (playersChanged) patch.players = migratedPlayers;

  return {
    expectedUserIDs,
    migratedPlayers,
    patch,
    needsWrite: playersChanged || participantIndexChanged,
  };
}
