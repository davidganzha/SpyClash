import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import { runBounded } from "./bounded-work.ts";
import { boundedText, clean } from "./contracts.ts";
import { withPushWriterLeases } from "./device-registration.ts";
import {
  committedPersonalInboxPatch,
  hiddenPersonalInboxPatch,
  PERSONAL_INBOX_EVENT_TYPES,
} from "./inbox-projection.ts";
import {
  type PushEvent,
  pushEventLifecycleUserIDs,
  type SourceContext,
} from "./push-events.ts";

export const LEGACY_INBOX_BACKFILL_BATCH = 32;
const SOURCE_SETTLE_MS = 2 * 60 * 1_000;

type Persist = <T>(writer: () => Promise<T>) => Promise<T>;

async function one(store: any, filter: Record<string, unknown>) {
  const rows = await store.filter(filter, "created_date", 2, 0) || [];
  return rows.length === 1 ? rows[0] : null;
}

function recentlyCreated(event: PushEvent, now: Date): boolean {
  const created = Date.parse(clean(event.created_at || event.created_date));
  return Number.isFinite(created) && now.getTime() - created < SOURCE_SETTLE_MS;
}

function retryRotationTimestamp(event: PushEvent, now: Date): string {
  const previous = Date.parse(clean(event.updated_at));
  return new Date(
    Math.max(now.getTime(), Number.isFinite(previous) ? previous + 1 : 0),
  ).toISOString();
}

async function rotateDeferredEvent(input: {
  store: any;
  current: PushEvent;
  persist: Persist;
  now: Date;
}): Promise<boolean> {
  const result: PushEvent = await input.persist(() =>
    input.store.updateMany({
      id: input.current.id,
      state: input.current.state,
      lease_token: input.current.lease_token,
      revision: input.current.revision,
      $or: [
        { inbox_committed_at: { $exists: false } },
        { inbox_committed_at: null },
      ],
    }, {
      $set: {
        updated_at: retryRotationTimestamp(input.current, input.now),
        revision: crypto.randomUUID(),
      },
    })
  );
  return Number(result?.updated) === 1;
}

async function rotateFailedEvent(input: {
  base44: any;
  event: PushEvent;
  now: Date;
}): Promise<boolean> {
  try {
    return await withPushWriterLeases({
      lifecycleStore:
        input.base44.asServiceRole.entities.BillingIdentityLifecycle,
      userIDs: pushEventLifecycleUserIDs(input.event),
      action: async (persist) => {
        const store = input.base44.asServiceRole.entities.PushNotificationEvent;
        const current = await one(store, { id: clean(input.event.id) });
        if (!current || clean(current.inbox_committed_at)) return true;
        return await rotateDeferredEvent({
          store,
          current,
          persist,
          now: input.now,
        });
      },
    });
  } catch (error) {
    // A lifecycle race already has a durable owner. The row remains
    // uncommitted and is safe to retry after that lease settles.
    if (error instanceof BillingIdentityLifecycleError) return false;
    throw error;
  }
}

async function legacyInboxSource(
  base44: any,
  event: PushEvent,
  now: Date,
): Promise<SourceContext> {
  const sourceEventID = clean(event.source_event_id);
  const actorID = clean(event.actor_user_id);
  const recipientID = clean(event.recipient_user_id);
  if (!sourceEventID || !recipientID) {
    return { valid: false, reason: "invalid_event" };
  }
  if (clean(event.event_type) === "friend_request") {
    const friendship = await one(
      base44.asServiceRole.entities.Friendship,
      { request_event_id: sourceEventID },
    );
    if (!friendship) {
      return {
        valid: false,
        retryable: recentlyCreated(event, now),
        reason: "friend_request_source_pending",
      };
    }
    if (
      clean(friendship.requester_id) !== actorID ||
      clean(friendship.addressee_id) !== recipientID ||
      clean(friendship.status) === "blocked"
    ) return { valid: false, reason: "friend_request_stale" };
    const actor = await one(base44.asServiceRole.entities.User, {
      id: actorID,
    });
    return {
      valid: true,
      actorName: boundedText(actor?.display_name || actor?.full_name, 48) ||
        "An operative",
    };
  }
  if (clean(event.event_type) === "room_invite") {
    const invite = await one(base44.asServiceRole.entities.RoomInvite, {
      notification_event_id: sourceEventID,
    });
    if (!invite) {
      return {
        valid: false,
        retryable: recentlyCreated(event, now),
        reason: "room_invite_source_pending",
      };
    }
    if (
      clean(invite.sender_user_id) !== actorID ||
      clean(invite.recipient_user_id) !== recipientID ||
      clean(invite.room_id) !== clean(event.room_id)
    ) return { valid: false, reason: "room_invite_stale" };
    const actor = await one(base44.asServiceRole.entities.User, {
      id: actorID,
    });
    return {
      valid: true,
      actorName: boundedText(actor?.display_name || actor?.full_name, 48) ||
        "An operative",
    };
  }
  const room = await one(base44.asServiceRole.entities.GameRoom, {
    id: clean(event.room_id),
  });
  if (!room) {
    return {
      valid: false,
      retryable: recentlyCreated(event, now),
      reason: "game_source_pending",
    };
  }
  const participants = [
    ...(Array.isArray(room.participant_user_ids)
      ? room.participant_user_ids
      : []),
    ...(Array.isArray(room.players)
      ? room.players.map((player: PushEvent) => player?.user_id)
      : []),
  ].map(clean);
  if (clean(event.event_type) === "game_finished") {
    const committed = clean(room.status) === "finished" &&
      clean(room.game_finished_event_id) === sourceEventID &&
      clean(room.match_id) === clean(event.match_id);
    if (!committed) {
      const terminalMatchID = clean(room.terminal_intent?.match_id);
      const pending = clean(room.status) !== "finished";
      return {
        valid: false,
        retryable: pending &&
          (terminalMatchID === clean(event.match_id) ||
            recentlyCreated(event, now)),
        reason: pending ? "game_finish_pending" : "game_finish_stale",
      };
    }
  }
  return {
    valid: participants.includes(recipientID) &&
      clean(room.match_id) === clean(event.match_id),
    reason: "game_source_stale",
  };
}

