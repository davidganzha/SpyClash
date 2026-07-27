import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import { clean } from "./contracts.ts";
import { withPushWriterLeases } from "./device-registration.ts";
import { runBounded } from "./bounded-work.ts";

type Entity = Record<string, any>;
const FANOUT_LEASE_MS = 90_000;
const PUSH_EVENT_TTL_MS = 7 * 24 * 60 * 60 * 1_000;
export const FANOUT_RECIPIENT_BATCH = 64;
export const FANOUT_ANNOUNCEMENTS_PER_DRAIN = 4;
export const FANOUT_MAX_FAILED_VERIFY_SWEEPS = 5;

export function announcementFanoutDue(
  announcement: Entity,
  now = new Date(),
): boolean {
  if (
    clean(announcement.status) !== "published" ||
    clean(announcement.importance) !== "important"
  ) return false;
  const state = clean(announcement.fanout_state);
  if (state === "pending") return true;
  if (state === "retry") {
    const next = Date.parse(clean(announcement.fanout_next_attempt_at));
    return !Number.isFinite(next) || next <= now.getTime();
  }
  if (state === "processing") {
    const lease = Date.parse(clean(announcement.fanout_lease_until));
    return !Number.isFinite(lease) || lease <= now.getTime();
  }
  return false;
}

export async function claimAnnouncementFanout(input: {
  store: any;
  announcement: Entity;
  now?: Date;
  randomUUID?: () => string;
}): Promise<Entity | null> {
  const now = input.now || new Date();
  if (!announcementFanoutDue(input.announcement, now)) return null;
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  const token = `announcement-fanout:${randomUUID()}`;
  const revision = randomUUID();
  const phase = clean(input.announcement.fanout_phase) === "verify"
    ? "verify"
    : "enqueue";
  const cutoffAt = clean(
    input.announcement.fanout_cutoff_at ||
      input.announcement.published_at || input.announcement.created_at,
  ) || now.toISOString();
  const claimed = {
    ...input.announcement,
    fanout_state: "processing",
    fanout_attempt_count: Number(input.announcement.fanout_attempt_count || 0) +
      1,
    fanout_lease_token: token,
    fanout_lease_until: new Date(now.getTime() + FANOUT_LEASE_MS).toISOString(),
    fanout_revision: revision,
    fanout_last_error_code: clean(
      input.announcement.fanout_last_error_code,
    ),
    fanout_phase: phase,
    fanout_cursor_registration_id: clean(
      input.announcement.fanout_cursor_registration_id,
    ),
    fanout_cutoff_at: cutoffAt,
    fanout_enqueued_count: Math.max(
      0,
      Number(input.announcement.fanout_enqueued_count || 0),
    ),
    fanout_sweep_failed: input.announcement.fanout_sweep_failed === true,
    fanout_verify_failure_passes: Math.max(
      0,
      Number(input.announcement.fanout_verify_failure_passes || 0),
    ),
    fanout_last_failed_registration_id: clean(
      input.announcement.fanout_last_failed_registration_id,
    ),
    updated_at: now.toISOString(),
  };
  const result = await input.store.updateMany({
    id: input.announcement.id,
    status: "published",
    importance: "important",
    fanout_state: input.announcement.fanout_state,
    fanout_lease_token: input.announcement.fanout_lease_token,
    fanout_revision: input.announcement.fanout_revision,
  }, {
    $set: {
      fanout_state: claimed.fanout_state,
      fanout_attempt_count: claimed.fanout_attempt_count,
      fanout_lease_token: claimed.fanout_lease_token,
      fanout_lease_until: claimed.fanout_lease_until,
      fanout_revision: claimed.fanout_revision,
      fanout_last_error_code: claimed.fanout_last_error_code,
      fanout_phase: claimed.fanout_phase,
      fanout_cursor_registration_id: claimed.fanout_cursor_registration_id,
      fanout_cutoff_at: claimed.fanout_cutoff_at,
      fanout_enqueued_count: claimed.fanout_enqueued_count,
      fanout_sweep_failed: claimed.fanout_sweep_failed,
      fanout_verify_failure_passes: claimed.fanout_verify_failure_passes,
      fanout_last_failed_registration_id:
        claimed.fanout_last_failed_registration_id,
      updated_at: claimed.updated_at,
    },
  });
  return Number(result?.updated) === 1 ? claimed : null;
}

