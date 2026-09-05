import { createClient, createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import {
  clean,
  constantTimeEqual,
  normalizeAPNSToken,
  PushContractError,
} from "./contracts.ts";
import {
  committedGameFinishReceipt,
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
import {
  clampDeadline,
  runBounded,
  runWithinDeadline,
} from "./bounded-work.ts";
import {
  sendLiveActivityTermination,
  sendLiveActivityUpdate,
} from "./live-activity.ts";
import {
  claimLiveDelivery,
  completeLiveDelivery,
  forcedLiveEndFailurePatch,
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
import { drainAnnouncementFanout } from "./announcement-fanout.ts";
import {
  normalizePushDrainLimit,
  PUSH_DRAIN_CONCURRENCY,
  pushDrainQueryLimit,
} from "./drain-policy.ts";
import {
  committedPersonalInboxPatch,
  isPersonalInboxEvent,
} from "./inbox-projection.ts";
import { backfillLegacyInboxProjections } from "./inbox-backfill.ts";
import { canonicalBase44Request } from "./base44-context.ts";
import { pushErrorResponse } from "./error-response.ts";
import { finishedProfileRepairAlreadyCompleted } from "./profile-repair-state.ts";
import { createProcessEventTiming } from "./process-event-timing.ts";
import { safePushErrorDetails } from "./safe-error.ts";
import {
  internalFunctionBody,
  profileRepairDrainSummary,
} from "./internal-function-response.ts";
import {
  enqueueRoomLiveActivityEnd,
  type RoomLiveActivityEndQueue,
} from "./live-end-enqueue.ts";
import { deliverQueuedRoomLiveActivityEnd } from "./queued-live-end-delivery.ts";
import {
  authorizeForcedLiveActivityEnd,
  committedRoomCloseReceipt,
  roomCloseCommitReceiptID,
} from "./forced-live-end-authorization.ts";
import { withBillingLifecycleContentionRetry } from "./billing-lifecycle-retry.ts";
import {
  advanceRoomReconciliationCheckpoint,
  cursorAfterAttemptedRoomPage,
  ensureRoomReconciliationCheckpoint,
  loadRoomReconciliationPage,
  type ReconciledRoomStatus,
  type RoomReconciliationCheckpoint,
  selectScheduledRoomReconciliationRooms,
} from "./scheduled-room-reconciliation.ts";

type Entity = Record<string, any>;
const PAGE_SIZE = 100;
const SPYCLASH_BASE44_APP_ID = "69a0e57fa939f578082f8091";
const LIVE_SYNC_BUDGET_MS = 25_000;
const DRAIN_BUDGET_MS = 55_000;

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

function pendingTerminalIntentScope(room: Entity): Entity | null {
  const intent = room?.terminal_intent;
  const matchID = clean(room?.match_id);
  const decidedAt = clean(intent?.decided_at);
  if (
    clean(room?.status).toLowerCase() === "finished" || !matchID ||
    clean(intent?.match_id) !== matchID ||
    !["spy", "detectives"].includes(clean(intent?.winner)) ||
    !decidedAt || !Number.isFinite(Date.parse(decidedAt))
  ) return null;
  return { matchID, decidedAt };
}

async function reconcilePendingTerminalRoom(
  base44: any,
  room: Entity,
): Promise<Entity> {
  const scope = pendingTerminalIntentScope(room);
  if (!scope) return room;
  const internalSecret = clean(Deno.env.get("PUSH_INTERNAL_SECRET"));
  if (internalSecret.length < 32) return room;
  try {
    await runWithinDeadline({
      deadlineEpochMs: Date.now() + 500,
      operation: () =>
        base44.asServiceRole.functions.invoke("gameRoomAction", {
          action: "reconcile_terminal_intent",
          room_id: clean(room.id),
          expected_match_id: scope.matchID,
          expected_decided_at: scope.decidedAt,
          internal_secret: internalSecret,
        }),
    });
    return (await allMatching(base44.asServiceRole.entities.GameRoom, {
      id: clean(room.id),
    }))[0] || room;
  } catch (error) {
    const details = safePushErrorDetails(error);
    console.error(
      "terminal intent reconciliation deferred",
      details.message,
      details.status || 500,
    );
    return room;
  }
}

async function repairFinishedRoomCommunityProfiles(
  base44: any,
  room: Entity,
): Promise<boolean> {
  if (finishedProfileRepairAlreadyCompleted(room)) return true;

  const internalSecret = clean(Deno.env.get("PUSH_INTERNAL_SECRET"));
  if (
    internalSecret.length < 32 || clean(room?.status).toLowerCase() !==
      "finished" ||
    !clean(room?.game_finished_event_id)
  ) return false;
  try {
    const response = await base44.asServiceRole.functions.invoke(
      "gameRoomAction",
      {
        action: "repair_finished_profile_side_effects",
        room_id: clean(room.id),
        source_event_id: clean(room.game_finished_event_id),
        internal_secret: internalSecret,
      },
    );
    return ["performed", "completed", "deferred"].includes(
      clean(internalFunctionBody(response).outcome),
    );
  } catch (error) {
    // Profile repair is a separate durable room outcome. It must never make
    // APNs/outbox delivery fail, but a scheduled pass will keep retrying it.
    const details = safePushErrorDetails(error);
    console.error(
      "finished room community profile repair deferred",
      details.message,
      details.status || 500,
    );
    return false;
  }
}

async function drainDurableCommunityProfileRepairs(
  base44: any,
  limit: number,
  deadlineEpochMs: number,
): Promise<Entity> {
  const internalSecret = clean(Deno.env.get("PUSH_INTERNAL_SECRET"));
  if (internalSecret.length < 32) {
    return { ok: false, selected: 0, deferred: 0, reason: "secret_missing" };
  }
  try {
    const bounded = await runWithinDeadline({
      deadlineEpochMs,
      operation: () =>
        base44.asServiceRole.functions.invoke("gameRoomAction", {
          action: "drain_community_profile_repairs",
          internal_secret: internalSecret,
          limit: Math.min(Math.max(Math.floor(limit) || 1, 1), 24),
        }),
    });
    if (bounded.timedOut) {
      return {
        ok: false,
        selected: 0,
        deferred: 1,
        reason: "deadline_exceeded",
      };
    }
    return profileRepairDrainSummary(bounded.value);
  } catch (error) {
    // GameHistory, not an ephemeral finished room, remains the durable source.
    // APNs/outbox work below proceeds independently and a later drain retries.
    const details = safePushErrorDetails(error);
    console.error(
      "durable community profile repair drain deferred",
      details.message,
      details.status || 500,
    );
    return { ok: false, selected: 0, deferred: 1 };
  }
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
  const roomStore = base44.asServiceRole.entities.GameRoom;
  const checkpointStore =
    base44.asServiceRole.entities.NotificationAnnouncement;
  const loadCheckpoint = async (
    status: ReconciledRoomStatus,
  ): Promise<RoomReconciliationCheckpoint | null> => {
    try {
      return await ensureRoomReconciliationCheckpoint({
        store: checkpointStore,
        status,
      });
    } catch (error) {
      // The newest head and the first keyset page still run if checkpoint
      // persistence is temporarily unavailable. No room state is mutated by
      // the checkpoint itself.
      const details = safePushErrorDetails(error);
      console.error(
        "room reconciliation checkpoint deferred",
        status,
        details.message,
        details.status || 500,
      );
      return null;
    }
  };
  const [finishedCheckpoint, playingCheckpoint] = await Promise.all([
    loadCheckpoint("finished"),
    loadCheckpoint("playing"),
  ]);
  const [finishedPage, playingPage, finishedNewest, playingNewest] =
    await Promise.all([
      loadRoomReconciliationPage({
        roomStore,
        status: "finished",
        cursor: finishedCheckpoint?.cursor || "",
        limit: 6,
      }),
      loadRoomReconciliationPage({
        roomStore,
        status: "playing",
        cursor: playingCheckpoint?.cursor || "",
        limit: 3,
      }),
      roomStore.filter(
        { status: "finished" },
        "-updated_date",
        2,
        0,
      ),
      roomStore.filter(
        { status: "playing" },
        "-updated_date",
        1,
        0,
      ),
    ]);
  const candidates = selectScheduledRoomReconciliationRooms({
    finishedNewest: finishedNewest || [],
    finishedCursorPage: finishedPage.rooms,
    playingNewest: playingNewest || [],
    playingCursorPage: playingPage.rooms,
  });
  const attemptedCursorRoomIDs: Record<
    ReconciledRoomStatus,
    Set<string>
  > = {
    finished: new Set<string>(),
    playing: new Set<string>(),
  };
  let created = 0;
  await runBounded({
    items: candidates,
    concurrency: 3,
    deadlineEpochMs,
    worker: async (candidate) => {
      const roomID = clean(candidate.room?.id);
      try {
        const room = await reconcilePendingTerminalRoom(
          base44,
          candidate.room,
        );
        try {
          created += await repairRoomPushOutbox(base44, room);
        } catch {
          // The committed room identity remains a durable repair source for
          // the next cursor wrap or any later process_event call.
        }
      } finally {
        if (candidate.source === "cursor" && roomID) {
          attemptedCursorRoomIDs[candidate.status].add(roomID);
        }
      }
    },
  });
  const nextFinishedCursor = cursorAfterAttemptedRoomPage({
    previousCursor: finishedCheckpoint?.cursor || "",
    page: finishedPage.rooms,
    attemptedRoomIDs: attemptedCursorRoomIDs.finished,
  });
  const nextPlayingCursor = cursorAfterAttemptedRoomPage({
    previousCursor: playingCheckpoint?.cursor || "",
    page: playingPage.rooms,
    attemptedRoomIDs: attemptedCursorRoomIDs.playing,
  });
  const checkpointAdvances: Promise<unknown>[] = [];
  if (
    finishedCheckpoint && nextFinishedCursor !== finishedCheckpoint.cursor
  ) {
    checkpointAdvances.push(
      advanceRoomReconciliationCheckpoint({
        store: checkpointStore,
        status: "finished",
        checkpoint: finishedCheckpoint,
        cursor: nextFinishedCursor,
      }),
    );
  }
  if (playingCheckpoint && nextPlayingCursor !== playingCheckpoint.cursor) {
    checkpointAdvances.push(
      advanceRoomReconciliationCheckpoint({
        store: checkpointStore,
        status: "playing",
        checkpoint: playingCheckpoint,
        cursor: nextPlayingCursor,
      }),
    );
  }
  await Promise.all(checkpointAdvances).catch((error) => {
    // A stale checkpoint only repeats an idempotent page. It must not undo the
    // terminal/outbox repairs that already completed above.
    const details = safePushErrorDetails(error);
    console.error(
      "room reconciliation cursor advance deferred",
      details.message,
      details.status || 500,
    );
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
          pending_force_end: false,
          pending_force_end_commit_id: null,
          terminal_probe_started_at: null,
          terminal_probe_until: null,
          pending_room_id: null,
          pending_match_id: null,
          pending_room_revision: 0,
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
        if (isPersonalInboxEvent(claimed)) {
          const inboxPatch = committedPersonalInboxPatch(
            claimed,
            stableSource,
            now,
          );
          const inboxCommit: Entity = await persist(() =>
            store.updateMany({
              id: claimed.id,
              state: "processing",
              lease_token: claimed.lease_token,
              revision: claimed.revision,
            }, { $set: inboxPatch })
          );
          if (Number(inboxCommit?.updated) !== 1) {
            throw new PushContractError(
              "Inbox projection commit raced with delivery.",
              409,
              "inbox_commit_contention",
            );
          }
          Object.assign(claimed, inboxPatch);
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

type TerminalRegistrationProof =
  | { state: "terminal"; commitID: string }
  | { state: "pending_terminal"; room: Entity }
  | { state: "active"; updatedAtMS: number }
  | { state: "uncertain" };

async function terminalRegistrationProof(
  base44: any,
  registration: Entity,
): Promise<TerminalRegistrationProof> {
  const userID = clean(registration.user_id);
  const roomID = clean(registration.room_id);
  const matchID = clean(registration.match_id);
  const [rooms, finishCommitID, closeCommitID] = await Promise.all([
    allMatching(base44.asServiceRole.entities.GameRoom, { id: roomID }),
    committedGameFinishReceipt({
      eventStore: base44.asServiceRole.entities.PushNotificationEvent,
      userID,
      roomID,
      matchID,
    }),
    committedRoomCloseReceipt({
      signalStore: base44.asServiceRole.entities.GameRoomSignal,
      userID,
      roomID,
      matchID,
    }),
  ]);
  if (finishCommitID) return { state: "terminal", commitID: finishCommitID };
  if (closeCommitID) return { state: "terminal", commitID: closeCommitID };

  const room = rooms.find((candidate) => clean(candidate.id) === roomID);
  if (!room) return { state: "uncertain" };
  if (clean(room.match_id) !== matchID) {
    // A previous-match replica can race the first token for a newly active
    // generation. Match mismatch alone is never a terminal authorization.
    return { state: "uncertain" };
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
  if (!participantIDs.has(userID)) {
    return { state: "uncertain" };
  }
  const status = clean(room.status).toLowerCase();
  if (["finished", "ended", "closed"].includes(status)) {
    const exactFinishID = `game-finished:${matchID}`;
    return clean(room.game_finished_event_id) === exactFinishID
      ? { state: "terminal", commitID: exactFinishID }
      : { state: "uncertain" };
  }
  const intent = room.close_intent;
  if (
    clean(intent?.id) && clean(intent?.room_id) === roomID &&
    clean(intent?.match_id) === matchID
  ) {
    return {
      state: "terminal",
      commitID: roomCloseCommitReceiptID(matchID, intent.id),
    };
  }
  if (clean(room?.terminal_intent?.match_id) === matchID) {
    // The terminal decision is durable, but the exact finished outbox receipt
    // may still be committing. Never reinterpret this snapshot as a later
    // active generation merely because updated_date advanced.
    return { state: "pending_terminal", room };
  }
  const updatedAtMS = Date.parse(clean(room.updated_date));
  return {
    state: "active",
    updatedAtMS: Number.isFinite(updatedAtMS) ? updatedAtMS : 0,
  };
}

async function terminalProbeRegistration(
  liveStore: any,
  registrationID: string,
  probeRevision: string,
): Promise<Entity | null> {
  const registration = (await allMatching(liveStore, {
    id: registrationID,
  }))[0];
  if (
    !registration || clean(registration.status) !== "active" ||
    clean(registration.token_kind) !== "activity" ||
    clean(registration.delivery_revision) !== probeRevision ||
    !clean(registration.terminal_probe_started_at) ||
    !clean(registration.terminal_probe_until)
  ) return null;
  return registration;
}

async function resolveTerminalRegistrationProbe(input: {
  base44: any;
  registration: Entity;
  proof: TerminalRegistrationProof;
}): Promise<{ outcome: string; registration: Entity | null }> {
  const liveStore =
    input.base44.asServiceRole.entities.LiveActivityRegistration;
  const registrationID = clean(input.registration.id);
  const probeRevision = clean(input.registration.delivery_revision);
  const userID = clean(input.registration.user_id);
  const roomID = clean(input.registration.room_id);
  const matchID = clean(input.registration.match_id);
  const startedAtMS = Date.parse(
    clean(input.registration.terminal_probe_started_at),
  );
  const now = new Date();
  let proof = input.proof;
  let outcome = "changed";
  let resolved: Entity | null = null;

  await withPushWriterLeases({
    lifecycleStore:
      input.base44.asServiceRole.entities.BillingIdentityLifecycle,
    userIDs: [userID],
    action: async (persist) => {
      const current = await terminalProbeRegistration(
        liveStore,
        registrationID,
        probeRevision,
      );
      if (!current) return;
      if (proof.state !== "terminal") {
        // Negative/active evidence read before waiting for this lifecycle
        // lease can become stale if finish/close commits while we are blocked.
        // Re-read all marker-first sources under the lease before any clear.
        proof = await terminalRegistrationProof(input.base44, current);
      }
      if (proof.state === "terminal") {
        const terminalProof = proof;
        const queued = await persist(() =>
          queueLiveRetry({
            store: liveStore,
            registrationID,
            roomID,
            matchID,
            roomRevision: Math.max(
              0,
              Number(current.pending_room_revision || 0),
            ),
            forceEnd: true,
            terminalCommitID: terminalProof.commitID,
            now,
          })
        );
        if (!queued) return;
        const queuedRow = (await allMatching(liveStore, {
          id: registrationID,
        }))[0];
        if (!queuedRow) return;
        await persist(() =>
          liveStore.updateMany({
            id: registrationID,
            delivery_revision: queuedRow.delivery_revision,
            terminal_probe_started_at: current.terminal_probe_started_at,
          }, {
            $set: {
              terminal_probe_started_at: null,
              terminal_probe_until: null,
              last_error_code: "terminal_probe_committed",
              updated_at: now.toISOString(),
            },
          })
        );
        resolved = (await allMatching(liveStore, { id: registrationID }))[0] ||
          null;
        outcome = "terminal";
        return;
      }

      const probeUntilMS = Date.parse(clean(current.terminal_probe_until));
      const provesBoundedActiveCommit = proof.state === "active" &&
        Number.isFinite(startedAtMS) &&
        Number.isFinite(probeUntilMS) && probeUntilMS <= now.getTime() &&
        proof.updatedAtMS > 0;
      const patch = provesBoundedActiveCommit
        ? {
          // The marker-first probation window elapsed while the exact room,
          // match and membership remained active. Clear probation, but keep a
          // due scoped projection so the newly accepted token immediately
          // catches up instead of waiting for a later room mutation.
          delivery_state: "retry",
          delivery_revision: crypto.randomUUID(),
          delivery_lease_until: now.toISOString(),
          delivery_attempt_count: 0,
          retry_requested: true,
          next_attempt_at: now.toISOString(),
          pending_room_id: roomID,
          pending_match_id: matchID,
          pending_room_revision: proof.state === "active"
            ? proof.updatedAtMS
            : 0,
          pending_force_end: false,
          pending_force_end_commit_id: null,
          terminal_probe_started_at: null,
          terminal_probe_until: null,
          last_error_code: "terminal_probe_active_commit",
          updated_at: now.toISOString(),
        }
        : {
          delivery_state: "retry",
          delivery_revision: crypto.randomUUID(),
          delivery_lease_until: now.toISOString(),
          retry_requested: false,
          next_attempt_at: new Date(now.getTime() + 30_000).toISOString(),
          last_error_code: "terminal_probe_unresolved",
          updated_at: now.toISOString(),
        };
      const result = await persist(() =>
        liveStore.updateMany({
          id: registrationID,
          delivery_revision: probeRevision,
          terminal_probe_started_at: current.terminal_probe_started_at,
          terminal_probe_until: current.terminal_probe_until,
        }, { $set: patch })
      ) as Entity;
      if (Number(result?.updated) !== 1) return;
      outcome = provesBoundedActiveCommit ? "active" : "deferred";
      resolved = (await allMatching(liveStore, { id: registrationID }))[0] ||
        null;
    },
  });
  return { outcome, registration: resolved };
}

async function probeLiveActivityTerminal(
  base44: any,
  body: Entity,
): Promise<Entity> {
  const registrationID = clean(body.registration_id);
  const probeRevision = clean(body.probe_revision);
  if (!registrationID || !probeRevision) {
    throw new PushContractError("Terminal probe identity is required.");
  }
  const operationDeadline = clampDeadline(body.deadline_epoch_ms, 30_000);
  const backoffMS = [100, 200, 400, 800, 1_500, 3_000, 5_000] as const;
  let retryIndex = 0;
  let terminalRecoveryPrompted = false;

  for (;;) {
    const registration = await terminalProbeRegistration(
      base44.asServiceRole.entities.LiveActivityRegistration,
      registrationID,
      probeRevision,
    );
    if (!registration) return { ok: true, outcome: "changed" };
    const proof = await terminalRegistrationProof(base44, registration);
    if (proof.state === "pending_terminal" && !terminalRecoveryPrompted) {
      terminalRecoveryPrompted = true;
      await reconcilePendingTerminalRoom(base44, proof.room);
      continue;
    }
    if (proof.state === "terminal") {
      const resolved = await resolveTerminalRegistrationProbe({
        base44,
        registration,
        proof,
      });
      const forcedEnd = resolved.registration
        ? await deliverForcedLiveActivityEnd({
          base44,
          registration: resolved.registration,
          roomID: clean(resolved.registration.pending_room_id),
          matchID: clean(resolved.registration.pending_match_id),
          roomRevision: Math.max(
            0,
            Number(resolved.registration.pending_room_revision || 0),
          ),
          queuedPendingOnly: true,
        })
        : "skipped";
      return { ok: true, outcome: resolved.outcome, forced_end: forcedEnd };
    }

    const now = Date.now();
    const probeUntil = Date.parse(clean(registration.terminal_probe_until));
    if (Number.isFinite(probeUntil) && now >= probeUntil) {
      const resolved = await resolveTerminalRegistrationProbe({
        base44,
        registration,
        proof,
      });
      if (resolved.outcome === "active" && resolved.registration) {
        const catchUp = await syncLiveActivities(base44, {
          room_id: clean(resolved.registration.pending_room_id),
          match_id: clean(resolved.registration.pending_match_id),
          registration_id: clean(resolved.registration.id),
          deadline_epoch_ms: operationDeadline,
        });
        return { ok: true, outcome: resolved.outcome, catch_up: catchUp };
      }
      return { ok: true, outcome: resolved.outcome };
    }
    if (now >= operationDeadline) {
      return { ok: true, outcome: "deferred" };
    }
    const requested = backoffMS[Math.min(retryIndex, backoffMS.length - 1)];
    retryIndex += 1;
    const remaining = Math.min(
      operationDeadline - now,
      Number.isFinite(probeUntil) ? probeUntil - now : requested,
    );
    if (remaining <= 0) continue;
    await new Promise<void>((resolve) =>
      setTimeout(resolve, Math.max(1, Math.min(requested, remaining)))
    );
  }
}

async function triggerLiveActivityTerminalProbe(
  base44: any,
  registration: Entity,
): Promise<boolean> {
  const registrationID = clean(registration?.id);
  const probeRevision = clean(registration?.delivery_revision);
  const probeUntil = Date.parse(clean(registration?.terminal_probe_until));
  const internalSecret = clean(Deno.env.get("PUSH_INTERNAL_SECRET"));
  if (
    !registrationID || !probeRevision || !Number.isFinite(probeUntil) ||
    internalSecret.length < 32
  ) return false;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const promptDeadline = Date.now() + 300;
      // A timeout means invoke already started and is safe: the durable probe
      // revision makes duplicate workers idempotent. Only an explicit invoke
      // rejection needs another prompt attempt.
      await runWithinDeadline({
        deadlineEpochMs: promptDeadline,
        operation: () =>
          base44.asServiceRole.functions.invoke("pushNotificationAction", {
            action: "probe_live_activity_terminal",
            registration_id: registrationID,
            probe_revision: probeRevision,
            deadline_epoch_ms: probeUntil,
            internal_secret: internalSecret,
          }),
      });
      return true;
    } catch (error) {
      const details = safePushErrorDetails(error);
      console.warn(
        "live activity terminal probe prompt deferred",
        details.message,
        details.status || 500,
      );
      if (attempt < 2) {
        await new Promise<void>((resolve) => setTimeout(resolve, 50));
      }
    }
  }
  return false;
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
        const exactActivityBinding = clean(registration.status) === "active" &&
          clean(registration.token_kind) === "activity" &&
          clean(registration.room_id) === roomID &&
          clean(registration.match_id) === matchID &&
          clean(registration.provider_match_id) === matchID;
        const [finishCommitID, closeCommitID] = exactActivityBinding
          ? await Promise.all([
            committedGameFinishReceipt({
              eventStore: base44.asServiceRole.entities.PushNotificationEvent,
              userID: clean(registration.user_id),
              roomID,
              matchID,
            }),
            committedRoomCloseReceipt({
              signalStore: base44.asServiceRole.entities.GameRoomSignal,
              userID: registration.user_id,
              roomID,
              matchID,
            }),
          ])
          : ["", ""];
        const terminalCommitID = finishCommitID || closeCommitID;
        if (terminalCommitID) {
          let queued = false;
          await withPushWriterLeases({
            lifecycleStore:
              base44.asServiceRole.entities.BillingIdentityLifecycle,
            userIDs: [clean(registration.user_id)],
            action: async (persist) => {
              const current = (await allMatching(liveStore, {
                id: clean(registration.id),
              }))[0];
              if (
                !current || clean(current.status) !== "active" ||
                clean(current.token_kind) !== "activity" ||
                clean(current.user_id) !== clean(registration.user_id) ||
                clean(current.room_id) !== roomID ||
                clean(current.match_id) !== matchID ||
                clean(current.provider_match_id) !== matchID
              ) return;
              queued = await persist(() =>
                queueLiveRetry({
                  store: liveStore,
                  registrationID: clean(current.id),
                  roomID,
                  matchID,
                  roomRevision: Math.max(
                    0,
                    Number(current.pending_room_revision || 0),
                  ),
                  forceEnd: true,
                  terminalCommitID,
                })
              );
            },
          });
          const queuedRegistration = queued
            ? (await allMatching(liveStore, {
              id: clean(registration.id),
            }))[0] || null
            : null;
          const forcedEnd = queuedRegistration
            ? await deliverForcedLiveActivityEnd({
              base44,
              registration: queuedRegistration,
              roomID,
              matchID,
              roomRevision: Math.max(
                0,
                Number(queuedRegistration.pending_room_revision || 0),
              ),
              queuedPendingOnly: true,
            })
            : "skipped";
          return {
            ok: true,
            delivered: forcedEnd === "delivered" ? 1 : 0,
            skipped: forcedEnd === "skipped" ? 1 : 0,
            failed: forcedEnd === "failed" ? 1 : 0,
            stale: true,
            closing: true,
          };
        }
        // A prepared forced end plus one missing-room/signal read is
        // ambiguous under replica lag. Its durable row must survive for the
        // next reconciliation instead of being terminalized as stale.
        if (registration.pending_force_end === true) {
          return {
            ok: true,
            delivered: 0,
            skipped: 1,
            failed: 0,
            stale: true,
            deferred: true,
          };
        }
        if (exactActivityBinding) {
          try {
            await withPushWriterLeases({
              lifecycleStore:
                base44.asServiceRole.entities.BillingIdentityLifecycle,
              userIDs: [clean(registration.user_id)],
              action: async (persist) => {
                const current = (await allMatching(liveStore, {
                  id: clean(registration.id),
                }))[0];
                if (
                  !current || clean(current.status) !== "active" ||
                  clean(current.token_kind) !== "activity" ||
                  clean(current.room_id) !== roomID ||
                  clean(current.match_id) !== matchID ||
                  clean(current.provider_match_id) !== matchID
                ) return;
                await persist(() =>
                  queueLiveRetry({
                    store: liveStore,
                    registrationID: clean(current.id),
                    roomID,
                    matchID,
                    roomRevision: Math.max(
                      0,
                      Number(current.pending_room_revision || 0),
                    ),
                  })
                );
              },
            });
          } catch {
            // Account deletion or a concurrent registration update owns the row.
          }
          return {
            ok: true,
            delivered: 0,
            skipped: 1,
            failed: 0,
            stale: true,
            deferred: true,
          };
        }
      }
    }
    return { ok: true, delivered: 0, skipped: 0, failed: 0, stale: true };
  }
  if (room.close_intent) {
    // close_intent is the logical terminal commit. Reconciliation must own the
    // durable forced-end queue as well: the original game action may have
    // crashed after committing participant tombstones but before its
    // post-lease enqueue phase. The idle sweep therefore repairs the exact
    // close marker instead of permanently returning `closing`.
    const intent = room.close_intent;
    const exactIntent = clean(intent?.id) &&
      clean(intent?.room_id) === roomID &&
      clean(intent?.match_id) === matchID;
    if (exactIntent) {
      const repaired = await endRoomLiveActivities(base44, {
        room_id: roomID,
        match_id: matchID,
        terminal_commit_id: roomCloseCommitReceiptID(matchID, intent.id),
        deadline_epoch_ms: deadlineEpochMs,
      }, room);
      return { ...repaired, stale: true, closing: true, reconciled: true };
    }
    return {
      ok: true,
      delivered: 0,
      skipped: 0,
      failed: 0,
      stale: true,
      closing: true,
      deferred: true,
    };
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
  if (clean(room.status) !== "finished" && !room.close_intent) {
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
      let pendingForcedEnd: Entity | null = null;
      let pendingTerminalProbe: Entity | null = null;
      let outcome = await withPushWriterLeases({
        lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
        userIDs: [clean(registration.user_id)],
        action: async (persist) => {
          await persist(async () => undefined);
          const currentRows = await allMatching(liveStore, {
            id: clean(registration.id),
          });
          const current = currentRows[0];
          if (!current || clean(current.status) !== "active") return "skipped";
          if (
            clean(current.token_kind) === "activity" &&
            clean(current.terminal_probe_started_at) &&
            clean(current.terminal_probe_until)
          ) {
            pendingTerminalProbe = current;
            return "terminal_probe_pending";
          }
          if (
            clean(current.token_kind) === "activity" &&
            current.pending_force_end === true &&
            clean(current.pending_room_id) &&
            clean(current.pending_match_id)
          ) {
            // Never claim a committed terminal intent as an ordinary room
            // projection. Release this lease, then let the forced-end path own
            // a fresh lease and its terminal retry/cleanup semantics.
            pendingForcedEnd = current;
            return "force_end_pending";
          }
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
          const isActivity = clean(claimed.token_kind) === "activity";
          const exactActivityBinding = isActivity &&
            clean(claimed.room_id) === roomID &&
            clean(claimed.match_id) === matchID &&
            clean(claimed.provider_match_id) === matchID;
          let terminalCommitID = "";
          if (exactActivityBinding) {
            const [finishCommitID, closeCommitID] = await Promise.all([
              committedGameFinishReceipt({
                eventStore: base44.asServiceRole.entities.PushNotificationEvent,
                userID: clean(claimed.user_id),
                roomID,
                matchID,
              }),
              committedRoomCloseReceipt({
                signalStore: base44.asServiceRole.entities.GameRoomSignal,
                userID: clean(claimed.user_id),
                roomID,
                matchID,
              }),
            ]);
            terminalCommitID = finishCommitID || closeCommitID;
            if (
              !terminalCommitID && latestRoom &&
              clean(latestRoom.match_id) === matchID
            ) {
              const intent = latestRoom.close_intent;
              if (
                clean(intent?.id) && clean(intent?.room_id) === roomID &&
                clean(intent?.match_id) === matchID
              ) {
                terminalCommitID = roomCloseCommitReceiptID(matchID, intent.id);
              } else {
                const exactFinishID = `game-finished:${matchID}`;
                if (
                  clean(latestRoom.game_finished_event_id) === exactFinishID
                ) terminalCommitID = exactFinishID;
              }
            }
          }
          if (terminalCommitID) {
            const nowISO = new Date().toISOString();
            await persist(() =>
              completeLiveDelivery({
                store: liveStore,
                claimed,
                state: "retry",
                nextAttemptAt: nowISO,
                errorCode: "terminal_marker_committed",
                patch: {
                  delivery_attempt_count: 0,
                  retry_requested: true,
                  pending_room_id: roomID,
                  pending_match_id: matchID,
                  pending_room_revision: Math.max(
                    roomRevision,
                    Number(claimed.pending_room_revision || 0),
                  ),
                  pending_force_end: true,
                  pending_force_end_commit_id: terminalCommitID,
                  terminal_probe_started_at: null,
                  terminal_probe_until: null,
                },
              })
            );
            const queued = (await allMatching(liveStore, {
              id: clean(claimed.id),
            }))[0];
            if (queued?.pending_force_end === true) {
              pendingForcedEnd = queued;
              return "force_end_pending";
            }
            return "skipped";
          }
          const latestStatus = clean(latestRoom?.status).toLowerCase();
          const uncommittedTerminalSnapshot = Boolean(
            latestRoom?.close_intent ||
              ["finished", "ended", "closed"].includes(latestStatus),
          );
          if (
            !latestRoom || clean(latestRoom.match_id) !== matchID ||
            (isActivity && !exactActivityBinding) ||
            (isActivity && uncommittedTerminalSnapshot)
          ) {
            const shouldRetry = isActivity;
            await persist(() =>
              completeLiveDelivery({
                store: liveStore,
                claimed,
                state: shouldRetry ? "retry" : "idle",
                nextAttemptAt: shouldRetry
                  ? new Date(Date.now() + 30_000).toISOString()
                  : undefined,
                errorCode: shouldRetry
                  ? "terminal_source_unconfirmed"
                  : "stale_match_binding",
              })
            );
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
      if (outcome === "terminal_probe_pending" && pendingTerminalProbe) {
        const probe = pendingTerminalProbe as Entity;
        const result = await probeLiveActivityTerminal(base44, {
          registration_id: probe.id,
          probe_revision: probe.delivery_revision,
          deadline_epoch_ms: deadlineEpochMs,
        });
        outcome = clean(result?.forced_end) || "skipped";
      } else if (outcome === "force_end_pending" && pendingForcedEnd) {
        const forced = pendingForcedEnd as Entity;
        outcome = await deliverForcedLiveActivityEnd({
          base44,
          registration: forced,
          roomID: clean(forced.pending_room_id),
          matchID: clean(forced.pending_match_id),
          roomRevision: Math.max(
            0,
            Number(forced.pending_room_revision || 0),
          ),
        });
      }
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
    } catch {
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
  queuedPendingOnly?: boolean;
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
      clean(current.token_kind) !== "activity" ||
      clean(current.user_id) !== clean(input.registration.user_id)
    ) return "skipped" as const;
    const exactRoom = clean(current.room_id) === clean(input.roomID) &&
      clean(current.match_id) === clean(input.matchID) &&
      clean(current.provider_match_id) === clean(input.matchID);
    const exactPendingEnd = current.pending_force_end === true &&
      clean(current.pending_room_id) === clean(input.roomID) &&
      clean(current.pending_match_id) === clean(input.matchID);
    if (
      input.queuedPendingOnly
        ? !exactPendingEnd
        : !exactRoom && !exactPendingEnd
    ) return "skipped" as const;
    // The enqueue request makes the first attempt immediately due. Once APNs
    // schedules a retry, repeated close/prompt invocations must respect that
    // backoff instead of burning the terminal attempt budget in a burst.
    if (exactPendingEnd && !liveDeliveryDue(current)) {
      return "skipped" as const;
    }
    const authorization = await authorizeForcedLiveActivityEnd({
      roomStore: input.base44.asServiceRole.entities.GameRoom,
      signalStore: input.base44.asServiceRole.entities.GameRoomSignal,
      liveStore,
      registration: current,
      roomID: input.roomID,
      matchID: input.matchID,
    });
    if (authorization !== "committed") return "skipped" as const;
    const roomRevision = input.queuedPendingOnly
      ? Math.max(0, Number(current.pending_room_revision || 0))
      : input.roomRevision;
    const claimed = await claimLiveDelivery({
      store: liveStore,
      registration: current,
      roomID: input.roomID,
      matchID: input.matchID,
      roomRevision,
      forceEnd: true,
    });
    if (!claimed) return "skipped" as const;
    let result;
    try {
      result = await sendLiveActivityTermination({
        registration: claimed,
        roomID: input.roomID,
        matchID: input.matchID,
        revision: roomRevision,
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
        patch: forcedLiveEndFailurePatch(canRetry),
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
          pending_force_end_commit_id: null,
          terminal_probe_started_at: null,
          terminal_probe_until: null,
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
      patch: forcedLiveEndFailurePatch(canRetry),
    });
    return "failed" as const;
  };
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

async function queueRoomLiveActivityEnd(
  base44: any,
  body: Entity,
  validatedRoomSnapshot?: Entity,
): Promise<RoomLiveActivityEndQueue> {
  return await enqueueRoomLiveActivityEnd({
    roomStore: base44.asServiceRole.entities.GameRoom,
    liveStore: base44.asServiceRole.entities.LiveActivityRegistration,
    lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
    signalStore: base44.asServiceRole.entities.GameRoomSignal,
    validatedRoomSnapshot,
    roomID: body.room_id,
    matchID: body.match_id,
    terminalCommitID: body.terminal_commit_id,
    closeCompletion: body.close_completion,
  });
}

async function enqueueRoomLiveActivityEndOnly(
  base44: any,
  body: Entity,
): Promise<Entity> {
  const queued = await queueRoomLiveActivityEnd(base44, body);
  return {
    ok: true,
    room_id: queued.roomID,
    match_id: queued.matchID,
    matched: queued.registrations.length,
    queued: queued.queued,
    skipped: queued.skipped,
    already_queued: queued.alreadyQueued,
    receipt: queued.receipt,
  };
}

async function deliverQueuedRoomLiveActivityEndOnly(
  base44: any,
  body: Entity,
): Promise<Entity> {
  const deadlineEpochMs = clampDeadline(
    body.deadline_epoch_ms,
    LIVE_SYNC_BUDGET_MS,
  );
  const bounded = await runWithinDeadline({
    deadlineEpochMs,
    waitForStartedWork: true,
    operation: () =>
      deliverQueuedRoomLiveActivityEnd({
        liveStore: base44.asServiceRole.entities.LiveActivityRegistration,
        roomID: body.room_id,
        matchID: body.match_id,
        deadlineEpochMs,
        deliver: async ({ registration, roomID, matchID, roomRevision }) =>
          await withBillingLifecycleContentionRetry({
            deadlineEpochMs,
            operation: () =>
              deliverForcedLiveActivityEnd({
                base44,
                registration,
                roomID,
                matchID,
                roomRevision,
                queuedPendingOnly: true,
              }),
          }),
      }),
  });
  if (bounded.timedOut) {
    // The deadline expired before starting. Started delivery workers are
    // awaited through their account-lease cleanup before a response is sent.
    return {
      ok: true,
      room_id: clean(body.room_id),
      match_id: clean(body.match_id),
      matched: 0,
      delivered: 0,
      failed: 0,
      skipped: 0,
      deferred: 1,
      timed_out: true,
    };
  }
  const result = bounded.value;
  return {
    ok: true,
    room_id: result.roomID,
    match_id: result.matchID,
    matched: result.registrations.length,
    delivered: result.delivered,
    failed: result.failed,
    skipped: result.skipped,
    deferred: result.deferredRegistrations.length,
  };
}

async function endRoomLiveActivities(
  base44: any,
  body: Entity,
  validatedRoomSnapshot?: Entity,
): Promise<Entity> {
  // The durable force-end boundary is shared with the enqueue-only action.
  // Compatibility callers continue into bounded APNs delivery below.
  const queued = await queueRoomLiveActivityEnd(
    base44,
    body,
    validatedRoomSnapshot,
  );
  const {
    roomID,
    matchID,
    roomRevision,
    registrations,
  } = queued;
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
      });
      if (outcome === "delivered") delivered += 1;
      else if (outcome === "failed") failed += 1;
      else skipped += 1;
    },
  });
  return {
    ok: true,
    queued: registrations.length,
    durably_queued: queued.queued,
    skipped_during_enqueue: queued.skipped,
    already_queued: queued.alreadyQueued,
    enqueue_receipt: queued.receipt,
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
  candidates.push(
    ...await store.filter(
      { status: "active", retry_requested: true },
      "updated_at",
      12,
      0,
    ) || [],
  );
  const dueByID = new Map<string, Entity>();
  for (const registration of candidates) {
    if (liveDeliveryDue(registration)) {
      dueByID.set(clean(registration.id), registration);
    }
  }
  const due = [...dueByID.values()];
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
          if (
            clean(registration.terminal_probe_started_at) &&
            clean(registration.terminal_probe_until)
          ) {
            results.push(
              await probeLiveActivityTerminal(base44, {
                registration_id: registration.id,
                probe_revision: registration.delivery_revision,
                deadline_epoch_ms: deadlineEpochMs,
              }),
            );
          } else if (registration.pending_force_end === true) {
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

async function processEvents(
  base44: any,
  body: Entity,
  timing?: ReturnType<typeof createProcessEventTiming>,
): Promise<Entity> {
  const deadlineEpochMs = clampDeadline(body.deadline_epoch_ms, 50_000);
  const sourceEventID = clean(body.source_event_id);
  if (!sourceEventID) throw new PushContractError("Source event is required.");
  let events = await allMatching(
    base44.asServiceRole.entities.PushNotificationEvent,
    { source_event_id: sourceEventID },
  );
  const existingRoomEvent = events.find((event) =>
    clean(event.room_id) && clean(event.match_id) &&
    ["game_started", "game_finished"].includes(clean(event.event_type))
  );
  let room: Entity | null = null;
  if (existingRoomEvent) {
    const candidates = await allMatching(
      base44.asServiceRole.entities.GameRoom,
      { id: clean(existingRoomEvent.room_id) },
    );
    room = candidates.find((candidate) =>
      clean(candidate.id) === clean(existingRoomEvent.room_id) &&
      [candidate.game_started_event_id, candidate.game_finished_event_id]
        .some((eventID) =>
          clean(eventID) === sourceEventID
        )
    ) || null;
  } else if (!events.length) {
    room = await roomForSourceEvent(base44, sourceEventID);
  }
  if (room) {
    // Reconcile even when some recipient rows already exist: a room can be
    // committed after only the first updates in the batched inbox commit.
    await repairRoomPushOutbox(base44, room);
    await repairFinishedRoomCommunityProfiles(base44, room);
    events = await allMatching(
      base44.asServiceRole.entities.PushNotificationEvent,
      { source_event_id: sourceEventID },
    );
  }
  // ActivityKit is attempted before the ordinary event becomes terminal. If
  // this invocation is interrupted, the still-pending alert outbox remains a
  // durable trigger for the scheduled failover worker.
  const roomEvent = events.find((event) =>
    clean(event.room_id) && clean(event.match_id) &&
    ["game_started", "game_finished"].includes(clean(event.event_type))
  );
  if (roomEvent) {
    timing?.begin("live_activity");
    try {
      await syncLiveActivities(base44, {
        room_id: roomEvent.room_id,
        match_id: roomEvent.match_id,
        deadline_epoch_ms: deadlineEpochMs,
      });
    } finally {
      timing?.complete("live_activity");
    }
  }
  const results: Entity[] = [];
  timing?.begin("ordinary_push");
  let eventWork;
  try {
    eventWork = await runBounded({
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
  } finally {
    timing?.complete("ordinary_push");
  }
  return {
    ok: true,
    processed: results.length,
    deferred: eventWork.unstarted.length,
    results,
  };
}

async function drain(base44: any, body: Entity): Promise<Entity> {
  const deadlineEpochMs = Date.now() + DRAIN_BUDGET_MS;
  const limit = normalizePushDrainLimit(body.limit);
  // Terminal intent and committed recipient outboxes are the highest-priority
  // recovery boundary. Run them before any nested profile worker so a slow or
  // poisoned profile side effect cannot prevent room convergence.
  const repairedEvents = await reconcileRecentRoomOutboxes(
    base44,
    Math.min(deadlineEpochMs, Date.now() + 10_000),
  );
  const announcementFanoutResults = await drainAnnouncementFanout({
    base44,
    deadlineEpochMs: Math.min(deadlineEpochMs, Date.now() + 15_000),
  });
  const inboxBackfill = await backfillLegacyInboxProjections({
    base44,
    deadlineEpochMs: Math.min(deadlineEpochMs, Date.now() + 8_000),
  });
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
  const queryLimit = pushDrainQueryLimit(limit);
  for (const state of ["pending", "retry", "processing"]) {
    candidates.push(
      ...await base44.asServiceRole.entities.PushNotificationEvent.filter(
        { state },
        state === "retry"
          ? "next_attempt_at"
          : state === "processing"
          ? "lease_until"
          : "created_at",
        queryLimit,
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
  const batch = due.slice(0, limit);
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
    items: [...gameEvents.entries()].slice(0, 12),
    concurrency: 6,
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
    concurrency: PUSH_DRAIN_CONCURRENCY,
    deadlineEpochMs,
    worker: async (event) => {
      try {
        results.push(await processOneEvent(base44, event));
      } catch {
        // Claimed rows recover after their exact lease expires.
      }
    },
  });
  const communityProfileRepairs = await drainDurableCommunityProfileRepairs(
    base44,
    Math.min(24, limit),
    Math.min(deadlineEpochMs, Date.now() + 3_000),
  );
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
    community_profile_repairs: communityProfileRepairs,
    announcement_fanout_results: announcementFanoutResults,
    inbox_backfill: inboxBackfill,
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
    const base44 = createClientFromRequest(canonicalBase44Request(req));

    if (
      [
        "process_event",
        "drain",
        "probe_live_activity_terminal",
        "sync_live_activity",
        "enqueue_room_live_activity_end",
        "deliver_queued_room_live_activity_end",
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
        const timing = createProcessEventTiming(body?.timing_id);
        let timingOutcome: "completed" | "failed" = "failed";
        try {
          const result = await processEvents(base44, body, timing);
          timingOutcome = "completed";
          return Response.json(result);
        } finally {
          // Only a server-generated, format-validated opaque id enables this
          // timing log. Missing/invalid values never affect push processing.
          if (timing.timingID) {
            try {
              console.info(
                "pushNotificationAction process-event timing",
                timing.report(timingOutcome),
              );
            } catch {
              // Timing diagnostics must never change durable push processing.
            }
          }
        }
      }
      if (action === "sync_live_activity") {
        return Response.json(await syncLiveActivities(base44, body));
      }
      if (action === "probe_live_activity_terminal") {
        return Response.json(await probeLiveActivityTerminal(base44, body));
      }
      if (action === "enqueue_room_live_activity_end") {
        return Response.json(
          await enqueueRoomLiveActivityEndOnly(base44, body),
        );
      }
      if (action === "deliver_queued_room_live_activity_end") {
        return Response.json(
          await deliverQueuedRoomLiveActivityEndOnly(base44, body),
        );
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
            eventStore: base44.asServiceRole.entities.PushNotificationEvent,
            signalStore: base44.asServiceRole.entities.GameRoomSignal,
            userID: clean(user.id),
            body,
            persist,
            leasedUserIDs,
          }),
      });
      let terminalDelivery = "";
      if (
        saved.pending_force_end === true &&
        clean(saved.pending_room_id) && clean(saved.pending_match_id)
      ) {
        terminalDelivery = await deliverForcedLiveActivityEnd({
          base44,
          registration: saved,
          roomID: clean(saved.pending_room_id),
          matchID: clean(saved.pending_match_id),
          roomRevision: Math.max(
            0,
            Number(saved.pending_room_revision || 0),
          ),
          queuedPendingOnly: true,
        });
        if (terminalDelivery === "skipped") {
          const current = (await allMatching(liveActivityStore, {
            id: clean(saved.id),
          }))[0];
          if (
            current?.pending_force_end === true && liveDeliveryDue(current)
          ) {
            throw new PushContractError(
              "Live Activity termination was deferred; retry registration.",
              503,
              "terminal_delivery_prompt_unconfirmed",
            );
          }
        }
      }
      const probeAccepted = terminalDelivery
        ? true
        : await triggerLiveActivityTerminalProbe(base44, saved);
      if (
        clean(saved.terminal_probe_started_at) &&
        clean(saved.terminal_probe_until) && !probeAccepted
      ) {
        // The row is already durable, but return a retryable response so the
        // device keeps the token and promptly re-prompts instead of relying on
        // the slower scheduled sweep.
        throw new PushContractError(
          "Live Activity reconciliation was deferred; retry registration.",
          503,
          "terminal_probe_prompt_unconfirmed",
        );
      }
      return Response.json({
        ok: true,
        registration_id: saved.id,
        updated_at: saved.updated_at,
        ...(terminalDelivery ? { terminal_delivery: terminalDelivery } : {}),
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
            roomStore: base44.asServiceRole.entities.GameRoom,
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
    return pushErrorResponse(error);
  }
});
