import {
  acquireBillingWriterLease,
  assertBillingWriterLease,
  type BillingIdentityLease,
  releaseBillingWriterLease,
} from "./billing-identity-lifecycle.ts";
import {
  boundedText,
  clean,
  normalizeAPNSToken,
  preferences,
  PushContractError,
  requireActivityBinding,
  requireBundleID,
  requireEnvironment,
  requireInstallationID,
  requireLiveActivityKind,
} from "./contracts.ts";
import { digest, encryptPushToken, tokenBinding } from "./token-crypto.ts";
import { queueLiveRetry } from "./live-delivery.ts";
import {
  committedRoomCloseReceipt,
  roomCloseCommitReceiptID,
} from "./forced-live-end-authorization.ts";

type Entity = Record<string, any>;
type Persist = <T>(writer: () => Promise<T>) => Promise<T>;

const PAGE_SIZE = 100;
const MAX_ACTIVE_DEVICES_PER_USER = 8;
const MAX_ACTIVE_LIVE_TOKENS_PER_USER = 16;
const TERMINAL_REGISTRATION_PROBE_MS = 30_000;
// ActivityKit automatically ends a Live Activity after 8 hours and can retain
// the ended UI for at most 4 more. A per-activity APNs token older than 12
// hours cannot represent an updateable Activity anymore.
const MAX_PER_ACTIVITY_TOKEN_AGE_MS = 12 * 60 * 60 * 1_000;

async function matching(
  store: any,
  filter: Record<string, unknown>,
): Promise<Entity[]> {
  const records: Entity[] = [];
  for (let skip = 0;; skip += PAGE_SIZE) {
    const page = await store.filter(filter, "created_date", PAGE_SIZE, skip) ||
      [];
    records.push(...page);
    if (page.length < PAGE_SIZE) return records;
  }
}

function canonical(records: Entity[]): Entity | null {
  return [...records].sort((left, right) =>
    clean(left.created_date).localeCompare(clean(right.created_date)) ||
    clean(left.id).localeCompare(clean(right.id))
  )[0] || null;
}

function perActivityTokenExpired(record: Entity, now: Date): boolean {
  if (
    clean(record.token_kind) !== "activity" ||
    clean(record.status) !== "active"
  ) return false;
  const created = Date.parse(
    clean(record.created_at || record.created_date || record.last_seen_at),
  );
  return Number.isFinite(created) &&
    now.getTime() - created >= MAX_PER_ACTIVITY_TOKEN_AGE_MS;
}

async function deleteRecords(
  records: Entity[],
  keepID: string,
  persist: Persist,
  store: any,
): Promise<void> {
  const seen = new Set<string>();
  for (const record of records) {
    const recordID = clean(record.id);
    if (!recordID || seen.has(recordID)) continue;
    seen.add(recordID);
    if (clean(record.id) === keepID) continue;
    await persist(() => store.delete(record.id));
  }
}

export async function withPushWriterLeases<T>(input: {
  lifecycleStore: any;
  userIDs: readonly unknown[];
  action: (persist: Persist) => Promise<T>;
}): Promise<T> {
  const userIDs = [...new Set(input.userIDs.map(clean).filter(Boolean))].sort();
  if (!userIDs.length) {
    throw new PushContractError("A stable user is required.", 401);
  }
  const leases: BillingIdentityLease[] = [];
  let actionError: unknown;
  try {
    for (const userID of userIDs) {
      leases.push(
        await acquireBillingWriterLease(input.lifecycleStore, userID),
      );
    }
    const assertAll = async () => {
      for (const lease of leases) {
        await assertBillingWriterLease(input.lifecycleStore, lease);
      }
    };
    await assertAll();
    return await input.action(async <R>(writer: () => Promise<R>) => {
      await assertAll();
      return await writer();
    });
  } catch (error) {
    actionError = error;
    throw error;
  } finally {
    const failures: unknown[] = [];
    for (const lease of [...leases].reverse()) {
      try {
        await releaseBillingWriterLease(input.lifecycleStore, lease);
      } catch (error) {
        failures.push(error);
      }
    }
    if (failures.length) {
      console.error(
        actionError
          ? "push lifecycle lease release failed after action error"
          : "push lifecycle lease release failed after committed action",
      );
    }
  }
}

