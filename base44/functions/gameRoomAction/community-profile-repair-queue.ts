type Entity = Record<string, any>;

export type CommunityProfileRepairStore = {
  filter(
    query: Record<string, unknown>,
    sort?: string,
    limit?: number,
    skip?: number,
  ): Promise<Entity[]>;
  updateMany(
    query: Record<string, unknown>,
    patch: Record<string, unknown>,
  ): Promise<{ updated?: number }>;
};

export type CommunityProfileRepairClaim = {
  source: Entity;
  token: string;
};

export type CommunityProfileRepairRunResult = {
  outcome: "performed" | "completed" | "deferred" | "failed" | "missing";
  source: Entity | null;
};

export type CommunityProfileRecipientRepairResult = {
  attempted: number;
  succeeded: number;
  failedUserIDs: string[];
};

const DEFAULT_LEASE_MILLISECONDS = 2 * 60 * 1_000;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function state(source: Entity): string {
  return clean(source?.profile_repair_state).toLocaleLowerCase();
}

async function readSource(
  store: CommunityProfileRepairStore,
  sourceID: string,
): Promise<Entity | null> {
  const rows = await store.filter({ id: sourceID }, "created_date", 2, 0) || [];
  return rows.find((row) => clean(row?.id) === sourceID) || null;
}

async function sourceForResultKey(
  store: CommunityProfileRepairStore,
  resultKey: string,
): Promise<Entity | null> {
  const rows = await store.filter(
    { result_key: resultKey },
    "created_date",
    8,
    0,
  ) || [];
  return rows.filter((row) => clean(row?.result_key) === resultKey)
    .sort((left, right) =>
      clean(left?.created_date).localeCompare(clean(right?.created_date)) ||
      clean(left?.id).localeCompare(clean(right?.id))
    )[0] || null;
}

function isCompleted(source: Entity | null): boolean {
  return state(source || {}) === "completed";
}

export function pendingCommunityProfileRepairFields(): Entity {
  return {
    profile_repair_state: "pending",
    profile_repair_attempt_count: 0,
  };
}

export async function repairCommunityProfileRecipients(input: {
  recipientUserIDs: readonly unknown[];
  repairRecipient: (userID: string) => Promise<boolean>;
  concurrency?: number;
}): Promise<CommunityProfileRecipientRepairResult> {
  const recipientUserIDs = [
    ...new Set(
      input.recipientUserIDs.map(clean).filter(Boolean),
    ),
  ];
  const concurrency = Math.min(
    Math.max(Math.floor(Number(input.concurrency)) || 4, 1),
    8,
  );
  const failedUserIDs: string[] = [];
  let succeeded = 0;
  for (
    let offset = 0;
    offset < recipientUserIDs.length;
    offset += concurrency
  ) {
    const batch = recipientUserIDs.slice(offset, offset + concurrency);
    const settled = await Promise.allSettled(
      batch.map((userID) => input.repairRecipient(userID)),
    );
    for (const [index, result] of settled.entries()) {
      if (result.status === "fulfilled" && result.value === true) {
        succeeded += 1;
      } else {
        failedUserIDs.push(batch[index]);
      }
    }
  }
  return {
    attempted: recipientUserIDs.length,
    succeeded,
    failedUserIDs,
  };
}

/**
 * A ranked history row is the durable work source. This write is completed
 * before the terminal room can be reset or deleted, and is recovered by the
 * deterministic result key if an earlier create response was lost.
 */
