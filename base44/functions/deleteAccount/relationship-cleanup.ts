const ENTITY_PAGE_SIZE = 100;
const MAX_CLEANUP_PASSES = 8;

async function allMatchingRecords(
  store: any,
  filter: Record<string, unknown>,
): Promise<Array<Record<string, unknown>>> {
  const records: Array<Record<string, unknown>> = [];
  for (let skip = 0;; skip += ENTITY_PAGE_SIZE) {
    const page = await store.filter(
      filter,
      "created_date",
      ENTITY_PAGE_SIZE,
      skip,
    ) || [];
    records.push(...page);
    if (page.length < ENTITY_PAGE_SIZE) return records;
  }
}

async function deleteAllMatching(
  store: any,
  filter: Record<string, unknown>,
): Promise<void> {
  for (let pass = 0; pass < MAX_CLEANUP_PASSES; pass += 1) {
    const records = await allMatchingRecords(store, filter);
    if (!records.length) return;
    for (const record of records) await store.delete(record.id);
  }
  if ((await allMatchingRecords(store, filter)).length) {
    throw new Error("Account relationship records continued changing");
  }
}

async function tombstoneAllMatching(
  store: any,
  field: "reporter_user_id" | "reported_user_id",
  rawUserID: string,
  tombstoneUserID: string,
): Promise<void> {
  for (let pass = 0; pass < MAX_CLEANUP_PASSES; pass += 1) {
    const records = await allMatchingRecords(store, { [field]: rawUserID });
    if (!records.length) return;

    for (const record of records) {
      // Use a field-level CAS so a retry, a simultaneous deletion of the other
      // participant, or an administrator updating the report cannot restore a
      // raw account id or overwrite moderation evidence.
      await store.updateMany(
        { id: record.id, [field]: rawUserID },
        { $set: { [field]: tombstoneUserID } },
      );
    }
  }

  if (
    (await allMatchingRecords(store, { [field]: rawUserID })).length
  ) {
    throw new Error("Community report identity continued changing");
  }
}

/**
 * Deletes user-owned relationship/content rows. Admin-only moderation reports
 * are retained as enforcement evidence, with raw account ids replaced by the
 * stable deletion tombstone used by the rest of the retention pipeline.
 */
export async function deleteAccountRelationshipRecords(input: {
  profileCommentStore: any;
  roomInviteStore: any;
  membershipGrantStore: any;
  reportStore: any;
  wordPackStore: any;
  gameHistoryStore: any;
  aiWordPackCacheVariantStore: any;
  aiWordPackRequestResultStore: any;
  pushDeviceStore: any;
  liveActivityStore: any;
  pushEventStore: any;
  notificationReceiptStore: any;
  userID: string;
  tombstoneUserID: string;
}): Promise<void> {
  if (!input.userID || !input.tombstoneUserID) {
    throw new Error("Raw and tombstone user ids are required");
  }
  if (input.userID === input.tombstoneUserID) {
    throw new Error("Community report tombstone must replace the raw user id");
  }

  await deleteAllMatching(input.profileCommentStore, {
    author_user_id: input.userID,
  });
  await deleteAllMatching(input.profileCommentStore, {
    target_user_id: input.userID,
  });
  await deleteAllMatching(input.roomInviteStore, {
    sender_user_id: input.userID,
  });
  await deleteAllMatching(input.roomInviteStore, {
    recipient_user_id: input.userID,
  });
  await deleteAllMatching(input.membershipGrantStore, {
    user_id: input.userID,
  });
  await tombstoneAllMatching(
    input.reportStore,
    "reporter_user_id",
    input.userID,
    input.tombstoneUserID,
  );
  await tombstoneAllMatching(
    input.reportStore,
    "reported_user_id",
    input.userID,
    input.tombstoneUserID,
  );
  await deleteAllMatching(input.wordPackStore, {
    owner_user_id: input.userID,
  });
  await deleteAllMatching(input.gameHistoryStore, {
    player_user_id: input.userID,
  });
  await deleteAllMatching(input.aiWordPackCacheVariantStore, {
    user_id: input.userID,
  });
  await deleteAllMatching(input.aiWordPackRequestResultStore, {
    user_id: input.userID,
  });
  await deleteAllMatching(input.pushDeviceStore, {
    user_id: input.userID,
  });
  await deleteAllMatching(input.liveActivityStore, {
    user_id: input.userID,
  });
  await deleteAllMatching(input.pushEventStore, {
    recipient_user_id: input.userID,
  });
  await deleteAllMatching(input.pushEventStore, {
    actor_user_id: input.userID,
  });
  await deleteAllMatching(input.notificationReceiptStore, {
    user_id: input.userID,
  });
}