export async function deviceTokenOwnerIDs(
  deviceStore: any,
  tokenHash: string,
): Promise<string[]> {
  return [
    ...new Set(
      (await matching(deviceStore, { token_hash: tokenHash }))
        .map((record) => clean(record.user_id))
        .filter(Boolean),
    ),
  ];
}

export async function registerDevice(input: {
  deviceStore: any;
  userID: string;
  body: Record<string, unknown>;
  persist: Persist;
  leasedUserIDs?: readonly string[];
  now?: Date;
}): Promise<Entity> {
  const now = input.now || new Date();
  const nowISO = now.toISOString();
  const installationID = requireInstallationID(input.body.installation_id);
  const token = normalizeAPNSToken(input.body.apns_token);
  const environment = requireEnvironment(input.body.environment);
  const bundleID = requireBundleID(input.body.bundle_id);
  const installationHash = await digest(installationID, "installation");
  const tokenHash = await digest(token, "apns-token");
  const existingForToken = await matching(input.deviceStore, {
    token_hash: tokenHash,
  });
  const foreignOwners = existingForToken.filter((record) =>
    clean(record.user_id) && clean(record.user_id) !== input.userID
  );
  const leased = new Set((input.leasedUserIDs || [input.userID]).map(clean));
  if (foreignOwners.some((record) => !leased.has(clean(record.user_id)))) {
    throw new PushContractError(
      "Device ownership changed. Retry registration.",
      409,
      "device_owner_changed",
    );
  }
  for (const record of existingForToken) {
    if (clean(record.user_id) !== input.userID) {
      await input.persist(() => input.deviceStore.delete(record.id));
    }
  }

  const existingForInstallation = await matching(input.deviceStore, {
    user_id: input.userID,
    installation_id_hash: installationHash,
  });
  const existing = canonical([
    ...existingForToken.filter((record) =>
      clean(record.user_id) === input.userID
    ),
    ...existingForInstallation,
  ]);
  if (!existing) {
    const activeForUser = await matching(input.deviceStore, {
      user_id: input.userID,
      status: "active",
    });
    if (activeForUser.length >= MAX_ACTIVE_DEVICES_PER_USER) {
      throw new PushContractError(
        "Too many active devices are registered.",
        429,
        "push_device_limit",
      );
    }
  }
  const currentPreferences = preferences(input.body.preferences, {
    friendRequests: existing?.friend_requests_enabled !== false,
    roomInvites: existing?.room_invites_enabled !== false,
    gameUpdates: existing?.game_updates_enabled !== false,
    announcements: existing?.announcements_enabled !== false,
  });
  const encryptionRecord = {
    user_id: input.userID,
    token_hash: tokenHash,
    token_kind: "alert",
  };
  const encrypted = await encryptPushToken(
    token,
    tokenBinding(encryptionRecord),
  );
  const patch = {
    user_id: input.userID,
    installation_id_hash: installationHash,
    token_hash: tokenHash,
    token_ciphertext: encrypted.ciphertext,
    token_iv: encrypted.iv,
    environment,
    bundle_id: bundleID,
    locale: boundedText(input.body.locale, 32),
    app_version: boundedText(input.body.app_version, 64),
    alert_authorized: input.body.alert_authorized === true,
    friend_requests_enabled: currentPreferences.friendRequests,
    room_invites_enabled: currentPreferences.roomInvites,
    game_updates_enabled: currentPreferences.gameUpdates,
    announcements_enabled: currentPreferences.announcements,
    status: "active",
    revoked_at: null,
    last_seen_at: nowISO,
    updated_at: nowISO,
  };
  let saved: Entity;
  if (existing?.id) {
    saved = await input.persist(() =>
      input.deviceStore.update(existing.id, patch)
    );
  } else {
    saved = await input.persist(() =>
      input.deviceStore.create({ ...patch, created_at: nowISO })
    );
  }
  await deleteRecords(
    [...existingForToken, ...existingForInstallation].filter((record) =>
      clean(record.user_id) === input.userID
    ),
    clean(saved.id),
    input.persist,
    input.deviceStore,
  );
  return saved;
}

function roomHasUser(room: Entity, userID: string): boolean {
  if (
    Array.isArray(room?.participant_user_ids) &&
    room.participant_user_ids.includes(userID)
  ) {
    return true;
  }
  return Array.isArray(room?.players) &&
    room.players.some((player: Entity) => clean(player?.user_id) === userID);
}