export async function completeAnnouncementFanout(input: {
  store: any;
  claimed: Entity;
  state: "retry" | "complete" | "cancelled" | "failed";
  errorCode?: string;
  nextAttemptAt?: string;
  checkpoint?: {
    phase?: "enqueue" | "verify";
    cursorRegistrationID?: string;
    enqueuedCount?: number;
    sweepFailed?: boolean;
    verifyFailurePasses?: number;
    lastFailedRegistrationID?: string;
  };
  now?: Date;
  randomUUID?: () => string;
}): Promise<boolean> {
  const now = input.now || new Date();
  const revision = (input.randomUUID || (() => crypto.randomUUID()))();
  const patch: Entity = {
    fanout_state: input.state,
    fanout_lease_token: "",
    fanout_lease_until: now.toISOString(),
    fanout_revision: revision,
    fanout_next_attempt_at: input.nextAttemptAt || null,
    fanout_last_error_code: clean(input.errorCode).slice(0, 80),
    updated_at: now.toISOString(),
  };
  if (input.state === "complete") patch.fanout_completed_at = now.toISOString();
  if (input.checkpoint?.phase) {
    patch.fanout_phase = input.checkpoint.phase;
  }
  if (input.checkpoint?.cursorRegistrationID !== undefined) {
    patch.fanout_cursor_registration_id = clean(
      input.checkpoint.cursorRegistrationID,
    );
  }
  if (input.checkpoint?.enqueuedCount !== undefined) {
    patch.fanout_enqueued_count = Math.max(
      0,
      Number(input.checkpoint.enqueuedCount || 0),
    );
  }
  if (input.checkpoint?.sweepFailed !== undefined) {
    patch.fanout_sweep_failed = input.checkpoint.sweepFailed;
  }
  if (input.checkpoint?.verifyFailurePasses !== undefined) {
    patch.fanout_verify_failure_passes = Math.max(
      0,
      Number(input.checkpoint.verifyFailurePasses || 0),
    );
  }
  if (input.checkpoint?.lastFailedRegistrationID !== undefined) {
    patch.fanout_last_failed_registration_id = clean(
      input.checkpoint.lastFailedRegistrationID,
    );
  }
  const result = await input.store.updateMany({
    id: input.claimed.id,
    status: "published",
    fanout_state: "processing",
    fanout_lease_token: input.claimed.fanout_lease_token,
    fanout_revision: input.claimed.fanout_revision,
  }, { $set: patch });
  return Number(result?.updated) === 1;
}

function fanoutRetryAt(attemptCount: number, now = new Date()): string {
  // A cursor checkpoint makes every pass useful. Keep the cadence tight while
  // still backing off transient contention; never terminalize merely because
  // the audience needs many pages.
  const seconds = Math.min(60, 5 * 2 ** Math.max(0, attemptCount - 1));
  return new Date(now.getTime() + seconds * 1_000).toISOString();
}

async function stableClaimSource(
  store: any,
  claimed: Entity,
): Promise<Entity | null> {
  const rows = await store.filter(
    {
      id: claimed.id,
      status: "published",
      importance: "important",
      fanout_state: "processing",
      fanout_lease_token: claimed.fanout_lease_token,
      fanout_revision: claimed.fanout_revision,
    },
    "created_date",
    2,
    0,
  ) || [];
  if (rows.length !== 1) return null;
  const expiry = Date.parse(clean(rows[0].expires_at));
  return Number.isFinite(expiry) && expiry <= Date.now() ? null : rows[0];
}

