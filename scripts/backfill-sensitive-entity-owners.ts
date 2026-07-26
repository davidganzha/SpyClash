// Run only through scripts/run-base44-sensitive-owner-backfill.sh. Base44
// injects this authenticated SDK client without exposing an access token in
// shell history or process arguments.
declare const base44: any;

const EXPECTED_APP_ID = "69a0e57fa939f578082f8091";
const EXPECTED_ACTION = "SECURITY_CUTOVER_STEP_7_STABLE_OWNER_BACKFILL";
const REPORT_PREFIX = "SPYCLASH_SENSITIVE_OWNER_BACKFILL_REPORT=";
const APPLY = Deno.env.get("SPYCLASH_BACKFILL_APPLY") === "1";
const PAGE_SIZE = 100;
const MAX_PAGES_PER_ENTITY = 1_000;

type PublicRoomPlan = {
  id: string;
  updated_date: string;
  set: {
    participant_user_ids: string[];
    player_user_ids_by_index?: Array<{ index: number; user_id: string }>;
  };
  players_replacement_sha256?: string;
};

type PrivateRoomPlan = PublicRoomPlan & {
  replacementPlayers?: Record<string, any>[];
};

type WordPackPlan = {
  id: string;
  updated_date: string;
  set: { owner_user_id: string };
};

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function emailKey(value: unknown): string {
  return clean(value).toLocaleLowerCase();
}

function uniqueSorted(values: readonly unknown[]): string[] {
  return [...new Set(values.map(clean).filter(Boolean))].sort();
}

function sameStrings(left: readonly unknown[], right: readonly unknown[]) {
  const a = uniqueSorted(left);
  const b = uniqueSorted(right);
  return a.length === b.length && a.every((value, index) => value === b[index]);
}

