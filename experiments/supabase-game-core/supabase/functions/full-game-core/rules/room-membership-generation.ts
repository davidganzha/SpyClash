type Entity = Record<string, any>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function key(value: unknown): string {
  return clean(value).toLocaleLowerCase();
}

export function validatedMembershipGeneration(
  value: unknown,
  randomUUID: () => string = () => crypto.randomUUID(),
): string {
  const candidate = clean(value);
  if (!candidate) return randomUUID();
  if (!/^[a-z0-9_-]{8,128}$/i.test(candidate)) {
    throw Object.assign(new Error("Membership generation is invalid."), {
      status: 400,
      code: "membership_generation_invalid",
    });
  }
  return candidate;
}

export function validatedExpectedMembershipGeneration(
  value: unknown,
): string {
  if (value === null || value === undefined) return "";
  if (typeof value !== "string") {
    throw Object.assign(new Error("Membership generation is invalid."), {
      status: 400,
      code: "membership_generation_invalid",
    });
  }
  const candidate = value.trim();
  if (!candidate) return "";
  if (candidate.length > 512 || /[\u0000-\u001F\u007F]/.test(candidate)) {
    throw Object.assign(new Error("Membership generation is invalid."), {
      status: 400,
      code: "membership_generation_invalid",
    });
  }
  return candidate;
}

export function playerMembershipGeneration(
  room: Entity,
  player: Entity,
): string {
  const persisted = clean(player?.membership_id);
  if (persisted) return persisted;
  const roomID = clean(room?.id);
  const identity = clean(player?.user_id) || key(player?.email);
  return roomID && identity ? `legacy_${roomID}_${identity}` : "";
}

export function viewerMembershipGeneration(
  room: Entity,
  viewer: Entity,
): string {
  const userID = clean(viewer?.id);
  const email = key(viewer?.email);
  const players = Array.isArray(room?.players) ? room.players : [];
  const player = players.find((candidate: Entity) =>
    (userID && clean(candidate?.user_id) === userID) ||
    (email && key(candidate?.email) === email)
  );
  return player ? playerMembershipGeneration(room, player) : "";
}

function roomExitMembershipConflict(): Error {
  return Object.assign(
    new Error("Room membership changed; refresh before leaving again."),
    {
      status: 409,
      code: "room_exit_membership_conflict",
    },
  );
}

export function captureRoomExitMembershipGeneration(input: {
  room: Entity;
  user: Entity;
  expected: unknown;
  expectedRevision?: unknown;
}): string {
  // Legacy clients did not send a membership CAS. Bind their request to the
  // generation visible on the server before it can wait behind writer leases,
  // so a later leave -> rejoin cannot be removed by that delayed request.
  assertExpectedMembershipGeneration(input);
  const expected = clean(input.expected);
  const captured = expected || viewerMembershipGeneration(
    input.room,
    input.user,
  );
  if (!captured) throw roomExitMembershipConflict();
  return captured;
}

export function assertExpectedMembershipGeneration(input: {
  room: Entity;
  user: Entity;
  expected: unknown;
  expectedRevision?: unknown;
}): void {
  const expected = clean(input.expected);
  if (expected) {
    const current = viewerMembershipGeneration(input.room, input.user);
    if (current && current === expected) return;
    throw roomExitMembershipConflict();
  }
  const hasLegacyRevision = input.expectedRevision !== null &&
    input.expectedRevision !== undefined &&
    clean(input.expectedRevision) !== "";
  if (!hasLegacyRevision) return;
  const expectedRevision = Number(input.expectedRevision);
  const currentRevision = Number(input.room?.room_revision);
  if (
    Number.isInteger(expectedRevision) && expectedRevision >= 0 &&
    Number.isInteger(currentRevision) && currentRevision === expectedRevision
  ) return;
  throw Object.assign(
    new Error("Room membership changed; refresh before leaving again."),
    {
      status: 409,
      code: "room_exit_revision_conflict",
      current_revision: Number.isInteger(currentRevision)
        ? currentRevision
        : null,
    },
  );
}
