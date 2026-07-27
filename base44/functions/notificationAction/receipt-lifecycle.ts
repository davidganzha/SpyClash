import { clean, NotificationContractError } from "./contracts.ts";

type Lease = {
  recordID: string;
  subjectKey: string;
  leaseToken: string;
  leaseUntil: string;
  revision: string;
};

const MAX_ATTEMPTS = 6;
const LEASE_MS = 10 * 60 * 1_000;
const CLOCK_SKEW_MS = 5_000;

function hex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function subjectKey(userID: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`spyclash-billing-lifecycle:${userID}`),
  );
  return `billing:${hex(digest).slice(0, 40)}`;
}

async function rows(store: any, key: string): Promise<Record<string, any>[]> {
  return await store.filter({ subject_key: key }, "created_date", 100, 0) || [];
}

function activeLease(row: Record<string, any>, now: Date): boolean {
  const leaseUntil = Date.parse(clean(row.lease_until));
  return Number.isFinite(leaseUntil) &&
    leaseUntil > now.getTime() + CLOCK_SKEW_MS;
}

async function convergeInactiveInitializers(
  store: any,
  matches: Record<string, any>[],
  now: Date,
): Promise<void> {
  if (
    matches.some((row) =>
      clean(row.state) === "deleting" || activeLease(row, now)
    )
  ) {
    throw new NotificationContractError(
      "Inbox lifecycle rows are ambiguous.",
      503,
      "ambiguous_lifecycle",
    );
  }
  const canonical =
    [...matches].sort((left, right) =>
      clean(left.created_date).localeCompare(clean(right.created_date)) ||
      clean(left.id).localeCompare(clean(right.id))
    )[0];
  for (const duplicate of matches) {
    if (clean(duplicate.id) === clean(canonical.id)) continue;
    await store.delete(duplicate.id);
  }
}

async function acquire(
  store: any,
  userID: string,
  nowFactory: () => Date,
  randomUUID: () => string,
): Promise<Lease> {
  const key = await subjectKey(userID);
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt += 1) {
    const now = nowFactory();
    const matches = await rows(store, key);
    if (!matches.length) {
      const revision = randomUUID();
      try {
        await store.create({
          subject_key: key,
          state: "active",
          lease_token: `initialized:${revision}`,
          lease_until: now.toISOString(),
          revision,
        });
      } catch {
        // A concurrent initializer may have won. Re-read through the loop.
      }
      continue;
    }
    if (matches.length !== 1) {
      await convergeInactiveInitializers(store, matches, now);
      continue;
    }
    const current = matches[0];
    if (clean(current.state) === "deleting") {
      throw new NotificationContractError(
        "Account deletion is in progress.",
        409,
        "deletion_in_progress",
      );
    }
    if (activeLease(current, now)) {
      throw new NotificationContractError(
        "Inbox is busy. Retry shortly.",
        409,
        "active_lease",
      );
    }
    const token = `notification:${randomUUID()}`;
    const revision = randomUUID();
    const nextLeaseUntil = new Date(now.getTime() + LEASE_MS).toISOString();
    const result = await store.updateMany({
      id: current.id,
      subject_key: key,
      state: current.state,
      lease_token: current.lease_token,
      revision: current.revision,
    }, {
      $set: {
        state: "active",
        lease_token: token,
        lease_until: nextLeaseUntil,
        revision,
      },
    });
    if (Number(result?.updated) === 1) {
      return {
        recordID: clean(current.id),
        subjectKey: key,
        leaseToken: token,
        leaseUntil: nextLeaseUntil,
        revision,
      };
    }
  }
  throw new NotificationContractError(
    "Inbox is busy. Retry shortly.",
    409,
    "cas_contention",
  );
}

async function assertLease(store: any, lease: Lease, now: Date): Promise<void> {
  const matches = await store.filter(
    {
      id: lease.recordID,
      subject_key: lease.subjectKey,
      state: "active",
      lease_token: lease.leaseToken,
      revision: lease.revision,
    },
    "created_date",
    2,
    0,
  ) || [];
  if (
    matches.length !== 1 ||
    Date.parse(clean(matches[0].lease_until)) <= now.getTime() + CLOCK_SKEW_MS
  ) {
    throw new NotificationContractError(
      "Inbox write lease was lost.",
      409,
      "lease_lost",
    );
  }
}

async function release(
  store: any,
  lease: Lease,
  now: Date,
  randomUUID: () => string,
): Promise<void> {
  const result = await store.updateMany({
    id: lease.recordID,
    subject_key: lease.subjectKey,
    state: "active",
    lease_token: lease.leaseToken,
    revision: lease.revision,
  }, {
    $set: {
      lease_token: `released:${randomUUID()}`,
      lease_until: now.toISOString(),
      revision: randomUUID(),
    },
  });
  if (Number(result?.updated) !== 1) {
    throw new NotificationContractError(
      "Inbox write lease release could not be verified.",
      503,
      "lease_release_failed",
    );
  }
}

export async function withNotificationWriteLease<T>(input: {
  lifecycleStore: any;
  userID: string;
  action: (persist: <R>(writer: () => Promise<R>) => Promise<R>) => Promise<T>;
  nowFactory?: () => Date;
  randomUUID?: () => string;
}): Promise<T> {
  const nowFactory = input.nowFactory || (() => new Date());
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  const userID = clean(input.userID);
  if (!userID) {
    throw new NotificationContractError("Unauthorized", 401, "unauthorized");
  }
  const lease = await acquire(
    input.lifecycleStore,
    userID,
    nowFactory,
    randomUUID,
  );
  let actionError: unknown;
  try {
    await assertLease(input.lifecycleStore, lease, nowFactory());
    return await input.action(async <R>(writer: () => Promise<R>) => {
      await assertLease(input.lifecycleStore, lease, nowFactory());
      return await writer();
    });
  } catch (error) {
    actionError = error;
    throw error;
  } finally {
    try {
      await release(input.lifecycleStore, lease, nowFactory(), randomUUID);
    } catch (error) {
      if (!actionError) throw error;
      console.error("notification lifecycle release failed");
    }
  }
}