export async function ensureCommunityProfileRepairSource(input: {
  store: CommunityProfileRepairStore;
  record: Entity;
}): Promise<Entity> {
  const resultKey = clean(input.record?.result_key);
  if (!resultKey) throw new Error("Profile repair result key is required");
  let source = clean(input.record?.id)
    ? input.record
    : await sourceForResultKey(input.store, resultKey);
  if (!source?.id) {
    source = await sourceForResultKey(input.store, resultKey);
  }
  if (!source?.id) {
    throw new Error("Profile repair history source could not be confirmed");
  }
  if (["pending", "processing", "completed"].includes(state(source))) {
    return source;
  }

  const patch = {
    $set: {
      result_key: resultKey,
      ...pendingCommunityProfileRepairFields(),
    },
  };
  try {
    const result = await input.store.updateMany(
      { id: clean(source.id) },
      patch,
    );
    if (Number(result?.updated) !== 1) {
      throw new Error("Profile repair history source update was not unique");
    }
  } catch (error) {
    const recovered = await readSource(input.store, clean(source.id));
    if (
      recovered &&
      ["pending", "processing", "completed"].includes(state(recovered))
    ) return recovered;
    throw error;
  }
  const confirmed = await readSource(input.store, clean(source.id));
  if (!confirmed || state(confirmed) !== "pending") {
    throw new Error("Profile repair history source was not confirmed");
  }
  return confirmed;
}

function leaseIsActive(source: Entity, now: Date): boolean {
  const leaseUntil = Date.parse(clean(source?.profile_repair_lease_until));
  return state(source) === "processing" && Number.isFinite(leaseUntil) &&
    leaseUntil > now.getTime();
}

export async function claimCommunityProfileRepair(input: {
  store: CommunityProfileRepairStore;
  source: Entity;
  now?: Date;
  randomUUID?: () => string;
  leaseMilliseconds?: number;
}): Promise<
  | { status: "claimed"; claim: CommunityProfileRepairClaim }
  | { status: "completed" | "deferred" | "missing"; source: Entity | null }
> {
  const sourceID = clean(input.source?.id);
  if (!sourceID) return { status: "missing", source: null };
  const now = input.now || new Date();
  const current = await readSource(input.store, sourceID);
  if (!current) return { status: "missing", source: null };
  if (isCompleted(current)) return { status: "completed", source: current };
  if (leaseIsActive(current, now)) {
    return { status: "deferred", source: current };
  }
  if (!["pending", "processing"].includes(state(current))) {
    return { status: "deferred", source: current };
  }

  const token = `profile-repair:${
    (input.randomUUID || (() => crypto.randomUUID()))()
  }`;
  const leaseMilliseconds = Math.max(
    1_000,
    Number(input.leaseMilliseconds) || DEFAULT_LEASE_MILLISECONDS,
  );
  const query: Entity = {
    id: sourceID,
    profile_repair_state: state(current),
  };
  if (state(current) === "processing") {
    query.profile_repair_token = clean(current.profile_repair_token);
  }
  const patch = {
    $set: {
      profile_repair_state: "processing",
      profile_repair_token: token,
      profile_repair_lease_until: new Date(
        now.getTime() + leaseMilliseconds,
      ).toISOString(),
      profile_repair_attempt_count: Math.max(
        0,
        Math.floor(Number(current.profile_repair_attempt_count) || 0),
      ) + 1,
    },
  };
  try {
    const result = await input.store.updateMany(query, patch);
    if (Number(result?.updated) !== 1) {
      return {
        status: "deferred",
        source: await readSource(input.store, sourceID),
      };
    }
  } catch (error) {
    const recovered = await readSource(input.store, sourceID);
    if (
      state(recovered || {}) === "processing" &&
      clean(recovered?.profile_repair_token) === token
    ) {
      return { status: "claimed", claim: { source: recovered!, token } };
    }
    throw error;
  }
  const claimed = await readSource(input.store, sourceID);
  if (
    state(claimed || {}) !== "processing" ||
    clean(claimed?.profile_repair_token) !== token
  ) return { status: "deferred", source: claimed };
  return { status: "claimed", claim: { source: claimed!, token } };
}

