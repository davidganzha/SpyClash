import { runBounded } from "./bounded-work.ts";
import { clean, PushContractError } from "./contracts.ts";

type Entity = Record<string, any>;
const PAGE_SIZE = 100;

export type QueuedLiveEndDelivery = {
  registration: Entity;
  roomID: string;
  matchID: string;
  roomRevision: number;
};

export type QueuedLiveEndDeliveryResult = {
  roomID: string;
  matchID: string;
  registrations: Entity[];
  delivered: number;
  failed: number;
  skipped: number;
  deferredRegistrations: Entity[];
};

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

function exactQueuedEnd(
  registration: Entity,
  roomID: string,
  matchID: string,
): boolean {
  return clean(registration.status) === "active" &&
    clean(registration.token_kind) === "activity" &&
    registration.pending_force_end === true &&
    clean(registration.pending_room_id) === roomID &&
    clean(registration.pending_match_id) === matchID;
}

export async function deliverQueuedRoomLiveActivityEnd(input: {
  liveStore: any;
  roomID: unknown;
  matchID: unknown;
  deadlineEpochMs: number;
  deliver: (
    delivery: QueuedLiveEndDelivery,
  ) => Promise<"delivered" | "failed" | "skipped">;
  concurrency?: number;
  nowEpochMs?: () => number;
}): Promise<QueuedLiveEndDeliveryResult> {
  const roomID = clean(input.roomID);
  const matchID = clean(input.matchID);
  if (!roomID || !matchID) {
    throw new PushContractError("Room and match are required.");
  }

  // This recovery action intentionally has no GameRoom dependency: a host
  // close may already have deleted the room. The durable registration binding
  // is the source of truth for both selection and the terminal revision.
  const registrations = (await allMatching(input.liveStore, {
    status: "active",
    token_kind: "activity",
    pending_force_end: true,
    pending_room_id: roomID,
    pending_match_id: matchID,
  })).filter((registration) => exactQueuedEnd(registration, roomID, matchID));

  const groupsByUser = new Map<string, Entity[]>();
  for (const registration of registrations) {
    const userID = clean(registration.user_id);
    const group = groupsByUser.get(userID) || [];
    group.push(registration);
    groupsByUser.set(userID, group);
  }

  let delivered = 0;
  let failed = 0;
  let skipped = 0;
  const deferredRegistrations: Entity[] = [];
  const nowEpochMs = input.nowEpochMs || Date.now;
  const groupWork = await runBounded({
    items: [...groupsByUser.values()],
    concurrency: input.concurrency ?? 3,
    deadlineEpochMs: input.deadlineEpochMs,
    nowEpochMs,
    worker: async (group) => {
      if (nowEpochMs() >= input.deadlineEpochMs) {
        deferredRegistrations.push(...group);
        return;
      }
      for (let index = 0; index < group.length; index += 1) {
        if (nowEpochMs() >= input.deadlineEpochMs) {
          deferredRegistrations.push(...group.slice(index));
          return;
        }
        const registration = group[index];
        try {
          const outcome = await input.deliver({
            registration,
            roomID,
            matchID,
            roomRevision: Math.max(
              0,
              Number(registration.pending_room_revision || 0),
            ),
          });
          if (outcome === "delivered") delivered += 1;
          else if (outcome === "failed") failed += 1;
          else skipped += 1;
        } catch {
          // The exact pending row remains durable for the scheduled drain.
          failed += 1;
        }
      }
    },
  });
  deferredRegistrations.push(...groupWork.unstarted.flat());

  return {
    roomID,
    matchID,
    registrations,
    delivered,
    failed,
    skipped,
    deferredRegistrations,
  };
}
