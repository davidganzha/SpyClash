import { createClient, createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import {
  clean,
  constantTimeEqual,
  normalizeAPNSToken,
  PushContractError,
} from "./contracts.ts";
import {
  deviceTokenOwnerIDs,
  registerDevice,
  registerLiveActivity,
  unregisterInstallation,
  unregisterLiveActivity,
  withPushWriterLeases,
} from "./device-registration.ts";
import { decryptPushToken, digest, tokenBinding } from "./token-crypto.ts";
import {
  alertCollapseID,
  alertPayload,
  claimPushEvent,
  completePushEvent,
  preferenceAllows,
  pushEventLifecycleUserIDs,
  retryAt,
  validatePushSource,
} from "./push-events.ts";
import { sendAlertPush } from "./apns.ts";
import { clampDeadline, runBounded } from "./bounded-work.ts";
import {
  sendLiveActivityTermination,
  sendLiveActivityUpdate,
} from "./live-activity.ts";
import {
  claimLiveDelivery,
  completeLiveDelivery,
  liveDeliveryDue,
  liveRetryAt,
  MAX_LIVE_DELIVERY_ATTEMPTS,
  queueLiveRetry,
} from "./live-delivery.ts";
import { isAdminAutomationUser, scheduledDrainArgs } from "./worker-auth.ts";
import {
  repairCommittedRoomPushEvents,
  runCommittedRoomPushRepairIfFresh,
} from "./room-reconciliation.ts";

type Entity = Record<string, any>;
const PAGE_SIZE = 100;
const SPYCLASH_BASE44_APP_ID = "69a0e57fa939f578082f8091";
const LIVE_SYNC_BUDGET_MS = 25_000;
const DRAIN_BUDGET_MS = 55_000;

function errorResponse(error: unknown): Response {
  if (error instanceof PushContractError) {
    return Response.json({ error: error.message, code: error.code }, {
      status: error.status,
    });
  }
  if (error instanceof BillingIdentityLifecycleError) {
    const status = ["deletion_in_progress", "active_lease", "cas_contention"]
        .includes(error.code)
      ? 409
      : 503;
    return Response.json({
      error: "Push registration is temporarily unavailable.",
    }, { status });
  }
  console.error(
    "pushNotificationAction failed",
    error instanceof Error ? error.message : error,
  );
  return Response.json({ error: "Push service is temporarily unavailable." }, {
    status: 500,
  });
}

async function allMatching(
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

function roomParticipantUserIDs(room: Entity): string[] {
  return [
    ...new Set(
      [
        ...(Array.isArray(room?.participant_user_ids)
          ? room.participant_user_ids
          : []),
        ...(Array.isArray(room?.players)
          ? room.players.map((player: Entity) => player?.user_id)
          : []),
      ].map(clean).filter(Boolean),
    ),
  ].sort();
}

async function repairRoomPushOutbox(base44: any, room: Entity) {
  if (!clean(room?.id)) return 0;
  return await runCommittedRoomPushRepairIfFresh({
    room,
    repair: async (now) => {
      const userIDs = roomParticipantUserIDs(room);
      if (!userIDs.length) return 0;
      return await withPushWriterLeases({
        lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
        userIDs,
        action: async (persist) =>
          await repairCommittedRoomPushEvents({
            eventStore: base44.asServiceRole.entities.PushNotificationEvent,
            room,
            persist,
            now,
          }),
      });
    },
  });
}

async function roomForSourceEvent(base44: any, sourceEventID: string) {
  for (const field of ["game_started_event_id", "game_finished_event_id"]) {
    const rows = await allMatching(
      base44.asServiceRole.entities.GameRoom,
      { [field]: sourceEventID },
    );
    const exact = rows.find((room) => clean(room?.[field]) === sourceEventID);
    if (exact) return exact;
  }
  return null;
}

async function reconcileRecentRoomOutboxes(
  base44: any,
  deadlineEpochMs: number,
): Promise<number> {
  const rooms: Entity[] = [];
  for (const status of ["playing", "finished"]) {
    rooms.push(
      ...await base44.asServiceRole.entities.GameRoom.filter(
        { status },
        "-updated_date",
        8,
        0,
      ) || [],
    );
  }
  const uniqueRooms = rooms.filter((room, index, all) =>
    all.findIndex((candidate) => clean(candidate.id) === clean(room.id)) ===
      index
  );
  let created = 0;
  await runBounded({
    items: uniqueRooms.slice(0, 12),
    concurrency: 3,
    deadlineEpochMs,
    worker: async (room) => {
      try {
        created += await repairRoomPushOutbox(base44, room);
      } catch {
        // The committed room identity remains a durable repair source for the
        // next scheduled pass or any later process_event call.
      }
    },
  });
  return created;
}

function internalRequest(body: Entity): boolean {
  const configured = clean(Deno.env.get("PUSH_INTERNAL_SECRET"));
  return configured.length >= 32 &&
    constantTimeEqual(configured, body.internal_secret);
}

async function authenticatedUser(req: Request, body: Entity): Promise<Entity> {
  const accessToken = clean(body.access_token);
  const appID = clean(req.headers.get("Base44-App-Id"));
  const serviceHeader = clean(req.headers.get("Base44-Service-Authorization"));
  if (
    !accessToken || appID !== SPYCLASH_BASE44_APP_ID ||
    !serviceHeader.startsWith("Bearer ")
  ) throw new PushContractError("Unauthorized", 401, "unauthorized");
  // Never trust caller-selectable host/app headers for token verification.
  // The token is checked against this app on Base44's canonical API origin.
  const identityClient = createClient({
    appId: SPYCLASH_BASE44_APP_ID,
    serverUrl: "https://base44.app",
    token: accessToken,
  });
  const user = await identityClient.auth.me();
  if (!user?.id) {
    throw new PushContractError("Unauthorized", 401, "unauthorized");
  }
  return user;
}

async function revokeRegistration(
  store: any,
  registration: Entity,
  reason: string,
) {
  try {
    const now = new Date().toISOString();
    await store.updateMany(
      { id: registration.id, token_hash: registration.token_hash },
      {
        $set: {
          status: "revoked",
          revoked_at: now,
          updated_at: now,
          last_error_code: clean(reason).slice(0, 80),
        },
      },
    );
  } catch {
    // Account deletion may have removed the registration concurrently.
  }
}

async function processOneEvent(base44: any, event: Entity): Promise<Entity> {
  const store = base44.asServiceRole.entities.PushNotificationEvent;
  const claimed = await claimPushEvent(store, event);
  if (!claimed) {
    return { id: event.id, state: clean(event.state), claimed: false };
  }
  const now = new Date();
  if (Date.parse(clean(claimed.expires_at)) <= now.getTime()) {
    await completePushEvent({
      store,
      claimed,
      state: "cancelled",
      errorCode: "expired",
    });
    return { id: claimed.id, state: "cancelled" };
  }
  const source = await validatePushSource(base44, claimed);
  if (!source.valid) {
    if (source.retryable && Number(claimed.attempt_count || 1) < 8) {
      await completePushEvent({
        store,
        claimed,
        state: "retry",
        errorCode: source.reason || "source_pending",
        nextAttemptAt: retryAt(Number(claimed.attempt_count || 1), now),
      });
      return { id: claimed.id, state: "retry" };
    }
    await completePushEvent({
      store,
      claimed,
      state: "cancelled",
      errorCode: source.reason || "stale_source",
    });
    return { id: claimed.id, state: "cancelled" };
  }

  try {
    return await withPushWriterLeases({
      lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
      // Friend/invite copy discloses the actor's display name. Hold the actor
      // lease too so account deletion cannot cross source validation + APNs.
      userIDs: pushEventLifecycleUserIDs(claimed),
      action: async (persist) => {
        // The deletion lifecycle lease is held across decrypt + APNs. A delete
        // cannot cross this assertion and purge the user while a notification
        // containing their data is already in flight.
        await persist(async () => undefined);
        const stableSource = await validatePushSource(base44, claimed);
        if (!stableSource.valid) {
          const attempt = Number(claimed.attempt_count || 1);
          const canRetry = stableSource.retryable === true && attempt < 8;
          await completePushEvent({
            store,
            claimed,
            state: canRetry ? "retry" : "cancelled",
            errorCode: stableSource.reason || "stale_source",
            nextAttemptAt: canRetry ? retryAt(attempt, now) : undefined,
          });
          return { id: claimed.id, state: canRetry ? "retry" : "cancelled" };
        }
        const recipientRows = await allMatching(
          base44.asServiceRole.entities.User,
          {
            id: clean(claimed.recipient_user_id),
          },
        );
        if (recipientRows.length !== 1) {
          await completePushEvent({
            store,
            claimed,
            state: "cancelled",
            errorCode: "recipient_missing",
          });
          return { id: claimed.id, state: "cancelled" };
        }
        const recipient = recipientRows[0];
        const previouslyDelivered = new Set(
          (Array.isArray(claimed.delivered_token_hashes)
            ? claimed.delivered_token_hashes
            : [])
            .map(clean)
            .filter(Boolean),
        );
        const registrations = (await allMatching(
          base44.asServiceRole.entities.PushDeviceRegistration,
          { user_id: clean(claimed.recipient_user_id) },
        )).filter((registration) =>
          preferenceAllows(registration, clean(claimed.event_type)) &&
          !previouslyDelivered.has(clean(registration.token_hash))
        );
        if (!registrations.length) {
          const state = previouslyDelivered.size ? "delivered" : "no_devices";
          await completePushEvent({
            store,
            claimed,
            state,
            deliveredCount: previouslyDelivered.size,
            deliveredTokenHashes: [...previouslyDelivered],
          });
          return { id: claimed.id, state };
        }

        let delivered = 0;
        let failed = 0;
        let retryable = 0;
        let lastReason = "";
        await Promise.all(registrations.map(async (registration) => {
          try {
            const token = await decryptPushToken(
              clean(registration.token_ciphertext),
              clean(registration.token_iv),
              tokenBinding({ ...registration, token_kind: "alert" }),
            );
            const result = await sendAlertPush({
              token,
              environment: clean(registration.environment) === "production"
                ? "production"
                : "sandbox",
              bundleID: clean(registration.bundle_id),
              // Start and finish for one match intentionally share a collapse
              // id, so APNs replaces an offline queued start with the finish.
              collapseID: alertCollapseID(claimed),
              expiration: Math.floor(
                Date.parse(clean(claimed.expires_at)) / 1_000,
              ),
              payload: alertPayload(
                claimed,
                stableSource,
                registration.locale || recipient.language,
              ),
            });
            lastReason = result.reason;
            if (result.delivered) {
              delivered += 1;
              previouslyDelivered.add(clean(registration.token_hash));
            } else {
              failed += 1;
              if (result.retryable) retryable += 1;
              if (result.invalidateToken) {
                await revokeRegistration(
                  base44.asServiceRole.entities.PushDeviceRegistration,
                  registration,
                  result.reason,
                );
              }
            }
          } catch (error) {
            failed += 1;
            retryable += 1;
            lastReason = error instanceof PushContractError
              ? error.code
              : "credential_error";
          }
        }));

        const attempt = Number(claimed.attempt_count || 1);
        const canRetry = retryable > 0 && attempt < 8;
        const totalDelivered = previouslyDelivered.size;
        const state = canRetry
          ? "retry"
          : totalDelivered > 0 && failed > 0
          ? "partial"
          : totalDelivered > 0
          ? "delivered"
          : "failed";
        await completePushEvent({
          store,
          claimed,
          state,
          deliveredCount: totalDelivered,
          failedCount: failed,
          deliveredTokenHashes: [...previouslyDelivered],
          errorCode: lastReason,
          nextAttemptAt: canRetry ? retryAt(attempt, now) : undefined,
        });
        return { id: claimed.id, state, delivered, failed };
      },
    });
  } catch (error) {
    if (error instanceof BillingIdentityLifecycleError) {
      const deleting = error.code === "deletion_in_progress";
      const attempt = Number(claimed.attempt_count || 1);
      const canRetry = !deleting && attempt < 8;
      await completePushEvent({
        store,
        claimed,
        state: canRetry ? "retry" : "cancelled",
        errorCode: deleting
          ? "notification_party_deleting"
          : "delivery_lease_busy",
        nextAttemptAt: canRetry ? retryAt(attempt, now) : undefined,
      });
      return { id: claimed.id, state: canRetry ? "retry" : "cancelled" };
    }
    throw error;
  }
}

async function syncLiveActivities(base44: any, body: Entity): Promise<Entity> {
  const deadlineEpochMs = clampDeadline(
    body.deadline_epoch_ms,
    LIVE_SYNC_BUDGET_MS,
  );
  const roomID = clean(body.room_id);
  const matchID = clean(body.match_id);
  if (!roomID || !matchID) {
    throw new PushContractError("Room and match are required.");
  }
  const rooms = await allMatching(base44.asServiceRole.entities.GameRoom, {
    id: roomID,
  });
  const room = rooms[0];
  if (!room || clean(room.match_id) !== matchID) {
    const requestedRegistrationID = clean(body.registration_id);
    if (requestedRegistrationID) {
      const liveStore = base44.asServiceRole.entities.LiveActivityRegistration;
      const rows = await allMatching(liveStore, {
        id: requestedRegistrationID,
      });
      const registration = rows[0];
      if (registration) {
        try {
          await withPushWriterLeases({
            lifecycleStore:
              base44.asServiceRole.entities.BillingIdentityLifecycle,
            userIDs: [clean(registration.user_id)],
            action: async (persist) => {
              const now = new Date().toISOString();
              const isActivity = clean(registration.token_kind) === "activity";
              await persist(() =>
                liveStore.updateMany({
                  id: registration.id,
                  token_hash: registration.token_hash,
                  status: "active",
                  pending_match_id: matchID,
                }, {
                  $set: {
                    status: isActivity ? "ended" : "active",
                    ended_at: isActivity ? now : null,
                    delivery_state: isActivity ? "failed" : "idle",
                    retry_requested: false,
                    next_attempt_at: null,
                    pending_room_id: "",
                    pending_match_id: "",
                    pending_room_revision: 0,
                    last_error_code: "stale_match_binding",
                    updated_at: now,
                  },
                })
              );
            },
          });
        } catch {
          // Account deletion or a concurrent registration update owns the row.
        }
      }
    }
    return { ok: true, delivered: 0, skipped: 0, failed: 0, stale: true };
  }
  const participantIDs = new Set(
    [
      ...(Array.isArray(room.participant_user_ids)
        ? room.participant_user_ids
        : []),
      ...(Array.isArray(room.players)
        ? room.players.map((player: Entity) => player?.user_id)
        : []),
    ].map(clean).filter(Boolean),
  );
  const activityRegistrations = (await allMatching(
    base44.asServiceRole.entities.LiveActivityRegistration,
    { status: "active", room_id: roomID },
  )).filter((registration) => {
    if (!participantIDs.has(clean(registration.user_id))) return false;
    if (clean(registration.token_kind) !== "activity") return false;
    return clean(registration.match_id) === matchID &&
      clean(registration.provider_match_id) === matchID;
  });
  const pushToStartRegistrations: Entity[] = [];
  if (clean(room.status) !== "finished") {
    for (const userID of [...participantIDs].slice(0, 12)) {
      pushToStartRegistrations.push(
        ...await allMatching(
          base44.asServiceRole.entities.LiveActivityRegistration,
          { status: "active", user_id: userID, token_kind: "push_to_start" },
        ),
      );
    }
  }
  const activeActivityInstallations = new Set(
    activityRegistrations.map((registration) =>
      `${clean(registration.user_id)}:${
        clean(registration.installation_id_hash)
      }`
    ),
  );
  const eligiblePushToStart = pushToStartRegistrations.filter(
    (registration) => {
      const startedMatches = new Set(
        [
          ...(Array.isArray(registration.started_match_ids)
            ? registration.started_match_ids
            : []),
          registration.last_started_match_id,
        ].map(clean).filter(Boolean),
      );
      return !startedMatches.has(matchID) &&
        !activeActivityInstallations.has(
          `${clean(registration.user_id)}:${
            clean(registration.installation_id_hash)
          }`,
        );
    },
  );
  const registrationMap = new Map<string, Entity>();
  for (
    const registration of [
      ...activityRegistrations,
      ...eligiblePushToStart,
    ]
  ) {
    if (clean(registration.id)) {
      registrationMap.set(clean(registration.id), registration);
    }
  }
  const registrations = [...registrationMap.values()];
  let delivered = 0;
  let skipped = 0;
  let failed = 0;
  const requestedRegistrationID = clean(body.registration_id);
  const prioritizedRegistrations =
    (requestedRegistrationID
      ? registrations.filter((registration) =>
        clean(registration.id) === requestedRegistrationID
      )
      : registrations).sort((left, right) =>
        Number(clean(right.token_kind) === "push_to_start") -
          Number(clean(left.token_kind) === "push_to_start") ||
        Number(liveDeliveryDue(right)) - Number(liveDeliveryDue(left)) ||
        Number(left.last_revision || 0) - Number(right.last_revision || 0)
      );
  const roomRevision = Number.isFinite(Date.parse(clean(room.updated_date)))
    ? Date.parse(clean(room.updated_date))
    : 0;
  const liveStore = base44.asServiceRole.entities.LiveActivityRegistration;
  const processRegistration = async (registration: Entity) => {
    try {
      const outcome = await withPushWriterLeases({
        lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
        userIDs: [clean(registration.user_id)],
        action: async (persist) => {
          await persist(async () => undefined);
          const currentRows = await allMatching(liveStore, {
            id: clean(registration.id),
          });
          const current = currentRows[0];
          if (!current || clean(current.status) !== "active") return "skipped";
          const claimed = await claimLiveDelivery({
            store: liveStore,
            registration: current,
            roomID,
            matchID,
            roomRevision,
          });
          if (!claimed) return "skipped";
          const latestRows = await allMatching(
            base44.asServiceRole.entities.GameRoom,
            { id: roomID },
          );
          const latestRoom = latestRows[0];
          const exactActivityBinding =
            clean(claimed.token_kind) !== "activity" ||
            (clean(claimed.room_id) === roomID &&
              clean(claimed.match_id) === matchID &&
              clean(claimed.provider_match_id) === matchID);
          if (
            !latestRoom || clean(latestRoom.match_id) !== matchID ||
            !exactActivityBinding
          ) {
            await completeLiveDelivery({
              store: liveStore,
              claimed,
              state: "failed",
              errorCode: "stale_match_binding",
              patch: clean(claimed.token_kind) === "activity"
                ? { status: "ended", ended_at: new Date().toISOString() }
                : {},
            });
            return "skipped";
          }
          const minimumTimestamp = Number(claimed.last_apns_timestamp || 0) + 1;
          const sendTimestamp = Math.max(
            Math.floor(Date.now() / 1_000),
            minimumTimestamp,
          );
          let result;
          try {
            result = await sendLiveActivityUpdate({
              room: latestRoom,
              registration: claimed,
              now: new Date(sendTimestamp * 1_000),
            });
          } catch {
            const attempts = Number(claimed.delivery_attempt_count || 1);
            const canRetry = attempts < MAX_LIVE_DELIVERY_ATTEMPTS;
            await completeLiveDelivery({
              store: liveStore,
              claimed,
              state: canRetry ? "retry" : "failed",
              nextAttemptAt: canRetry ? liveRetryAt(attempts) : undefined,
              errorCode: "credential_error",
            });
            return "failed";
          }
          if (result.skipped) {
            await completeLiveDelivery({
              store: liveStore,
              claimed,
              state: "idle",
              errorCode: result.reason,
            });
            return "skipped";
          }
          if (result.delivered) {
            const afterRows = await allMatching(liveStore, {
              id: clean(claimed.id),
            });
            const after = afterRows[0] || claimed;
            const newerPending = after.retry_requested === true ||
              Number(after.pending_room_revision || 0) >
                Number(result.revision || 0) ||
              (clean(after.pending_match_id) &&
                clean(after.pending_match_id) !== matchID);
            const patch: Entity = {
              last_revision: result.revision || 0,
              last_apns_timestamp: sendTimestamp,
              provider_match_id: clean(claimed.token_kind) === "activity"
                ? matchID
                : "",
            };
            if (result.event === "start") {
              const started = new Set(
                [
                  ...(Array.isArray(after.started_match_ids)
                    ? after.started_match_ids
                    : []),
                  after.last_started_match_id,
                  matchID,
                ].map(clean).filter(Boolean),
              );
              patch.started_match_ids = [...started].slice(-16);
              patch.last_started_match_id = matchID;
            }
            if (result.event === "end") {
              patch.status = "ended";
              patch.ended_at = new Date().toISOString();
            }
            await completeLiveDelivery({
              store: liveStore,
              claimed,
              state: newerPending ? "retry" : "idle",
              nextAttemptAt: newerPending
                ? new Date().toISOString()
                : undefined,
              patch,
            });
            return "delivered";
          }
          if (result.invalidateToken) {
            await revokeRegistration(liveStore, claimed, result.reason);
          }
          const attempts = Number(claimed.delivery_attempt_count || 1);
          const canRetry = result.retryable &&
            attempts < MAX_LIVE_DELIVERY_ATTEMPTS;
          await completeLiveDelivery({
            store: liveStore,
            claimed,
            state: canRetry ? "retry" : "failed",
            nextAttemptAt: canRetry ? liveRetryAt(attempts) : undefined,
            errorCode: result.reason,
          });
          return "failed";
        },
      });
      if (outcome === "delivered") delivered += 1;
      else if (outcome === "failed") failed += 1;
      else skipped += 1;
      const retryHop = Math.max(0, Number(body.retry_hop || 0));
      if (retryHop < 2) {
        const pendingRows = await allMatching(liveStore, {
          id: clean(registration.id),
        });
        const pending = pendingRows[0];
        const pendingRoomID = clean(pending?.pending_room_id);
        const pendingMatchID = clean(pending?.pending_match_id);
        if (
          pending && liveDeliveryDue(pending) && pendingRoomID &&
          pendingMatchID
        ) {
          await syncLiveActivities(base44, {
            room_id: pendingRoomID,
            match_id: pendingMatchID,
            registration_id: pending.id,
            retry_hop: retryHop + 1,
            deadline_epoch_ms: deadlineEpochMs,
          });
        }
      }
    } catch (error) {
      failed += 1;
      await queueLiveRetry({
        store: liveStore,
        registrationID: clean(registration.id),
        roomID,
        matchID,
        roomRevision,
      }).catch(() => false);
    }
  };
  const groupsByUser = new Map<string, Entity[]>();
  for (const registration of prioritizedRegistrations) {
    const userID = clean(registration.user_id);
    const group = groupsByUser.get(userID) || [];
    group.push(registration);
    groupsByUser.set(userID, group);
  }
  const unfinishedFromStartedGroups: Entity[] = [];
  const groupWork = await runBounded({
    items: [...groupsByUser.values()],
    concurrency: 6,
    deadlineEpochMs,
    worker: async (group) => {
      for (let index = 0; index < group.length; index += 1) {
        if (Date.now() >= deadlineEpochMs) {
          unfinishedFromStartedGroups.push(...group.slice(index));
          return;
        }
        await processRegistration(group[index]);
      }
    },
  });
  const deferredRegistrations = [
    ...unfinishedFromStartedGroups,
    ...groupWork.unstarted.flat(),
  ];
  await runBounded({
    items: deferredRegistrations,
    concurrency: 8,
    deadlineEpochMs: Date.now() + 3_000,
    worker: async (registration) => {
      await queueLiveRetry({
        store: liveStore,
        registrationID: clean(registration.id),
        roomID,
        matchID,
        roomRevision,
      }).catch(() => false);
    },
  });
  return {
    ok: true,
    delivered,
    skipped,
    failed,
    deferred: deferredRegistrations.length,
    stale: false,
  };
}

async function deliverForcedLiveActivityEnd(input: {
  base44: any;
  registration: Entity;
  roomID: string;
  matchID: string;
  roomRevision: number;
  callerHoldsLifecycleLeases?: boolean;
}): Promise<"delivered" | "failed" | "skipped"> {
  const liveStore =
    input.base44.asServiceRole.entities.LiveActivityRegistration;
  const deliver = async () => {
    const rows = await allMatching(liveStore, {
      id: clean(input.registration.id),
    });
    const current = rows[0];
    if (
      !current || clean(current.status) !== "active" ||
      clean(current.token_kind) !== "activity"
    ) return "skipped" as const;
    const exactRoom = clean(current.room_id) === clean(input.roomID) &&
      clean(current.match_id) === clean(input.matchID) &&
      clean(current.provider_match_id) === clean(input.matchID);
    const exactPendingEnd = current.pending_force_end === true &&
      clean(current.pending_room_id) === clean(input.roomID) &&
      clean(current.pending_match_id) === clean(input.matchID);
    if (!exactRoom && !exactPendingEnd) return "skipped" as const;
    const claimed = await claimLiveDelivery({
      store: liveStore,
      registration: current,
      roomID: input.roomID,
      matchID: input.matchID,
      roomRevision: input.roomRevision,
      forceEnd: true,
    });
    if (!claimed) return "skipped" as const;
    let result;
    try {
      result = await sendLiveActivityTermination({
        registration: claimed,
        roomID: input.roomID,
        matchID: input.matchID,
        revision: input.roomRevision,
      });
    } catch {
      const attempts = Number(claimed.delivery_attempt_count || 1);
      const canRetry = attempts < MAX_LIVE_DELIVERY_ATTEMPTS;
      await completeLiveDelivery({
        store: liveStore,
        claimed,
        state: canRetry ? "retry" : "failed",
        nextAttemptAt: canRetry ? liveRetryAt(attempts) : undefined,
        errorCode: "credential_error",
      });
      return "failed" as const;
    }
    if (result.delivered) {
      await completeLiveDelivery({
        store: liveStore,
        claimed,
        state: "idle",
        patch: {
          status: "ended",
          ended_at: new Date().toISOString(),
          pending_force_end: false,
          last_revision: result.revision,
        },
      });
      return "delivered" as const;
    }
    if (result.invalidateToken) {
      await revokeRegistration(liveStore, claimed, result.reason);
      return "failed" as const;
    }
    const attempts = Number(claimed.delivery_attempt_count || 1);
    const canRetry = result.retryable &&
      attempts < MAX_LIVE_DELIVERY_ATTEMPTS;
    await completeLiveDelivery({
      store: liveStore,
      claimed,
      state: canRetry ? "retry" : "failed",
      nextAttemptAt: canRetry ? liveRetryAt(attempts) : undefined,
      errorCode: result.reason,
    });
    return "failed" as const;
  };
  if (input.callerHoldsLifecycleLeases) return await deliver();
  return await withPushWriterLeases({
    lifecycleStore:
      input.base44.asServiceRole.entities.BillingIdentityLifecycle,
    userIDs: [clean(input.registration.user_id)],
    action: async (persist) => {
      await persist(async () => undefined);
      return await deliver();
    },
  });
}

async function endRoomLiveActivities(
  base44: any,
  body: Entity,
): Promise<Entity> {
  const roomID = clean(body.room_id);
  const matchID = clean(body.match_id);
  if (!roomID || !matchID) {
    throw new PushContractError("Room and match are required.");
  }
  const rooms = await allMatching(base44.asServiceRole.entities.GameRoom, {
    id: roomID,
  });
  const room = rooms[0];
  if (!room || clean(room.match_id) !== matchID) {
    throw new PushContractError(
      "The room end source is stale.",
      409,
      "stale_match_binding",
    );
  }
  const roomRevision = Number.isFinite(Date.parse(clean(room.updated_date)))
    ? Date.parse(clean(room.updated_date))
    : Date.now();
  const liveStore = base44.asServiceRole.entities.LiveActivityRegistration;
  const leasedParticipantIDs = new Set(roomParticipantUserIDs(room));
  const registrations = (await allMatching(liveStore, {
    status: "active",
    room_id: roomID,
    token_kind: "activity",
  })).filter((registration) =>
    clean(registration.match_id) === matchID &&
    clean(registration.provider_match_id) === matchID
  );

  // Persist every terminal intent before the first APNs call. The caller keeps
  // the current participant lifecycle leases. A stale activity belonging to a
  // player who already left is leased here separately before touching its row.
  for (const registration of registrations) {
    const queue = async () =>
      await queueLiveRetry({
        store: liveStore,
        registrationID: clean(registration.id),
        roomID,
        matchID,
        roomRevision,
        forceEnd: true,
      });
    const queued = leasedParticipantIDs.has(clean(registration.user_id))
      ? await queue()
      : await withPushWriterLeases({
        lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
        userIDs: [clean(registration.user_id)],
        action: async (persist) => {
          await persist(async () => undefined);
          return await queue();
        },
      });
    if (!queued) {
      const latest = (await allMatching(liveStore, {
        id: clean(registration.id),
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

  let delivered = 0;
  let failed = 0;
  let skipped = 0;
  const deadlineEpochMs = clampDeadline(
    body.deadline_epoch_ms,
    LIVE_SYNC_BUDGET_MS,
  );
  const work = await runBounded({
    items: registrations,
    concurrency: 6,
    deadlineEpochMs,
    worker: async (registration) => {
      const outcome = await deliverForcedLiveActivityEnd({
        base44,
        registration,
        roomID,
        matchID,
        roomRevision,
        callerHoldsLifecycleLeases: leasedParticipantIDs.has(
          clean(registration.user_id),
        ),
      });
      if (outcome === "delivered") delivered += 1;
      else if (outcome === "failed") failed += 1;
      else skipped += 1;
    },
  });
  return {
    ok: true,
    queued: registrations.length,
    delivered,
    failed,
    skipped,
    deferred: work.unstarted.length,
  };
}

async function drainLiveActivityRetries(
  base44: any,
  limit: number,
  deadlineEpochMs: number,
): Promise<Entity[]> {
  const store = base44.asServiceRole.entities.LiveActivityRegistration;
  const candidates: Entity[] = [];
  for (const state of ["retry", "processing"]) {
    candidates.push(
      ...await store.filter(
        { status: "active", delivery_state: state },
        state === "retry" ? "next_attempt_at" : "delivery_lease_until",
        12,
        0,
      ) || [],
    );
  }
  const due = candidates.filter((registration) =>
    liveDeliveryDue(registration)
  );
  due.sort((left, right) =>
    Date.parse(clean(left.next_attempt_at || left.updated_at)) -
    Date.parse(clean(right.next_attempt_at || right.updated_at))
  );
  const results: Entity[] = [];
  const selected = due.slice(0, Math.min(limit, 6));
  const groupsByUser = new Map<string, Entity[]>();
  for (const registration of selected) {
    const userID = clean(registration.user_id);
    const group = groupsByUser.get(userID) || [];
    group.push(registration);
    groupsByUser.set(userID, group);
  }
  await runBounded({
    items: [...groupsByUser.values()],
    concurrency: 3,
    deadlineEpochMs,
    worker: async (group) => {
      for (const registration of group) {
        if (Date.now() >= deadlineEpochMs) return;
        const roomID = clean(
          registration.pending_room_id || registration.room_id,
        );
        const matchID = clean(
          registration.pending_match_id || registration.match_id,
        );
        if (!roomID || !matchID) continue;
        try {
          if (registration.pending_force_end === true) {
            results.push({
              ok: true,
              forced_end: await deliverForcedLiveActivityEnd({
                base44,
                registration,
                roomID,
                matchID,
                roomRevision: Number(
                  registration.pending_room_revision ||
                    registration.last_revision || 0,
                ),
              }),
            });
          } else {
            results.push(
              await syncLiveActivities(base44, {
                room_id: roomID,
                match_id: matchID,
                registration_id: registration.id,
                deadline_epoch_ms: deadlineEpochMs,
              }),
            );
          }
        } catch {
          // The durable retry row remains due for the next trusted drain.
        }
      }
    },
  });
  return results;
}

async function reconcileIdleLiveActivityDrift(
  base44: any,
  limit: number,
  deadlineEpochMs: number,
): Promise<Entity[]> {
  const store = base44.asServiceRole.entities.LiveActivityRegistration;
  // Oldest-idle-first gives every bound activity a periodic reconciliation
  // pass. If a gameRoomAction -> sync_live_activity invocation was lost before
  // it could mark a retry, the registration's old revision remains durable and
  // this sweep repairs it without a global room scan.
  const candidates: Entity[] = await store.filter(
    { status: "active", token_kind: "activity", delivery_state: "idle" },
    "updated_at",
    Math.min(12, Math.max(1, limit)),
    0,
  ) || [];
  const results: Entity[] = [];
  await runBounded({
    items: candidates,
    concurrency: 3,
    deadlineEpochMs,
    worker: async (registration) => {
      const roomID = clean(registration.room_id);
      const matchID = clean(registration.match_id);
      if (!roomID || !matchID) return;
      try {
        results.push(
          await syncLiveActivities(base44, {
            room_id: roomID,
            match_id: matchID,
            registration_id: registration.id,
            deadline_epoch_ms: deadlineEpochMs,
          }),
        );
      } catch {
        // The unchanged oldest-idle row is selected again on the next drain.
      }
    },
  });
  return results;
}

async function processEvents(base44: any, body: Entity): Promise<Entity> {
  const deadlineEpochMs = Date.now() + 50_000;
  const sourceEventID = clean(body.source_event_id);
  if (!sourceEventID) throw new PushContractError("Source event is required.");
  let events = await allMatching(
    base44.asServiceRole.entities.PushNotificationEvent,
    { source_event_id: sourceEventID },
  );
  if (!events.length) {
    const room = await roomForSourceEvent(base44, sourceEventID);
    if (room) {
      await repairRoomPushOutbox(base44, room);
      events = await allMatching(
        base44.asServiceRole.entities.PushNotificationEvent,
        { source_event_id: sourceEventID },
      );
    }
  }
  // ActivityKit is attempted before the ordinary event becomes terminal. If
  // this invocation is interrupted, the still-pending alert outbox remains a
  // durable trigger for the scheduled failover worker.
  const roomEvent = events.find((event) =>
    clean(event.room_id) && clean(event.match_id) &&
    ["game_started", "game_finished"].includes(clean(event.event_type))
  );
  if (roomEvent) {
    await syncLiveActivities(base44, {
      room_id: roomEvent.room_id,
      match_id: roomEvent.match_id,
      deadline_epoch_ms: deadlineEpochMs,
    });
  }
  const results: Entity[] = [];
  const eventWork = await runBounded({
    items: events.slice(0, 24),
    concurrency: 6,
    deadlineEpochMs,
    worker: async (event) => {
      try {
        results.push(await processOneEvent(base44, event));
      } catch {
        // Exact worker leases recover through a later trusted drain.
      }
    },
  });
  return {
    ok: true,
    processed: results.length,
    deferred: eventWork.unstarted.length,
    results,
  };
}

async function drain(base44: any, body: Entity): Promise<Entity> {
  const deadlineEpochMs = Date.now() + DRAIN_BUDGET_MS;
  const limit = Math.min(12, Math.max(1, Number(body.limit || 8)));
  const repairedEvents = await reconcileRecentRoomOutboxes(
    base44,
    Math.min(deadlineEpochMs, Date.now() + 10_000),
  );
  const liveResults = await drainLiveActivityRetries(
    base44,
    Math.min(6, limit),
    Math.min(deadlineEpochMs, Date.now() + 20_000),
  );
  const reconciledLiveResults = await reconcileIdleLiveActivityDrift(
    base44,
    Math.min(6, limit),
    Math.min(deadlineEpochMs, Date.now() + 20_000),
  );
  const candidates: Entity[] = [];
  for (const state of ["pending", "retry", "processing"]) {
    candidates.push(
      ...await base44.asServiceRole.entities.PushNotificationEvent.filter(
        { state },
        state === "retry"
          ? "next_attempt_at"
          : state === "processing"
          ? "lease_until"
          : "created_at",
        24,
        0,
      ) || [],
    );
  }
  const now = Date.now();
  const due = candidates.filter((event) => {
    if (clean(event.state) === "pending") return true;
    if (clean(event.state) === "retry") {
      const nextAttempt = Date.parse(clean(event.next_attempt_at));
      return !Number.isFinite(nextAttempt) || nextAttempt <= now;
    }
    const leaseUntil = Date.parse(clean(event.lease_until));
    return !Number.isFinite(leaseUntil) || leaseUntil <= now;
  });
  due.sort((left, right) =>
    Date.parse(clean(left.created_at)) - Date.parse(clean(right.created_at))
  );
  const batch = due.slice(0, Math.min(8, limit));
  const gameEvents = new Map<string, Entity>();
  for (const event of batch) {
    if (
      ["game_started", "game_finished"].includes(clean(event.event_type)) &&
      clean(event.room_id) && clean(event.match_id)
    ) {
      gameEvents.set(`${clean(event.room_id)}:${clean(event.match_id)}`, event);
    }
  }
  const syncedGameKeys = new Set<string>();
  await runBounded({
    items: [...gameEvents.entries()].slice(0, 2),
    concurrency: 2,
    deadlineEpochMs,
    worker: async ([key, event]) => {
      try {
        await syncLiveActivities(base44, {
          room_id: event.room_id,
          match_id: event.match_id,
          deadline_epoch_ms: deadlineEpochMs,
        });
        syncedGameKeys.add(key);
      } catch {
        // Do not terminalize its ordinary row until ActivityKit was attempted.
      }
    },
  });
  const eligibleEvents = batch.filter((event) => {
    if (!["game_started", "game_finished"].includes(clean(event.event_type))) {
      return true;
    }
    return syncedGameKeys.has(
      `${clean(event.room_id)}:${clean(event.match_id)}`,
    );
  });
  const results: Entity[] = [];
  const ordinaryWork = await runBounded({
    items: eligibleEvents,
    concurrency: 4,
    deadlineEpochMs,
    worker: async (event) => {
      try {
        results.push(await processOneEvent(base44, event));
      } catch {
        // Claimed rows recover after their exact lease expires.
      }
    },
  });
  return {
    ok: true,
    processed: results.length + liveResults.length +
      reconciledLiveResults.length,
    deferred: Math.max(0, due.length - results.length),
    ordinary_unstarted: ordinaryWork.unstarted.length,
    results,
    live_activity_results: liveResults,
    live_activity_reconciliations: reconciledLiveResults,
    repaired_events: repairedEvents,
  };
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return Response.json({ error: "Method not allowed" }, { status: 405 });
    }
    const body = await req.json().catch(() => ({}));
    const automationArgs = scheduledDrainArgs(body);
    const action = clean(body.action || automationArgs?.action).toLowerCase();
    const base44 = createClientFromRequest(req);

    if (
      [
        "process_event",
        "drain",
        "sync_live_activity",
        "end_room_live_activities",
      ].includes(action)
    ) {
      if (action === "drain" && !internalRequest(body)) {
        const automationUser = await base44.auth.me().catch(() => null);
        if (!isAdminAutomationUser(automationUser)) {
          return Response.json({ error: "Unauthorized" }, { status: 401 });
        }
        // Base44 may expose function_args as body.args for scheduled runs;
        // dashboard/manual admin execution can provide the same fields at the
        // top level. Both are safe because auth.me() is the automation creator
        // or current admin, never a caller-selected identity.
        return Response.json(await drain(base44, automationArgs || body));
      }
      if (!internalRequest(body)) {
        return Response.json({ error: "Unauthorized" }, { status: 401 });
      }
      if (action === "process_event") {
        return Response.json(await processEvents(base44, body));
      }
      if (action === "sync_live_activity") {
        return Response.json(await syncLiveActivities(base44, body));
      }
      if (action === "end_room_live_activities") {
        return Response.json(await endRoomLiveActivities(base44, body));
      }
      return Response.json(await drain(base44, body));
    }

    const user = await authenticatedUser(req, body);
    const lifecycleStore =
      base44.asServiceRole.entities.BillingIdentityLifecycle;
    const deviceStore = base44.asServiceRole.entities.PushDeviceRegistration;
    const liveActivityStore =
      base44.asServiceRole.entities.LiveActivityRegistration;

    if (action === "register_device") {
      const tokenHash = await digest(
        normalizeAPNSToken(body.apns_token),
        "apns-token",
      );
      const ownerIDs = await deviceTokenOwnerIDs(deviceStore, tokenHash);
      const leasedUserIDs = [...new Set([clean(user.id), ...ownerIDs])].sort();
      const saved = await withPushWriterLeases({
        lifecycleStore,
        userIDs: leasedUserIDs,
        action: async (persist) =>
          await registerDevice({
            deviceStore,
            userID: clean(user.id),
            body,
            persist,
            leasedUserIDs,
          }),
      });
      return Response.json({
        ok: true,
        registration_id: saved.id,
        updated_at: saved.updated_at,
      });
    }
    if (action === "register_live_activity_token") {
      const tokenHash = await digest(
        normalizeAPNSToken(body.live_activity_token),
        "live-activity-token",
      );
      const ownerIDs = await deviceTokenOwnerIDs(liveActivityStore, tokenHash);
      const leasedUserIDs = [...new Set([clean(user.id), ...ownerIDs])].sort();
      const saved = await withPushWriterLeases({
        lifecycleStore,
        userIDs: leasedUserIDs,
        action: async (persist) =>
          await registerLiveActivity({
            liveActivityStore,
            roomStore: base44.asServiceRole.entities.GameRoom,
            userID: clean(user.id),
            body,
            persist,
            leasedUserIDs,
          }),
      });
      return Response.json({
        ok: true,
        registration_id: saved.id,
        updated_at: saved.updated_at,
      });
    }
    if (action === "unregister_device") {
      await withPushWriterLeases({
        lifecycleStore,
        userIDs: [user.id],
        action: async (persist) =>
          await unregisterInstallation({
            deviceStore,
            liveActivityStore,
            userID: clean(user.id),
            installationID: body.installation_id,
            persist,
          }),
      });
      return Response.json({ ok: true });
    }
    if (action === "unregister_live_activity_token") {
      await withPushWriterLeases({
        lifecycleStore,
        userIDs: [user.id],
        action: async (persist) =>
          await unregisterLiveActivity({
            liveActivityStore,
            userID: clean(user.id),
            body,
            persist,
          }),
      });
      return Response.json({ ok: true });
    }
    throw new PushContractError(
      "Unsupported push action.",
      400,
      "unsupported_action",
    );
  } catch (error) {
    return errorResponse(error);
  }
});