export async function completeCommunityProfileRepair(input: {
  store: CommunityProfileRepairStore;
  claim: CommunityProfileRepairClaim;
  now?: Date;
}): Promise<{ completed: boolean; source: Entity | null }> {
  const sourceID = clean(input.claim.source?.id);
  const now = input.now || new Date();
  let result: { updated?: number };
  try {
    result = await input.store.updateMany({
      id: sourceID,
      profile_repair_state: "processing",
      profile_repair_token: input.claim.token,
    }, {
      $set: {
        profile_repair_state: "completed",
        profile_repair_lease_until: now.toISOString(),
        profile_repair_completed_at: now.toISOString(),
      },
    });
  } catch (error) {
    const recovered = await readSource(input.store, sourceID);
    if (isCompleted(recovered)) {
      return { completed: true, source: recovered };
    }
    throw error;
  }
  const source = await readSource(input.store, sourceID);
  return {
    completed: Number(result?.updated) === 1 || isCompleted(source),
    source,
  };
}

export async function runCommunityProfileRepair(input: {
  store: CommunityProfileRepairStore;
  source: Entity;
  repair: (source: Entity) => Promise<boolean>;
  now?: Date;
  randomUUID?: () => string;
  leaseMilliseconds?: number;
  logError?: (message: string, error: unknown) => void;
}): Promise<CommunityProfileRepairRunResult> {
  const claim = await claimCommunityProfileRepair(input);
  if (claim.status !== "claimed") {
    return {
      outcome: claim.status,
      source: claim.source,
    };
  }
  try {
    if (!(await input.repair(claim.claim.source))) {
      input.logError?.(
        "community profile repair remained incomplete",
        new Error(`profile repair source ${clean(claim.claim.source?.id)}`),
      );
      return {
        outcome: "failed",
        source: await readSource(input.store, clean(claim.claim.source.id)),
      };
    }
    const completion = await completeCommunityProfileRepair({
      store: input.store,
      claim: claim.claim,
      now: input.now,
    });
    if (!completion.completed) {
      input.logError?.(
        "community profile repair completion raced",
        new Error(`profile repair source ${clean(claim.claim.source?.id)}`),
      );
    }
    return {
      outcome: completion.completed ? "performed" : "failed",
      source: completion.source,
    };
  } catch (error) {
    input.logError?.("community profile repair failed", error);
    return {
      outcome: "failed",
      source: await readSource(input.store, clean(claim.claim.source.id)),
    };
  }
}

export async function dueCommunityProfileRepairSources(input: {
  store: CommunityProfileRepairStore;
  limit: number;
  now?: Date;
}): Promise<Entity[]> {
  const limit = Math.min(Math.max(Math.floor(input.limit) || 1, 1), 100);
  const now = input.now || new Date();
  const [pending, processing] = await Promise.all([
    input.store.filter(
      { profile_repair_state: "pending" },
      "created_date",
      limit,
      0,
    ),
    input.store.filter(
      { profile_repair_state: "processing" },
      "profile_repair_lease_until",
      limit,
      0,
    ),
  ]);
  const due = [
    ...(pending || []),
    ...(processing || []).filter((source) => {
      const leaseUntil = Date.parse(clean(source?.profile_repair_lease_until));
      return !Number.isFinite(leaseUntil) || leaseUntil <= now.getTime();
    }),
  ];
  due.sort((left, right) => {
    const leftDue = state(left) === "processing"
      ? Date.parse(clean(left?.profile_repair_lease_until))
      : Date.parse(clean(left?.created_date));
    const rightDue = state(right) === "processing"
      ? Date.parse(clean(right?.profile_repair_lease_until))
      : Date.parse(clean(right?.created_date));
    const stableLeft = Number.isFinite(leftDue) ? leftDue : 0;
    const stableRight = Number.isFinite(rightDue) ? rightDue : 0;
    return stableLeft - stableRight ||
      clean(left?.id).localeCompare(clean(right?.id));
  });
  const seen = new Set<string>();
  return due.filter((source) => {
    const id = clean(source?.id);
    if (!id || seen.has(id)) return false;
    seen.add(id);
    return true;
  }).slice(0, limit);
}
