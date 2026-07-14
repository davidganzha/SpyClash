// Run only through `base44 exec`; it injects an authenticated SDK client
// without exposing an access token in shell history or process arguments.
declare const base44: any;

const APPLY = Deno.env.get("SPYCLASH_BACKFILL_APPLY") === "1";
const PAGE_SIZE = 100;

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

async function allRecords(store: any): Promise<Record<string, any>[]> {
  const records: Record<string, any>[] = [];
  for (let skip = 0;; skip += PAGE_SIZE) {
    const page = await store.list("created_date", PAGE_SIZE, skip) || [];
    records.push(...page);
    if (page.length < PAGE_SIZE) return records;
  }
}

const operator = await base44.auth.me();
if (clean(operator?.role).toLocaleLowerCase() !== "admin") {
  throw new Error("An authenticated Base44 admin is required.");
}

const [users, rooms, wordPacks] = await Promise.all([
  allRecords(base44.entities.User),
  allRecords(base44.entities.GameRoom),
  allRecords(base44.entities.WordPack),
]);

const usersByEmail = new Map<string, string>();
let ambiguousUsers = 0;
for (const user of users) {
  const email = emailKey(user?.email);
  const id = clean(user?.id);
  if (!email || !id) continue;
  const existing = usersByEmail.get(email);
  if (existing && existing !== id) {
    ambiguousUsers += 1;
    continue;
  }
  usersByEmail.set(email, id);
}

if (ambiguousUsers) {
  throw new Error(
    `Backfill found ${ambiguousUsers} ambiguous user identity mapping(s). No records were changed.`,
  );
}

const roomPlan: Array<{
  id: string;
  updatedDate: string;
  participantUserIDs: string[];
  players?: Record<string, any>[];
}> = [];
const wordPackPlan: Array<{
  id: string;
  updatedDate: string;
  ownerUserID: string;
}> = [];
let unresolvedRooms = 0;
let mismatchedRoomParticipantOwners = 0;
let mismatchedRoomPlayerOwners = 0;
let unresolvedWordPacks = 0;
let mismatchedWordPackOwners = 0;

for (const room of rooms) {
  const roomID = clean(room?.id);
  const rawPlayers = Array.isArray(room?.players) ? room.players : [];
  const emails = [
    ...new Set([
      emailKey(room?.host_email),
      ...rawPlayers.map((player) => emailKey(player?.email)),
    ].filter(Boolean)),
  ];
  const playerEmails = rawPlayers.map((player) => emailKey(player?.email));
  const missing = emails.filter((email) => !usersByEmail.has(email));
  if (!emailKey(room?.host_email)) missing.push("");
  if (playerEmails.some((email) => !email)) missing.push("");
  if (!roomID || missing.length) {
    unresolvedRooms += 1;
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
    mismatchedRoomParticipantOwners += 1;
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
    mismatchedRoomPlayerOwners += 1;
    continue;
  }
  if (
    !playersChanged &&
    sameStrings(room?.participant_user_ids || [], participantUserIDs)
  ) {
    continue;
  }
  roomPlan.push({
    id: roomID,
    updatedDate: clean(room?.updated_date),
    participantUserIDs,
    ...(playersChanged ? { players: normalizedPlayers } : {}),
  });
}

for (const pack of wordPacks) {
  const packID = clean(pack?.id);
  const ownerEmail = emailKey(pack?.owner_email);
  const ownerUserID = usersByEmail.get(ownerEmail);
  if (!packID || !ownerEmail || !ownerUserID) {
    unresolvedWordPacks += 1;
    continue;
  }
  const existingOwnerUserID = clean(pack?.owner_user_id);
  if (existingOwnerUserID) {
    if (existingOwnerUserID !== ownerUserID) {
      mismatchedWordPackOwners += 1;
    }
    continue;
  }
  wordPackPlan.push({
    id: packID,
    updatedDate: clean(pack?.updated_date),
    ownerUserID,
  });
}

const report = {
  mode: APPLY ? "apply" : "dry-run",
  users: users.length,
  rooms: rooms.length,
  room_updates: roomPlan.length,
  unresolved_rooms: unresolvedRooms,
  mismatched_room_participant_owners: mismatchedRoomParticipantOwners,
  mismatched_room_player_owners: mismatchedRoomPlayerOwners,
  word_packs: wordPacks.length,
  word_pack_updates: wordPackPlan.length,
  unresolved_word_packs: unresolvedWordPacks,
  mismatched_word_pack_owners: mismatchedWordPackOwners,
};

if (
  unresolvedRooms || mismatchedRoomParticipantOwners ||
  mismatchedRoomPlayerOwners || unresolvedWordPacks ||
  mismatchedWordPackOwners
) {
  console.log(
    JSON.stringify({ ...report, mode: `blocked-${report.mode}` }, null, 2),
  );
  throw new Error(
    "Backfill has unresolved or conflicting ownership mappings. No records were changed.",
  );
}

if (APPLY) {
  // Use the system updated_date as a field-level CAS. A concurrent room join,
  // leave, or pack edit makes the update fail instead of allowing this
  // migration to overwrite a newer participant/owner projection. Room player
  // objects are rewritten only to add their email-resolved stable user_id;
  // every other player property is preserved from the CAS-protected snapshot.
  for (const plan of roomPlan) {
    if (!plan.updatedDate) {
      throw new Error("A GameRoom row has no stable CAS revision.");
    }
    const roomSet: Record<string, unknown> = {
      participant_user_ids: plan.participantUserIDs,
    };
    if (plan.players) roomSet.players = plan.players;
    const result = await base44.entities.GameRoom.updateMany(
      { id: plan.id, updated_date: plan.updatedDate },
      { $set: roomSet },
    );
    if (Number(result?.updated) !== 1) {
      throw new Error(
        "A GameRoom changed during backfill. Stop and rerun the dry-run before retrying.",
      );
    }
  }

  for (const plan of wordPackPlan) {
    if (!plan.updatedDate) {
      throw new Error("A WordPack row has no stable CAS revision.");
    }
    const result = await base44.entities.WordPack.updateMany(
      { id: plan.id, updated_date: plan.updatedDate },
      { $set: { owner_user_id: plan.ownerUserID } },
    );
    if (Number(result?.updated) !== 1) {
      throw new Error(
        "A WordPack changed during backfill. Stop and rerun the dry-run before retrying.",
      );
    }
  }
}

console.log(JSON.stringify(report, null, 2));