function roomIsTerminal(room: Entity | null | undefined): boolean {
  return Boolean(room?.close_intent) ||
    ["finished", "ended", "closed"].includes(
      clean(room?.status).toLowerCase(),
    );
}

export async function committedGameFinishReceipt(input: {
  eventStore?: any;
  userID: string;
  roomID: string;
  matchID: string;
}): Promise<string> {
  if (!input.eventStore) return "";
  const sourceEventID = `game-finished:${input.matchID}`;
  const dedupeKey = `game_finished:${sourceEventID}:${input.userID}`;
  const events = await input.eventStore.filter({ dedupe_key: dedupeKey }) || [];
  return events.some((event: Entity) =>
      clean(event.source_event_id) === sourceEventID &&
      clean(event.event_type) === "game_finished" &&
      clean(event.source_type) === "game_room" &&
      clean(event.recipient_user_id) === input.userID &&
      clean(event.room_id) === input.roomID &&
      clean(event.match_id) === input.matchID &&
      event.inbox_visible !== true &&
      Boolean(clean(event.inbox_committed_at))
    )
    ? sourceEventID
    : "";
}

function exactPendingForceEnd(
  registration: Entity,
  roomID: string,
  matchID: string,
): boolean {
  return registration.pending_force_end === true &&
    clean(registration.pending_room_id) === roomID &&
    clean(registration.pending_match_id) === matchID;
}

