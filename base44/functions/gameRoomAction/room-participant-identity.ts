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
}): string[] | null {
  if (!input.players.length) return null;
  const rows = input.players.map((player) => ({
    id: clean(player.user_id),
    email: email(player.email),
  }));
  if (rows.some((row) => !row.id || !row.email)) return null;

  const ids = rows.map((row) => row.id);
  const emails = rows.map((row) => row.email);
  if (
    new Set(ids).size !== ids.length || new Set(emails).size !== emails.length
  ) {
    throw identityError(
      "Room participant identity is ambiguous",
      "ambiguous_participant",
    );
  }

  const hostEmail = email(input.hostEmail);
  if (!hostEmail || !rows.some((row) => row.email === hostEmail)) return null;

  const actorID = clean(input.actor?.id);
  const actorEmail = email(input.actor?.email);
  const actorRow = rows.find((row) => row.email === actorEmail);
  if (actorID && actorRow && actorRow.id !== actorID) {
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