async function enqueueForRegistration(input: {
  base44: any;
  claimed: Entity;
  registration: Entity;
  now: Date;
}): Promise<"created" | "existing" | "skipped"> {
  const userID = clean(input.registration.user_id);
  const registrationID = clean(input.registration.id);
  if (!userID || !registrationID) return "skipped";
  try {
    return await withPushWriterLeases({
      lifecycleStore:
        input.base44.asServiceRole.entities.BillingIdentityLifecycle,
      userIDs: [userID],
      action: async (persist) => {
        const stable = await stableClaimSource(
          input.base44.asServiceRole.entities.NotificationAnnouncement,
          input.claimed,
        );
        if (!stable) return "skipped";
        const cutoff = Date.parse(clean(stable.fanout_cutoff_at));
        const registrations = await input.base44.asServiceRole.entities
          .PushDeviceRegistration.filter(
            {
              id: registrationID,
              user_id: userID,
              status: "active",
              alert_authorized: true,
              ...(Number.isFinite(cutoff)
                ? { created_date: { $lte: new Date(cutoff).toISOString() } }
                : {}),
              $or: [
                { announcements_enabled: true },
                { announcements_enabled: { $exists: false } },
              ],
            },
            "id",
            2,
            0,
          ) || [];
        if (registrations.length !== 1) return "skipped";
        const dedupeKey = `global_announcement:${clean(stable.id)}:${userID}`;
        const existing = await input.base44.asServiceRole.entities
          .PushNotificationEvent.filter(
            { dedupe_key: dedupeKey },
            "created_date",
            2,
            0,
          ) || [];
        if (existing.length > 1) {
          throw new Error("duplicate_announcement_events");
        }
        if (existing.length === 1) return "existing";
        const expiry = Math.min(
          Date.parse(clean(stable.expires_at)) || Number.POSITIVE_INFINITY,
          input.now.getTime() + PUSH_EVENT_TTL_MS,
        );
        const eventID = crypto.randomUUID();
        await persist(() =>
          input.base44.asServiceRole.entities.PushNotificationEvent.create({
            dedupe_key: dedupeKey,
            source_event_id: clean(stable.id),
            event_type: "global_announcement",
            source_type: "notification_announcement",
            recipient_user_id: userID,
            actor_user_id: "",
            room_id: "",
            match_id: "",
            announcement_id: clean(stable.id),
            state: "pending",
            attempt_count: 0,
            delivered_count: 0,
            failed_count: 0,
            delivered_token_hashes: [],
            lease_token: "",
            lease_until: input.now.toISOString(),
            revision: eventID,
            next_attempt_at: input.now.toISOString(),
            expires_at: new Date(expiry).toISOString(),
            last_error_code: "",
            created_at: input.now.toISOString(),
            updated_at: input.now.toISOString(),
          })
        );
        return "created";
      },
    });
  } catch (error) {
    if (
      error instanceof BillingIdentityLifecycleError &&
      error.code === "deletion_in_progress"
    ) return "skipped";
    throw error;
  }
}