export async function registerLiveActivity(input: {
  liveActivityStore: any;
  roomStore: any;
  eventStore?: any;
  signalStore?: any;
  userID: string;
  body: Record<string, unknown>;
  persist: Persist;
  leasedUserIDs?: readonly string[];
  now?: Date;
}): Promise<Entity> {
  const now = input.now || new Date();
  const nowISO = now.toISOString();
  const installationID = requireInstallationID(input.body.installation_id);
  const token = normalizeAPNSToken(input.body.live_activity_token);
  const tokenKind = requireLiveActivityKind(input.body.token_kind);
  const environment = requireEnvironment(input.body.environment);
  const bundleID = requireBundleID(input.body.bundle_id);
  const installationHash = await digest(installationID, "installation");
  const tokenHash = await digest(token, "live-activity-token");
  let activityIDHash = "";
  let roomID = "";
  let matchID = "";
  let boundRoom: Entity | null = null;
  let boundRoomRevision = now.getTime();
  let committedCloseID = "";
  let committedFinishID = "";
  let boundRoomMatchesRegistration = false;
  if (tokenKind === "activity") {
    const binding = requireActivityBinding(input.body);
    activityIDHash = await digest(binding.activityID, "live-activity");
    roomID = binding.roomID;
    matchID = binding.matchID;
    const [rooms, closeReceipt, finishReceipt] = await Promise.all([
      input.roomStore.filter({ id: roomID }),
      committedRoomCloseReceipt({
        signalStore: input.signalStore,
        userID: input.userID,
        roomID,
        matchID,
      }),
      committedGameFinishReceipt({
        eventStore: input.eventStore,
        userID: input.userID,
        roomID,
        matchID,
      }),
    ]);
    committedCloseID = closeReceipt;
    committedFinishID = finishReceipt;
    const room = rooms[0];
    boundRoomMatchesRegistration = Boolean(
      room && matchID === clean(room.match_id) &&
        roomHasUser(room, input.userID),
    );
    // Missing, mismatched, or temporarily incomplete membership reads are not
    // negative proof under cross-function replica lag. Persist the encrypted
    // token as an isolated probation row below; marker-first reconciliation
    // will either force-end it or accept only a genuinely later exact active
    // room commit. Ordinary sync never projects it while membership is absent.
    boundRoom = room || null;
    const parsedRevision = Date.parse(clean(room?.updated_date));
    if (boundRoomMatchesRegistration && Number.isFinite(parsedRevision)) {
      boundRoomRevision = parsedRevision;
    }
  }

  const byToken = await matching(input.liveActivityStore, {
    token_hash: tokenHash,
  });
  const foreignOwners = byToken.filter((record) =>
    clean(record.user_id) && clean(record.user_id) !== input.userID
  );
  const leased = new Set((input.leasedUserIDs || [input.userID]).map(clean));
  if (foreignOwners.some((record) => !leased.has(clean(record.user_id)))) {
    throw new PushContractError(
      "Live Activity ownership changed. Retry registration.",
      409,
      "activity_owner_changed",
    );
  }
  for (const record of byToken) {
    const durableForeignEnd = clean(record.status) === "active" &&
      clean(record.token_kind) === "activity" &&
      record.pending_force_end === true;
    if (clean(record.user_id) !== input.userID && !durableForeignEnd) {
      await input.persist(() => input.liveActivityStore.delete(record.id));
    }
  }

  // Client-side unregister is best effort and can be lost when the app is
  // terminated offline. Prune server rows that ActivityKit can no longer
  // update, before applying the per-user cap.
  const userActivityRows = await matching(input.liveActivityStore, {
    user_id: input.userID,
    token_kind: "activity",
  });
  const garbageActivityIDs = new Set(
    userActivityRows.filter((record) =>
      clean(record.status) !== "active" ||
      (record.pending_force_end !== true &&
        perActivityTokenExpired(record, now))
    ).map((record) => clean(record.id)).filter(Boolean),
  );
  for (const record of userActivityRows) {
    if (garbageActivityIDs.has(clean(record.id))) {
      await input.persist(() => input.liveActivityStore.delete(record.id));
    }
  }
  const liveByToken = byToken.filter((record) =>
    !garbageActivityIDs.has(clean(record.id))
  );
  const identityFilter: Record<string, unknown> = {
    user_id: input.userID,
    installation_id_hash: installationHash,
    token_kind: tokenKind,
  };
  if (tokenKind === "activity") {
    identityFilter.activity_id_hash = activityIDHash;
  }
  const byIdentity = await matching(input.liveActivityStore, identityFilter);
  const existing = canonical([
    ...liveByToken.filter((record) => clean(record.user_id) === input.userID),
    ...byIdentity,
  ]);
  const queuedTerminalRows = tokenKind === "activity"
    ? userActivityRows.filter((record) =>
      clean(record.status) === "active" &&
      exactPendingForceEnd(record, roomID, matchID)
    )
    : [];
  const exactRoomFinishID = `game-finished:${matchID}`;
  const roomFinishID = boundRoomMatchesRegistration &&
      clean(boundRoom?.game_finished_event_id) === exactRoomFinishID
    ? exactRoomFinishID
    : "";
  const roomCloseIntent = boundRoomMatchesRegistration
    ? boundRoom?.close_intent
    : null;
  const roomCloseID = clean(roomCloseIntent?.id) &&
      clean(roomCloseIntent?.room_id) === roomID &&
      clean(roomCloseIntent?.match_id) === matchID
    ? roomCloseCommitReceiptID(matchID, roomCloseIntent.id)
    : "";
  committedFinishID = tokenKind === "activity"
    ? roomFinishID || committedFinishID
    : "";
  committedCloseID = tokenKind === "activity"
    ? roomCloseID || committedCloseID
    : "";
  const preserveForceEnd = tokenKind === "activity" &&
    (Boolean(committedFinishID) || Boolean(committedCloseID) ||
      queuedTerminalRows.length > 0);
  const pendingForceEndCommitID = preserveForceEnd
    ? committedFinishID || committedCloseID ||
      clean(
        queuedTerminalRows.find((record) =>
          clean(record.pending_force_end_commit_id)
        )?.pending_force_end_commit_id,
      )
    : "";
  const needsTerminalProbe = tokenKind === "activity" && !preserveForceEnd;
  const terminalProbeUntil = needsTerminalProbe
    ? new Date(now.getTime() + TERMINAL_REGISTRATION_PROBE_MS).toISOString()
    : null;
  const pendingRoomRevision = preserveForceEnd
    ? Math.max(
      boundRoomRevision,
      ...queuedTerminalRows.map((record) =>
        Math.max(0, Number(record.pending_room_revision || 0))
      ),
    )
    : 0;
  if (!existing) {
    const activeForUser = await matching(input.liveActivityStore, {
      user_id: input.userID,
      status: "active",
    });
    // ActivityKit can publish a late token for an older generation after a new
    // Activity already exists on the same installation. Count every active row
    // and never treat installation identity alone as proof of supersession.
    const countableActive = activeForUser;
    if (countableActive.length >= MAX_ACTIVE_LIVE_TOKENS_PER_USER) {
      throw new PushContractError(
        "Too many Live Activity tokens are registered.",
        429,
        "live_activity_limit",
      );
    }
  }
  const encryptionRecord = {
    user_id: input.userID,
    token_hash: tokenHash,
    token_kind: tokenKind,
  };
  const encrypted = await encryptPushToken(
    token,
    tokenBinding(encryptionRecord),
  );
  const patch = {
    ...identityFilter,
    token_hash: tokenHash,
    token_ciphertext: encrypted.ciphertext,
    token_iv: encrypted.iv,
    room_id: roomID,
    match_id: matchID,
    environment,
    bundle_id: bundleID,
    locale: boundedText(input.body.locale, 32),
    status: "active",
    provider_match_id: tokenKind === "activity" ? matchID : "",
    started_match_ids: Array.isArray(existing?.started_match_ids)
      ? existing.started_match_ids.map(clean).filter(Boolean).slice(-16)
      : clean(existing?.last_started_match_id)
      ? [clean(existing?.last_started_match_id)]
      : [],
    delivery_state: preserveForceEnd || needsTerminalProbe ? "retry" : "idle",
    delivery_revision: crypto.randomUUID(),
    delivery_lease_until: nowISO,
    delivery_attempt_count: 0,
    next_attempt_at: preserveForceEnd || needsTerminalProbe ? nowISO : null,
    retry_requested: preserveForceEnd || needsTerminalProbe,
    pending_room_id: preserveForceEnd || needsTerminalProbe ? roomID : "",
    pending_match_id: preserveForceEnd || needsTerminalProbe ? matchID : "",
    pending_room_revision: preserveForceEnd || needsTerminalProbe
      ? Math.max(pendingRoomRevision, boundRoomRevision)
      : 0,
    pending_force_end: preserveForceEnd,
    pending_force_end_commit_id: pendingForceEndCommitID || null,
    terminal_probe_started_at: needsTerminalProbe ? nowISO : null,
    terminal_probe_until: terminalProbeUntil,
    last_error_code: needsTerminalProbe ? "terminal_probe_pending" : "",
    ended_at: null,
    revoked_at: null,
    last_seen_at: nowISO,
    updated_at: nowISO,
  };
  const saved: Entity = existing?.id
    ? await input.persist(() =>
      input.liveActivityStore.update(existing.id, patch)
    )
    : await input.persist(() =>
      input.liveActivityStore.create({ ...patch, created_at: nowISO })
    ) as Entity;
  await deleteRecords(
    [
      ...liveByToken,
      ...byIdentity,
    ].filter((record) =>
      clean(record.user_id) === input.userID &&
      !(clean(record.status) === "active" &&
        clean(record.token_kind) === "activity" &&
        record.pending_force_end === true &&
        clean(record.id) !== clean(saved.id))
    ),
    clean(saved.id),
    input.persist,
    input.liveActivityStore,
  );
  return saved;
}

