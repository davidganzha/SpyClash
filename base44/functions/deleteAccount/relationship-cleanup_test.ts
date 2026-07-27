import { assertEquals } from "jsr:@std/assert@1";
import { deleteAccountRelationshipRecords } from "./relationship-cleanup.ts";

type RecordValue = Record<string, any>;

class MockStore {
  constructor(public records: RecordValue[]) {
    this.records = structuredClone(records);
  }

  async filter(
    filter: RecordValue,
    _sort: string,
    limit: number,
    skip: number,
  ) {
    return this.records
      .filter((record) =>
        Object.entries(filter).every(([key, value]) => record[key] === value)
      )
      .slice(skip, skip + limit)
      .map((record) => structuredClone(record));
  }

  async delete(id: string) {
    this.records = this.records.filter((record) => record.id !== id);
  }

  async updateMany(filter: RecordValue, update: RecordValue) {
    let updated = 0;
    this.records = this.records.map((record) => {
      const matches = Object.entries(filter).every(([key, value]) =>
        record[key] === value
      );
      if (!matches) return record;
      updated += 1;
      return { ...record, ...(update?.$set || {}) };
    });
    return { updated };
  }
}

Deno.test("relationship cleanup erases content but tombstones both moderation identities", async () => {
  const comments = new MockStore([
    { id: "comment-author", author_user_id: "target", target_user_id: "other" },
    { id: "comment-target", author_user_id: "other", target_user_id: "target" },
    { id: "comment-both", author_user_id: "target", target_user_id: "target" },
    { id: "comment-safe", author_user_id: "other", target_user_id: "third" },
  ]);
  const invites = new MockStore([
    {
      id: "invite-sender",
      sender_user_id: "target",
      recipient_user_id: "other",
    },
    {
      id: "invite-recipient",
      sender_user_id: "other",
      recipient_user_id: "target",
    },
    {
      id: "invite-both",
      sender_user_id: "target",
      recipient_user_id: "target",
    },
    { id: "invite-safe", sender_user_id: "other", recipient_user_id: "third" },
  ]);
  const grants = new MockStore([
    { id: "grant-target", user_id: "target" },
    { id: "grant-safe", user_id: "other" },
  ]);
  const reports = new MockStore([
    {
      id: "reporter-target",
      reporter_user_id: "target",
      reported_user_id: "other",
      content_snapshot: "private target-authored snapshot",
    },
    {
      id: "reported-target",
      reporter_user_id: "other",
      reported_user_id: "target",
      content_snapshot: "private snapshot about target",
    },
    {
      id: "both-target",
      reporter_user_id: "target",
      reported_user_id: "target",
      content_snapshot: "evidence remains intact",
      details: "admin-only details remain intact",
      status: "reviewing",
    },
    {
      id: "report-safe",
      reporter_user_id: "other",
      reported_user_id: "third",
      content_snapshot: "unrelated",
    },
  ]);
  const wordPacks = new MockStore([
    {
      id: "pack-target",
      owner_user_id: "target",
      owner_email: "changed@example.com",
    },
    {
      id: "pack-safe",
      owner_user_id: "other",
      owner_email: "target@example.com",
    },
  ]);
  const histories = new MockStore([
    {
      id: "history-target",
      player_user_id: "target",
      player_email: "changed@example.com",
    },
    {
      id: "history-safe",
      player_user_id: "other",
      player_email: "target@example.com",
    },
  ]);
  const aiWordPackCacheVariants = new MockStore([
    {
      id: "cache-target",
      user_id: "target",
      theme_key: "awt1-private-target-hash",
    },
    {
      id: "cache-safe",
      user_id: "other",
      theme_key: "awt1-other-hash",
    },
  ]);
  const aiWordPackRequestResults = new MockStore([
    {
      id: "request-target",
      user_id: "target",
      request_id: "private-target-request",
    },
    {
      id: "request-safe",
      user_id: "other",
      request_id: "other-request",
    },
  ]);
  const pushDevices = new MockStore([
    { id: "device-target", user_id: "target", token_ciphertext: "private" },
    { id: "device-safe", user_id: "other", token_ciphertext: "safe" },
  ]);
  const liveActivities = new MockStore([
    { id: "activity-target", user_id: "target", token_ciphertext: "private" },
    { id: "activity-safe", user_id: "other", token_ciphertext: "safe" },
  ]);
  const pushEvents = new MockStore([
    {
      id: "event-recipient",
      recipient_user_id: "target",
      actor_user_id: "other",
    },
    { id: "event-actor", recipient_user_id: "other", actor_user_id: "target" },
    { id: "event-safe", recipient_user_id: "other", actor_user_id: "third" },
  ]);
  const notificationReceipts = new MockStore([
    { id: "receipt-target", user_id: "target", notification_key: "global:1" },
    { id: "receipt-safe", user_id: "other", notification_key: "global:1" },
  ]);

  await deleteAccountRelationshipRecords({
    profileCommentStore: comments,
    roomInviteStore: invites,
    membershipGrantStore: grants,
    reportStore: reports,
    wordPackStore: wordPacks,
    gameHistoryStore: histories,
    aiWordPackCacheVariantStore: aiWordPackCacheVariants,
    aiWordPackRequestResultStore: aiWordPackRequestResults,
    pushDeviceStore: pushDevices,
    liveActivityStore: liveActivities,
    pushEventStore: pushEvents,
    notificationReceiptStore: notificationReceipts,
    userID: "target",
    tombstoneUserID: "deleted:stable-target",
  });

  assertEquals(comments.records.map((record) => record.id), ["comment-safe"]);
  assertEquals(invites.records.map((record) => record.id), ["invite-safe"]);
  assertEquals(grants.records.map((record) => record.id), ["grant-safe"]);
  assertEquals(reports.records, [
    {
      id: "reporter-target",
      reporter_user_id: "deleted:stable-target",
      reported_user_id: "other",
      content_snapshot: "private target-authored snapshot",
    },
    {
      id: "reported-target",
      reporter_user_id: "other",
      reported_user_id: "deleted:stable-target",
      content_snapshot: "private snapshot about target",
    },
    {
      id: "both-target",
      reporter_user_id: "deleted:stable-target",
      reported_user_id: "deleted:stable-target",
      content_snapshot: "evidence remains intact",
      details: "admin-only details remain intact",
      status: "reviewing",
    },
    {
      id: "report-safe",
      reporter_user_id: "other",
      reported_user_id: "third",
      content_snapshot: "unrelated",
    },
  ]);
  assertEquals(wordPacks.records.map((record) => record.id), ["pack-safe"]);
  assertEquals(histories.records.map((record) => record.id), ["history-safe"]);
  assertEquals(aiWordPackCacheVariants.records.map((record) => record.id), [
    "cache-safe",
  ]);
  assertEquals(aiWordPackRequestResults.records.map((record) => record.id), [
    "request-safe",
  ]);
  assertEquals(pushDevices.records.map((record) => record.id), ["device-safe"]);
  assertEquals(liveActivities.records.map((record) => record.id), [
    "activity-safe",
  ]);
  assertEquals(pushEvents.records.map((record) => record.id), ["event-safe"]);
  assertEquals(notificationReceipts.records.map((record) => record.id), [
    "receipt-safe",
  ]);

  // A lost response/retry must be idempotent and must not erase the retained
  // report or change its moderation evidence a second time.
  await deleteAccountRelationshipRecords({
    profileCommentStore: comments,
    roomInviteStore: invites,
    membershipGrantStore: grants,
    reportStore: reports,
    wordPackStore: wordPacks,
    gameHistoryStore: histories,
    aiWordPackCacheVariantStore: aiWordPackCacheVariants,
    aiWordPackRequestResultStore: aiWordPackRequestResults,
    pushDeviceStore: pushDevices,
    liveActivityStore: liveActivities,
    pushEventStore: pushEvents,
    notificationReceiptStore: notificationReceipts,
    userID: "target",
    tombstoneUserID: "deleted:stable-target",
  });
  assertEquals(reports.records.length, 4);
  assertEquals(
    reports.records.find((record) => record.id === "both-target")
      ?.content_snapshot,
    "evidence remains intact",
  );
  assertEquals(aiWordPackCacheVariants.records.map((record) => record.id), [
    "cache-safe",
  ]);
  assertEquals(aiWordPackRequestResults.records.map((record) => record.id), [
    "request-safe",
  ]);
});