export async function fanoutAnnouncement(input: {
  base44: any;
  announcement: Entity;
  deadlineEpochMs: number;
  now?: Date;
  nowEpochMs?: () => number;
}): Promise<Entity> {
  const now = input.now || new Date();
  const nowEpochMs = input.nowEpochMs || Date.now;
  const store = input.base44.asServiceRole.entities.NotificationAnnouncement;
  const claimed = await claimAnnouncementFanout({
    store,
    announcement: input.announcement,
    now,
  });
  if (!claimed) {
    return { claimed: false, state: clean(input.announcement.fanout_state) };
  }
  const stable = await stableClaimSource(store, claimed);
  if (!stable) {
    // A concurrent withdraw owns the new revision, so this exact completion is
    // expected to lose CAS. Either way no further recipients are enqueued.
    await completeAnnouncementFanout({
      store,
      claimed,
      state: "cancelled",
      errorCode: "announcement_stale",
      now,
    }).catch(() => false);
    return { claimed: true, state: "cancelled", created: 0 };
  }

  if (nowEpochMs() >= input.deadlineEpochMs) {
    const attempt = Number(claimed.fanout_attempt_count || 1);
    await completeAnnouncementFanout({
      store,
      claimed,
      state: "retry",
      errorCode: "fanout_deadline",
      nextAttemptAt: fanoutRetryAt(attempt, now),
      checkpoint: {
        phase: clean(stable.fanout_phase) === "verify" ? "verify" : "enqueue",
        cursorRegistrationID: clean(stable.fanout_cursor_registration_id),
        enqueuedCount: Number(stable.fanout_enqueued_count || 0),
      },
      now,
    });
    return {
      claimed: true,
      state: "retry",
      created: 0,
      existing: 0,
      skipped: 0,
      failures: 0,
      deferred: 1,
      phase: clean(stable.fanout_phase) === "verify" ? "verify" : "enqueue",
      cursor_registration_id: clean(stable.fanout_cursor_registration_id),
    };
  }

  const cutoff = clean(stable.fanout_cutoff_at);
  const cursor = clean(stable.fanout_cursor_registration_id);
  // One keyset page is the only audience query per pass. The extra row proves
  // whether the persisted cursor reached the tail without an offset/full scan.
  const page: Entity[] =
    await input.base44.asServiceRole.entities.PushDeviceRegistration
      .filter(
        {
          status: "active",
          alert_authorized: true,
          ...(cutoff ? { created_date: { $lte: cutoff } } : {}),
          ...(cursor ? { id: { $gt: cursor } } : {}),
          $or: [
            { announcements_enabled: true },
            { announcements_enabled: { $exists: false } },
          ],
        },
        "id",
        FANOUT_RECIPIENT_BATCH + 1,
        0,
      ) || [];
  const batch = page.slice(0, FANOUT_RECIPIENT_BATCH);
  const hasMore = page.length > FANOUT_RECIPIENT_BATCH;
  let created = 0;
  let existing = 0;
  let skipped = 0;
  let failures = 0;
  const outcomes = new Map<
    string,
    "created" | "existing" | "skipped" | "failed" | "covered"
  >();
  const deadlineDeferred = new Set<string>();
  const unresolvedFailures = new Set<string>();
  const groupsByUser = new Map<string, Entity[]>();
  for (const registration of batch) {
    const userID = clean(registration.user_id);
    const group = groupsByUser.get(userID) || [];
    group.push(registration);
    groupsByUser.set(userID, group);
  }
  const work = await runBounded({
    items: [...groupsByUser.values()],
    concurrency: 6,
    deadlineEpochMs: input.deadlineEpochMs,
    nowEpochMs,
    worker: async (group) => {
      const groupFailures: string[] = [];
      let covered = false;
      for (let index = 0; index < group.length; index += 1) {
        if (nowEpochMs() >= input.deadlineEpochMs) {
          for (const deferred of group.slice(index)) {
            deadlineDeferred.add(clean(deferred.id));
          }
          break;
        }
        const registration = group[index];
        const registrationID = clean(registration.id);
        try {
          const result = await enqueueForRegistration({
            base44: input.base44,
            claimed,
            registration,
            now,
          });
          if (result === "created") created += 1;
          else if (result === "existing") existing += 1;
          else skipped += 1;
          outcomes.set(registrationID, result);
          if (result === "created" || result === "existing") {
            covered = true;
            // The outbox row is per announcement + user, not per device. Once
            // one eligible registration proves that row, the remaining devices
            // in this page are covered by the same durable event.
            for (const sibling of group.slice(index + 1)) {
              outcomes.set(clean(sibling.id), "covered");
            }
            break;
          }
        } catch {
          failures += 1;
          outcomes.set(registrationID, "failed");
          groupFailures.push(registrationID);
        }
      }
      if (!covered) {
        for (const registrationID of groupFailures) {
          unresolvedFailures.add(registrationID);
        }
      }
    },
  });
  const unstarted = new Set(
    [
      ...deadlineDeferred,
      ...work.unstarted.flatMap((group) =>
        group.map((registration) => clean(registration.id))
      ),
    ],
  );
  let durableCursor = cursor;
  for (const registration of batch) {
    const registrationID = clean(registration.id);
    const outcome = outcomes.get(registrationID);
    if (!outcome || unstarted.has(registrationID)) {
      break;
    }
    durableCursor = registrationID;
  }
  const attempt = Number(claimed.fanout_attempt_count || 1);
  const phase: "enqueue" | "verify" = clean(stable.fanout_phase) === "verify"
    ? "verify"
    : "enqueue";
  const verifyFailurePasses = Math.max(
    0,
    Number(stable.fanout_verify_failure_passes || 0),
  );
  const priorSweepFailed = stable.fanout_sweep_failed === true;
  const currentSweepFailed = priorSweepFailed || unresolvedFailures.size > 0;
  const failedRegistrationID = [...unresolvedFailures].sort()[0] ||
    clean(stable.fanout_last_failed_registration_id);
  const reachedTail = !hasMore &&
    durableCursor === clean(batch.at(-1)?.id || cursor) &&
    unstarted.size === 0;
  // The first pass enqueues, the second independently walks the same frozen
  // audience and proves that every dedupe row exists. This closes the classic
  // lost-create-response / checkpoint-advanced gap before completion.
  let nextPhase = phase;
  let nextCursor = durableCursor;
  let nextSweepFailed = currentSweepFailed;
  let nextVerifyFailurePasses = verifyFailurePasses;
  let nextFailedRegistrationID = failedRegistrationID;
  let state: "retry" | "complete" | "failed" = "retry";
  if (reachedTail && phase === "enqueue") {
    nextPhase = "verify";
    nextCursor = "";
    // Enqueue failures are intentionally retried by the independent proof
    // sweep. A lost create response is expected to become `existing` there.
    nextSweepFailed = false;
  } else if (reachedTail && phase === "verify" && !currentSweepFailed) {
    state = "complete";
    nextSweepFailed = false;
    nextFailedRegistrationID = "";
  } else if (reachedTail && phase === "verify" && currentSweepFailed) {
    nextVerifyFailurePasses = verifyFailurePasses + 1;
    if (nextVerifyFailurePasses >= FANOUT_MAX_FAILED_VERIFY_SWEEPS) {
      state = "failed";
      nextSweepFailed = true;
    } else {
      // Retry a complete proof sweep. The main cursor already reached every
      // later recipient, so a poison row can no longer starve the audience.
      nextCursor = "";
      nextSweepFailed = false;
    }
  }
  const errorCode = state === "complete"
    ? ""
    : state === "failed"
    ? "fanout_verification_failed"
    : unstarted.size
    ? "fanout_deadline"
    : reachedTail && phase === "enqueue"
    ? "fanout_verification_pending"
    : reachedTail && phase === "verify" && currentSweepFailed
    ? "fanout_verification_retry"
    : unresolvedFailures.size
    ? "fanout_recipient_error"
    : "fanout_page_pending";
  await completeAnnouncementFanout({
    store,
    claimed,
    state,
    errorCode,
    nextAttemptAt: state === "retry" ? fanoutRetryAt(attempt, now) : undefined,
    checkpoint: {
      phase: nextPhase,
      cursorRegistrationID: nextCursor,
      enqueuedCount: Number(stable.fanout_enqueued_count || 0) + created,
      sweepFailed: nextSweepFailed,
      verifyFailurePasses: nextVerifyFailurePasses,
      lastFailedRegistrationID: nextFailedRegistrationID,
    },
    now,
  });
  return {
    claimed: true,
    state,
    created,
    existing,
    skipped,
    failures,
    deferred: unstarted.size,
    phase: nextPhase,
    cursor_registration_id: nextCursor,
    sweep_failed: nextSweepFailed,
    verify_failure_passes: nextVerifyFailurePasses,
    last_failed_registration_id: nextFailedRegistrationID,
  };
}