function stableJson(value: unknown): string {
  if (
    value === null || typeof value === "boolean" ||
    typeof value === "number" || typeof value === "string"
  ) {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map(stableJson).join(",")}]`;
  }
  if (typeof value === "object" && value !== null) {
    const record = value as Record<string, unknown>;
    const keys = Object.keys(record)
      .filter((key) => record[key] !== undefined)
      .sort();
    return `{${
      keys.map((key) => `${JSON.stringify(key)}:${stableJson(record[key])}`)
        .join(",")
    }}`;
  }
  throw new Error("Backfill plan contains a non-JSON value.");
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function requireDigest(value: unknown, label: string): string {
  const digest = clean(value).toLocaleLowerCase();
  if (!/^[0-9a-f]{64}$/.test(digest)) {
    throw new Error(`${label} must be a lowercase SHA-256 digest.`);
  }
  return digest;
}

function emit(report: Record<string, unknown>) {
  console.log(`${REPORT_PREFIX}${JSON.stringify(report)}`);
}

async function allRecords(
  store: any,
  entityName: string,
): Promise<Record<string, any>[]> {
  const records: Record<string, any>[] = [];
  const seenIDs = new Set<string>();
  for (let pageIndex = 0; pageIndex < MAX_PAGES_PER_ENTITY; pageIndex += 1) {
    const skip = pageIndex * PAGE_SIZE;
    const page = await store.list("created_date", PAGE_SIZE, skip) || [];
    if (!Array.isArray(page) || page.length > PAGE_SIZE) {
      throw new Error(`${entityName} returned an invalid pagination page.`);
    }
    for (const record of page) {
      const id = clean(record?.id);
      if (!id) {
        throw new Error(`${entityName} contains a record without an id.`);
      }
      if (seenIDs.has(id)) {
        throw new Error(
          `${entityName} pagination returned duplicate record id ${id}.`,
        );
      }
      seenIDs.add(id);
      records.push(record);
    }
    if (page.length < PAGE_SIZE) {
      return records.sort((left, right) =>
        clean(left.id).localeCompare(clean(right.id))
      );
    }
  }
  throw new Error(
    `${entityName} exceeded the ${MAX_PAGES_PER_ENTITY}-page safety ceiling.`,
  );
}

const sourceSHA256 = requireDigest(
  Deno.env.get("SPYCLASH_BACKFILL_SOURCE_SHA256"),
  "SPYCLASH_BACKFILL_SOURCE_SHA256",
);
const lifecycleSourceSHA256 = requireDigest(
  Deno.env.get("SPYCLASH_BACKFILL_LIFECYCLE_SOURCE_SHA256"),
  "SPYCLASH_BACKFILL_LIFECYCLE_SOURCE_SHA256",
);
const roomWriteLifecycleModuleURL = clean(
  Deno.env.get("SPYCLASH_BACKFILL_ROOM_WRITE_LIFECYCLE_URL"),
);
if (!roomWriteLifecycleModuleURL.startsWith("file://")) {
  throw new Error("The wrapper-owned room lifecycle module URL is invalid.");
}
const roomWriteLifecycle = await import(roomWriteLifecycleModuleURL);
if (
  typeof roomWriteLifecycle.withRoomWriteLeases !== "function" ||
  typeof roomWriteLifecycle.assertRoomWriteLeases !== "function"
) {
  throw new Error("The reviewed room lifecycle module is incomplete.");
}
const {
  assertRoomWriteLeases,
  withRoomWriteLeases,
} = roomWriteLifecycle as {
  assertRoomWriteLeases: (context: unknown) => Promise<void>;
  withRoomWriteLeases: <T>(input: {
    lifecycleStore: any;
    userIDs: readonly unknown[];
    action: (context: unknown) => Promise<T>;
  }) => Promise<T>;
};
const finalSchemaDigestValue = clean(
  Deno.env.get("SPYCLASH_BACKFILL_FINAL_SCHEMA_REMOTE_DIGEST"),
);
const finalSchemaRemoteDigest = finalSchemaDigestValue
  ? requireDigest(
    finalSchemaDigestValue,
    "SPYCLASH_BACKFILL_FINAL_SCHEMA_REMOTE_DIGEST",
  )
  : null;
const finalSchemaVerified =
  Deno.env.get("SPYCLASH_BACKFILL_FINAL_SCHEMA_VERIFIED") === "1";

if (APPLY) {
  if (
    Deno.env.get("SPYCLASH_BACKFILL_CONFIRM_ACTION") !== EXPECTED_ACTION
  ) {
    throw new Error(
      "The exact stable-owner backfill action was not confirmed.",
    );
  }
  if (
    Deno.env.get("SPYCLASH_BACKFILL_CONFIRM_APP_ID") !== EXPECTED_APP_ID
  ) {
    throw new Error("The reviewed SpyClash Base44 app was not confirmed.");
  }
  if (!finalSchemaVerified || !finalSchemaRemoteDigest) {
    throw new Error("The canonical 20-entity final schema is not verified.");
  }
  requireDigest(
    Deno.env.get("SPYCLASH_BACKFILL_EXPECTED_PLAN_DIGEST"),
    "SPYCLASH_BACKFILL_EXPECTED_PLAN_DIGEST",
  );
}

const operator = await base44.auth.me();
const operatorRole = clean(operator?.role).toLocaleLowerCase();
if (operatorRole !== "admin") {
  throw new Error("An authenticated Base44 admin is required.");
}
const operatorIdentityMaterial = clean(operator?.id)
  ? `id:${clean(operator.id)}`
  : `email:${emailKey(operator?.email)}`;
if (operatorIdentityMaterial === "email:") {
  throw new Error("The authenticated Base44 admin has no stable identity.");
}
const operatorIdentitySHA256 = await sha256(operatorIdentityMaterial);

const [users, rooms, wordPacks] = await Promise.all([
  allRecords(base44.entities.User, "User"),
  allRecords(base44.entities.GameRoom, "GameRoom"),
  allRecords(base44.entities.WordPack, "WordPack"),
]);

const usersByEmail = new Map<string, string>();
const ambiguousEmails = new Set<string>();
for (const user of users) {
  const email = emailKey(user?.email);
  const id = clean(user?.id);
  if (!email) continue;
  const existing = usersByEmail.get(email);
  if (existing && existing !== id) {
    ambiguousEmails.add(email);
    continue;
  }
  usersByEmail.set(email, id);
}
for (const email of ambiguousEmails) usersByEmail.delete(email);

async function exactRecord(
  store: any,
  entityName: string,
  id: string,
): Promise<Record<string, any> | null> {
  const rows = await store.filter({ id }, "created_date", 2, 0) || [];
  if (!Array.isArray(rows) || rows.length > 1) {
    throw new Error(`${entityName} identity ${id} is ambiguous.`);
  }
  return rows[0] || null;
}

function currentRoomOwnerProjection(room: Record<string, any>) {
  const rawPlayers = Array.isArray(room?.players) ? room.players : [];
  const hostEmail = emailKey(room?.host_email);
  const playerEmails = rawPlayers.map((player) => emailKey(player?.email));
  const emails = [...new Set([hostEmail, ...playerEmails].filter(Boolean))];
  if (
    !hostEmail || playerEmails.some((email) => !email) ||
    emails.some((email) => !usersByEmail.has(email))
  ) {
    throw new Error("A GameRoom owner projection became unresolved.");
  }

  const participantUserIDs = uniqueSorted(
    emails.map((email) => usersByEmail.get(email)),
  );
  const existingParticipantUserIDs = uniqueSorted(
    room?.participant_user_ids || [],
  );
  if (
    existingParticipantUserIDs.length > 0 &&
    !sameStrings(existingParticipantUserIDs, participantUserIDs)
  ) {
    throw new Error("A GameRoom participant owner projection changed.");
  }

  const normalizedPlayers = rawPlayers.map((player) => {
    const expectedUserID = usersByEmail.get(emailKey(player?.email)) || "";
    const existingUserID = clean(player?.user_id);
    if (existingUserID && existingUserID !== expectedUserID) {
      throw new Error("A GameRoom player owner projection changed.");
    }
    return { ...player, user_id: expectedUserID };
  });
  return { participantUserIDs, normalizedPlayers };
}

const privateRoomPlan: PrivateRoomPlan[] = [];
const wordPackPlan: WordPackPlan[] = [];
const unresolvedRoomIDs: string[] = [];
const mismatchedRoomParticipantOwnerIDs: string[] = [];
const mismatchedRoomPlayerOwnerIDs: string[] = [];
const unresolvedWordPackIDs: string[] = [];
const mismatchedWordPackOwnerIDs: string[] = [];

for (const room of rooms) {
  const roomID = clean(room.id);
  const rawPlayers = Array.isArray(room?.players) ? room.players : [];
  const hostEmail = emailKey(room?.host_email);
  const playerEmails = rawPlayers.map((player) => emailKey(player?.email));
  const emails = [...new Set([hostEmail, ...playerEmails].filter(Boolean))];
  if (
    !hostEmail || playerEmails.some((email) => !email) ||
    emails.some((email) => !usersByEmail.has(email))
  ) {
    unresolvedRoomIDs.push(roomID);
    continue;
  }

  const participantUserIDs = uniqueSorted(
    emails.map((email) => usersByEmail.get(email)),
  );
  const existingParticipantUserIDs = uniqueSorted(
    room?.participant_user_ids || [],
  );
  if (
    existingParticipantUserIDs.length > 0 &&
    !sameStrings(existingParticipantUserIDs, participantUserIDs)
  ) {
    mismatchedRoomParticipantOwnerIDs.push(roomID);
    continue;
  }

  let playersChanged = false;
  let roomPlayerMismatch = false;
  const normalizedPlayers = rawPlayers.map((player) => {
    const expectedUserID = usersByEmail.get(emailKey(player?.email)) || "";
    const existingUserID = clean(player?.user_id);
    if (existingUserID && existingUserID !== expectedUserID) {
      roomPlayerMismatch = true;
    }
    if (existingUserID !== expectedUserID) playersChanged = true;
    return { ...player, user_id: expectedUserID };
  });
  if (roomPlayerMismatch) {
    mismatchedRoomPlayerOwnerIDs.push(roomID);
    continue;
  }

  const participantsChanged = !sameStrings(
    room?.participant_user_ids || [],
    participantUserIDs,
  );
  if (!playersChanged && !participantsChanged) continue;

  const updatedDate = clean(room?.updated_date);
  if (!updatedDate) {
    unresolvedRoomIDs.push(roomID);
    continue;
  }
  const publicPlan: PublicRoomPlan = {
    id: roomID,
    updated_date: updatedDate,
    set: { participant_user_ids: participantUserIDs },
  };
  if (playersChanged) {
    publicPlan.set.player_user_ids_by_index = normalizedPlayers.map(
      (player, index) => ({ index, user_id: clean(player.user_id) }),
    );
    publicPlan.players_replacement_sha256 = await sha256(
      stableJson(normalizedPlayers),
    );
  }
  privateRoomPlan.push({
    ...publicPlan,
    ...(playersChanged ? { replacementPlayers: normalizedPlayers } : {}),
  });
}

for (const pack of wordPacks) {
  const packID = clean(pack.id);
  const ownerEmail = emailKey(pack?.owner_email);
  const ownerUserID = usersByEmail.get(ownerEmail);
  if (!ownerEmail || !ownerUserID) {
    unresolvedWordPackIDs.push(packID);
    continue;
  }
  const existingOwnerUserID = clean(pack?.owner_user_id);
  if (existingOwnerUserID) {
    if (existingOwnerUserID !== ownerUserID) {
      mismatchedWordPackOwnerIDs.push(packID);
    }
    continue;
  }
  const updatedDate = clean(pack?.updated_date);
  if (!updatedDate) {
    unresolvedWordPackIDs.push(packID);
    continue;
  }
  wordPackPlan.push({
    id: packID,
    updated_date: updatedDate,
    set: { owner_user_id: ownerUserID },
  });
}

privateRoomPlan.sort((left, right) => left.id.localeCompare(right.id));
wordPackPlan.sort((left, right) => left.id.localeCompare(right.id));
const roomPlan: PublicRoomPlan[] = privateRoomPlan.map((plan) => ({
  id: plan.id,
  updated_date: plan.updated_date,
  set: plan.set,
  ...(plan.players_replacement_sha256
    ? { players_replacement_sha256: plan.players_replacement_sha256 }
    : {}),
}));

const blockers = {
  ambiguous_user_mappings: ambiguousEmails.size,
  unresolved_room_ids: uniqueSorted(unresolvedRoomIDs),
  mismatched_room_participant_owner_ids: uniqueSorted(
    mismatchedRoomParticipantOwnerIDs,
  ),
  mismatched_room_player_owner_ids: uniqueSorted(
    mismatchedRoomPlayerOwnerIDs,
  ),
  unresolved_word_pack_ids: uniqueSorted(unresolvedWordPackIDs),
  mismatched_word_pack_owner_ids: uniqueSorted(
    mismatchedWordPackOwnerIDs,
  ),
};
const unresolvedTotal = blockers.ambiguous_user_mappings +
  blockers.unresolved_room_ids.length +
  blockers.unresolved_word_pack_ids.length;
const mismatchTotal = blockers.mismatched_room_participant_owner_ids.length +
  blockers.mismatched_room_player_owner_ids.length +
  blockers.mismatched_word_pack_owner_ids.length;

const planEnvelope = {
  protocol: "spyclash-sensitive-owner-backfill-v2",
  app_id: EXPECTED_APP_ID,
  source_sha256: sourceSHA256,
  lifecycle_source_sha256: lifecycleSourceSHA256,
  final_schema_remote_digest: finalSchemaRemoteDigest,
  final_schema_verified: finalSchemaVerified,
  operator: {
    identity_sha256: operatorIdentitySHA256,
    role: operatorRole,
  },
  mutation_scope: {
    lifecycle_entity: "BillingIdentityLifecycle",
    game_room_fields: ["participant_user_ids", "players.user_id"],
    word_pack_fields: ["owner_user_id"],
  },
  cas_plan: {
    game_rooms: roomPlan,
    word_packs: wordPackPlan,
  },
};
const planDigest = await sha256(stableJson(planEnvelope));
const baseReport = {
  protocol: planEnvelope.protocol,
  app_id: EXPECTED_APP_ID,
  mode: APPLY ? "apply" : "dry-run",
  source_sha256: sourceSHA256,
  lifecycle_source_sha256: lifecycleSourceSHA256,
  final_schema_remote_digest: finalSchemaRemoteDigest,
  final_schema_verified: finalSchemaVerified,
  operator: planEnvelope.operator,
  mutation_scope: planEnvelope.mutation_scope,
  plan_digest: planDigest,
  users: users.length,
  rooms: rooms.length,
  room_updates: roomPlan.length,
  word_packs: wordPacks.length,
  word_pack_updates: wordPackPlan.length,
  unresolved_total: unresolvedTotal,
  mismatch_total: mismatchTotal,
  blockers,
  cas_plan: planEnvelope.cas_plan,
};

if (unresolvedTotal > 0 || mismatchTotal > 0) {
  emit({ ...baseReport, phase: "blocked" });
  if (APPLY) {
    throw new Error(
      "Backfill has unresolved or conflicting ownership mappings. No records were changed.",
    );
  }
} else if (!APPLY) {
  emit({ ...baseReport, phase: "planned" });
} else {
  const expectedPlanDigest = requireDigest(
    Deno.env.get("SPYCLASH_BACKFILL_EXPECTED_PLAN_DIGEST"),
    "SPYCLASH_BACKFILL_EXPECTED_PLAN_DIGEST",
  );
  if (expectedPlanDigest !== planDigest) {
    emit({ ...baseReport, phase: "digest-mismatch" });
    throw new Error(
      "Fresh CAS plan differs from the explicitly confirmed plan. No records were changed.",
    );
  }

  // Emit the fully validated, privacy-safe plan before the first write. The
  // system updated_date is a read-only precondition, never an updateMany CAS:
  // Base44 Production does not support that predicate for GameRoom. Instead,
  // acquire the same per-user lifecycle leases used by the mediated writers,
  // re-read and verify the complete planned projection under those leases,
  // update by stable entity id, and verify the persisted result.
  emit({ ...baseReport, phase: "pre-write" });
  let appliedRoomUpdates = 0;
  let appliedWordPackUpdates = 0;
  for (const plan of privateRoomPlan) {
    await withRoomWriteLeases({
      lifecycleStore: base44.entities.BillingIdentityLifecycle,
      userIDs: plan.set.participant_user_ids,
      action: async (leaseContext) => {
        const latest = await exactRecord(
          base44.entities.GameRoom,
          "GameRoom",
          plan.id,
        );
        if (!latest || clean(latest.updated_date) !== plan.updated_date) {
          throw new Error(
            "A GameRoom changed before its lifecycle-serialized backfill.",
          );
        }
        const projection = currentRoomOwnerProjection(latest);
        if (!sameStrings(
          projection.participantUserIDs,
          plan.set.participant_user_ids,
        )) {
          throw new Error("A GameRoom participant set changed before backfill.");
        }
        if (plan.players_replacement_sha256) {
          const currentReplacementSHA256 = await sha256(
            stableJson(projection.normalizedPlayers),
          );
          if (currentReplacementSHA256 !== plan.players_replacement_sha256) {
            throw new Error("A GameRoom player projection changed before backfill.");
          }
        }

        await assertRoomWriteLeases(leaseContext);
        const roomSet: Record<string, unknown> = {
          participant_user_ids: plan.set.participant_user_ids,
        };
        if (plan.replacementPlayers) roomSet.players = plan.replacementPlayers;
        await base44.entities.GameRoom.update(plan.id, roomSet);

        const persisted = await exactRecord(
          base44.entities.GameRoom,
          "GameRoom",
          plan.id,
        );
        if (!persisted) {
          throw new Error("A GameRoom disappeared during backfill.");
        }
        const persistedProjection = currentRoomOwnerProjection(persisted);
        if (!sameStrings(
          persistedProjection.participantUserIDs,
          plan.set.participant_user_ids,
        )) {
          throw new Error("A GameRoom owner backfill could not be verified.");
        }
        if (plan.replacementPlayers) {
          const persistedPlayersSHA256 = await sha256(
            stableJson(persisted.players || []),
          );
          if (persistedPlayersSHA256 !== plan.players_replacement_sha256) {
            throw new Error("A GameRoom player backfill could not be verified.");
          }
        }
      },
    });
    appliedRoomUpdates += 1;
  }

  for (const plan of wordPackPlan) {
    await withRoomWriteLeases({
      lifecycleStore: base44.entities.BillingIdentityLifecycle,
      userIDs: [plan.set.owner_user_id],
      action: async (leaseContext) => {
        const latest = await exactRecord(
          base44.entities.WordPack,
          "WordPack",
          plan.id,
        );
        if (!latest || clean(latest.updated_date) !== plan.updated_date) {
          throw new Error(
            "A WordPack changed before its lifecycle-serialized backfill.",
          );
        }
        const currentOwner = clean(latest.owner_user_id);
        if (currentOwner && currentOwner !== plan.set.owner_user_id) {
          throw new Error("A WordPack owner changed before backfill.");
        }

        await assertRoomWriteLeases(leaseContext);
        await base44.entities.WordPack.update(plan.id, plan.set);
        const persisted = await exactRecord(
          base44.entities.WordPack,
          "WordPack",
          plan.id,
        );
        if (clean(persisted?.owner_user_id) !== plan.set.owner_user_id) {
          throw new Error("A WordPack owner backfill could not be verified.");
        }
      },
    });
    appliedWordPackUpdates += 1;
  }

  emit({
    ...baseReport,
    phase: "completed",
    applied_room_updates: appliedRoomUpdates,
    applied_word_pack_updates: appliedWordPackUpdates,
  });
}