export async function unregisterInstallation(input: {
  deviceStore: any;
  liveActivityStore: any;
  userID: string;
  installationID: unknown;
  persist: Persist;
}): Promise<void> {
  const installationHash = await digest(
    requireInstallationID(input.installationID),
    "installation",
  );
  for (const store of [input.deviceStore, input.liveActivityStore]) {
    const records = await matching(store, {
      user_id: input.userID,
      installation_id_hash: installationHash,
    });
    for (const record of records) {
      if (
        store === input.liveActivityStore &&
        clean(record.status) === "active" &&
        clean(record.token_kind) === "activity" &&
        record.pending_force_end === true
      ) {
        const deliveryState = clean(record.delivery_state);
        const deliverable = deliveryState === "retry" ||
          deliveryState === "processing";
        if (!deliverable) {
          const roomID = clean(record.pending_room_id || record.room_id);
          const matchID = clean(record.pending_match_id || record.match_id);
          if (roomID && matchID) {
            const queued = await input.persist(() =>
              queueLiveRetry({
                store: input.liveActivityStore,
                registrationID: clean(record.id),
                roomID,
                matchID,
                roomRevision: Math.max(
                  0,
                  Number(record.pending_room_revision || 0),
                ),
                forceEnd: true,
              })
            );
            if (!queued) {
              const latest = (await matching(input.liveActivityStore, {
                id: clean(record.id),
              }))[0];
              if (latest && clean(latest.status) === "active") {
                throw new PushContractError(
                  "Live Activity end could not be queued.",
                  503,
                  "live_end_queue_contention",
                );
              }
            }
          }
        }
        continue;
      }
      await input.persist(() => store.delete(record.id));
    }
  }
}