async function migrateOne(input: {
  base44: any;
  event: PushEvent;
  now: Date;
}): Promise<"visible" | "hidden" | "deferred"> {
  try {
    return await withPushWriterLeases({
      lifecycleStore:
        input.base44.asServiceRole.entities.BillingIdentityLifecycle,
      userIDs: pushEventLifecycleUserIDs(input.event),
      action: async (persist) => {
        const store = input.base44.asServiceRole.entities.PushNotificationEvent;
        const current = await one(store, { id: clean(input.event.id) });
        if (!current || clean(current.inbox_committed_at)) return "deferred";
        const source = clean(current.state) === "cancelled"
          ? { valid: false, reason: "cancelled" }
          : await legacyInboxSource(input.base44, current, input.now);
        if (!source.valid && source.retryable) {
          await rotateDeferredEvent({
            store,
            current,
            persist,
            now: input.now,
          });
          return "deferred";
        }
        const patch = source.valid
          ? committedPersonalInboxPatch(current, source, input.now)
          : hiddenPersonalInboxPatch(input.now);
        const result: PushEvent = await persist(() =>
          store.updateMany({
            id: current.id,
            state: current.state,
            lease_token: current.lease_token,
            revision: current.revision,
          }, {
            $set: {
              ...patch,
              revision: crypto.randomUUID(),
            },
          })
        );
        if (Number(result?.updated) !== 1) return "deferred";
        return source.valid ? "visible" : "hidden";
      },
    });
  } catch (error) {
    if (error instanceof BillingIdentityLifecycleError) {
      if (error.retryable) return "deferred";

      // A terminal lifecycle boundary (for example, an account already in
      // deletion) must not pin the oldest backfill window forever. This CAS
      // only makes a pre-existing outbox projection invisible; it cannot
      // create or resurrect user data and is safe if deletion wins the race.
      const store = input.base44.asServiceRole.entities.PushNotificationEvent;
      const current = await one(store, { id: clean(input.event.id) });
      if (!current || clean(current.inbox_committed_at)) return "deferred";
      const result: PushEvent = await store.updateMany({
        id: current.id,
        state: current.state,
        lease_token: current.lease_token,
        revision: current.revision,
      }, {
        $set: {
          ...hiddenPersonalInboxPatch(input.now),
          revision: crypto.randomUUID(),
        },
      });
      return Number(result?.updated) === 1 ? "hidden" : "deferred";
    }
    throw error;
  }
}

export async function backfillLegacyInboxProjections(input: {
  base44: any;
  deadlineEpochMs: number;
  now?: Date;
}): Promise<Record<string, number>> {
  const now = input.now || new Date();
  if (Date.now() >= input.deadlineEpochMs) {
    return { selected: 0, visible: 0, hidden: 0, deferred: 0, errors: 0 };
  }
  const store = input.base44.asServiceRole.entities.PushNotificationEvent;
  const candidates: PushEvent[] = await store.filter(
    {
      event_type: { $in: [...PERSONAL_INBOX_EVENT_TYPES] },
      $or: [
        { inbox_committed_at: { $exists: false } },
        { inbox_committed_at: null },
      ],
    },
    // Every started retry is CAS-touched below. Sorting by that durable
    // timestamp makes the uncommitted set a round-robin queue: poison rows
    // remain retryable without pinning every newer legacy event behind them.
    "updated_at",
    LEGACY_INBOX_BACKFILL_BATCH,
    0,
  ) || [];
  let visible = 0;
  let hidden = 0;
  let deferred = 0;
  let errors = 0;
  const work = await runBounded({
    items: candidates,
    concurrency: 6,
    deadlineEpochMs: input.deadlineEpochMs,
    worker: async (event) => {
      try {
        const result = await migrateOne({ base44: input.base44, event, now });
        if (result === "visible") visible += 1;
        else if (result === "hidden") hidden += 1;
        else deferred += 1;
      } catch (error) {
        // One corrupt legacy row or transient source read must not abort the
        // other independently leased rows in this scheduled drain. Move the
        // failed row to the durable retry tail when its lifecycle is stable.
        errors += 1;
        try {
          await rotateFailedEvent({
            base44: input.base44,
            event,
            now,
          });
        } catch (rotationError) {
          console.error(
            "legacy inbox backfill retry rotation failed",
            clean(event.id),
            rotationError instanceof Error
              ? rotationError.message
              : rotationError,
          );
        }
        console.error(
          "legacy inbox backfill row failed",
          clean(event.id),
          error instanceof Error ? error.message : error,
        );
      }
    },
  });
  return {
    selected: candidates.length,
    visible,
    hidden,
    deferred: deferred + work.unstarted.length,
    errors,
  };
}