export async function drainAnnouncementFanout(input: {
  base44: any;
  deadlineEpochMs: number;
  nowEpochMs?: () => number;
}): Promise<Entity[]> {
  const nowEpochMs = input.nowEpochMs || Date.now;
  const candidates: Entity[] = [];
  for (const state of ["pending", "retry", "processing"]) {
    candidates.push(
      ...await input.base44.asServiceRole.entities.NotificationAnnouncement
        .filter(
          { status: "published", importance: "important", fanout_state: state },
          state === "retry"
            ? "fanout_next_attempt_at"
            : state === "processing"
            ? "fanout_lease_until"
            : "published_at",
          12,
          0,
        ) || [],
    );
  }
  const due = candidates.filter((announcement) =>
    announcementFanoutDue(announcement)
  ).sort((left, right) =>
    Date.parse(clean(
        left.updated_at || left.published_at || left.created_at,
      )) -
      Date.parse(clean(
        right.updated_at || right.published_at || right.created_at,
      )) || clean(left.id).localeCompare(clean(right.id))
  );
  const results: Entity[] = [];
  const selected = due.slice(0, FANOUT_ANNOUNCEMENTS_PER_DRAIN);
  for (let index = 0; index < selected.length; index += 1) {
    if (nowEpochMs() >= input.deadlineEpochMs) break;
    const announcementsLeft = selected.length - index;
    const remainingBudget = Math.max(
      0,
      input.deadlineEpochMs - nowEpochMs(),
    );
    const slotBudget = Math.max(
      500,
      Math.floor(remainingBudget / announcementsLeft),
    );
    results.push(
      await fanoutAnnouncement({
        base44: input.base44,
        announcement: selected[index],
        deadlineEpochMs: Math.min(
          input.deadlineEpochMs,
          nowEpochMs() + slotBudget,
        ),
        nowEpochMs,
      }),
    );
  }
  return results;
}