export async function unregisterLiveActivity(input: {
  liveActivityStore: any;
  roomStore: any;
  userID: string;
  body: Record<string, unknown>;
  persist: Persist;
  now?: Date;
}): Promise<void> {
  const installationHash = await digest(
    requireInstallationID(input.body.installation_id),
    "installation",
  );
  const tokenKind = requireLiveActivityKind(input.body.token_kind);
  const filter: Record<string, unknown> = {
    user_id: input.userID,
    installation_id_hash: installationHash,
    token_kind: tokenKind,
  };
  if (tokenKind === "activity") {
    const activityID = boundedText(input.body.activity_id, 200);
    if (activityID) {
      filter.activity_id_hash = await digest(activityID, "live-activity");
    } else {
      const matchID = boundedText(input.body.match_id, 200);
      if (!matchID) {
        throw new PushContractError(
          "Activity or match identifier is required.",
        );
      }
      filter.match_id = matchID;
    }
  }
  const records = await matching(input.liveActivityStore, filter);
  for (const record of records) {
    if (tokenKind === "activity" && record.pending_force_end === true) {
      if (clean(record.status) === "active") {
        const deliveryState = clean(record.delivery_state);
        const deliverable = deliveryState === "retry" ||
          deliveryState === "processing";
        if (!deliverable) {
          const roomID = clean(record.pending_room_id || record.room_id);
          const matchID = clean(record.pending_match_id || record.match_id);
          const queued = roomID && matchID &&
            await input.persist(() =>
              queueLiveRetry({
                store: input.liveActivityStore,
                registrationID: clean(record.id),
                roomID,
                matchID,
                roomRevision: Math.max(
                  0,
                  Number(record.pending_room_revision || 0),
                ),
                forceEnd: true,
                now: input.now || new Date(),
              })
            );
          if (!queued) {
            const latest = (await matching(input.liveActivityStore, {
              id: clean(record.id),
            }))[0];
            if (latest && clean(latest.status) === "active") {
              throw new PushContractError(
                "Live Activity end could not be queued.",
                503,
                "live_end_queue_contention",
              );
            }
          }
        }
        // The server has already committed a terminal ActivityKit intent. Keep
        // its exact token row until the retry worker delivers or revokes it;
        // the client's local unregister must not erase that durable boundary.
        continue;
      }
      // Terminalized/revoked rows have already cleared or exhausted delivery.
      await input.persist(() => input.liveActivityStore.delete(record.id));
      continue;
    }
    if (
      tokenKind === "activity" && clean(record.status) !== "active"
    ) {
      await input.persist(() => input.liveActivityStore.delete(record.id));
      continue;
    }
    if (tokenKind === "activity") {
      const roomID = clean(record.room_id);
      const matchID = clean(record.match_id || record.provider_match_id);
      if (roomID && matchID) {
        const rooms = await matching(input.roomStore, { id: roomID });
        const room = rooms.find((candidate) => clean(candidate.id) === roomID);
        const exactActiveMatch = room && clean(room.match_id) === matchID &&
          !roomIsTerminal(room);
        if (!exactActiveMatch) {
          const parsedRevision = Date.parse(clean(room?.updated_date));
          const now = input.now || new Date();
          const queued = await input.persist(() =>
            queueLiveRetry({
              store: input.liveActivityStore,
              registrationID: clean(record.id),
              roomID,
              matchID,
              roomRevision: Number.isFinite(parsedRevision)
                ? parsedRevision
                : now.getTime(),
              forceEnd: true,
              terminalCommitID: clean(room?.game_finished_event_id),
              now,
            })
          );
          if (!queued) {
            const latest = (await matching(input.liveActivityStore, {
              id: clean(record.id),
            }))[0];
            if (latest && clean(latest.status) === "active") {
              throw new PushContractError(
                "Live Activity end could not be queued.",
                503,
                "live_end_queue_contention",
              );
            }
          }
          continue;
        }
      }
    }
    await input.persist(() => input.liveActivityStore.delete(record.id));
  }
}
