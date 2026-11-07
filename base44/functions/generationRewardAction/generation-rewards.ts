import { quotaKey, totalQuotaUsage } from "./quota.ts";

export const REWARDED_FREE_DAILY_LIMIT = 3;
export function rewardedGenerationEnabled(): boolean {
  try {
    return Deno.env.get("SPYCLASH_REWARDED_GENERATION_ENABLED") === "true";
  } catch {
    return false;
  }
}
export function configuredRewardAdUnit(): string | null {
  let value = "";
  try {
    value = Deno.env.get("ADMOB_REWARDED_AD_UNIT_ID")?.trim() || "";
  } catch { /* disabled */ }
  // Google's public demo unit must never mint real server credits.
  return /^ca-app-pub-\d{16}\/\d{10}$/.test(value) &&
      !value.startsWith("ca-app-pub-3940256099942544/")
    ? value
    : null;
}
export class GenerationRewardError extends Error {
  constructor(readonly code: string, message: string, readonly status = 409) {
    super(message);
  }
}
export type RewardRecord = {
  id?: string;
  user_id: string;
  attempt_id: string;
  custom_data: string;
  ad_unit_id: string;
  issued_at: string;
  state: "pending" | "earned" | "reserved" | "spent";
  transaction_id?: string;
  earned_at?: string;
  generation_request_id?: string;
};
export type RewardStore = {
  filter: (
    query: Record<string, unknown>,
    sort: string,
    limit: number,
    skip: number,
  ) => Promise<RewardRecord[]>;
  create: (record: RewardRecord) => Promise<RewardRecord>;
  updateMany: (
    query: Record<string, unknown>,
    update: Record<string, Record<string, unknown>>,
  ) => Promise<{ updated?: number }>;
};
export type RewardWriteGuard = {
  boundary: <T>(operation: () => Promise<T>) => Promise<T>;
};
const unavailable = () =>
  new GenerationRewardError(
    "reward_storage_unavailable",
    "Your generation bonus is being confirmed. Please try again shortly.",
    503,
  );
export function rewardUUID(value: unknown): string {
  if (
    typeof value !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(value)
  ) {
    throw new GenerationRewardError(
      "invalid_request_id",
      "A stable request identifier is required.",
      400,
    );
  }
  return value.toLowerCase();
}
export async function rewardAttempt(
  store: RewardStore,
  userID: string,
  attemptID: string,
): Promise<RewardRecord | null> {
  const rows = await store.filter(
    { user_id: userID, attempt_id: attemptID },
    "created_date",
    2,
    0,
  );
  if (rows.length > 1 || (rows[0] && !rows[0].id)) throw unavailable();
  return rows[0] || null;
}
export async function availableRewardCredits(
  store: RewardStore,
  userID: string,
): Promise<number> {
  const rows = await store.filter(
    { user_id: userID, state: "earned" },
    "created_date",
    5000,
    0,
  );
  if (
    rows.length === 5000 ||
    new Set(rows.map((r) => r.attempt_id)).size !== rows.length
  ) throw unavailable();
  return rows.length;
}
export async function generationRewardStatus(
  input: {
    rewardStore: RewardStore;
    quotaStore: any;
    userID: string;
    unlimited: boolean;
    enabled: boolean;
    adUnit: string | null;
    now?: Date;
  },
) {
  const now = input.now || new Date();
  const resetsAt = new Date(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1),
  ).toISOString();
  if (!input.enabled) {
    return {
      enabled: false,
      unlimited: input.unlimited,
      daily_limit: 3,
      free_remaining: null,
      bonus_credits: 0,
      resets_at: resetsAt,
      ad_available: false,
    };
  }
  const [usage, bonus] = await Promise.all([
    input.quotaStore.filter(
      { quota_key: quotaKey(input.userID, now) },
      "created_date",
      100,
      0,
    ),
    availableRewardCredits(input.rewardStore, input.userID),
  ]);
  if (usage.length === 100) throw unavailable();
  return {
    enabled: true,
    unlimited: input.unlimited,
    daily_limit: 3,
    free_remaining: input.unlimited
      ? null
      : Math.max(0, 3 - totalQuotaUsage(usage)),
    bonus_credits: bonus,
    resets_at: resetsAt,
    ad_available: !input.unlimited && Boolean(input.adUnit),
  };
}
/** Caller holds the same generation coordinator used by spending and deletion. */
export async function prepareRewardAttempt(
  input: {
    store: RewardStore;
    guard: RewardWriteGuard;
    userID: string;
    requestID: string;
    adUnit: string;
    now?: Date;
  },
) {
  const attemptID = rewardUUID(input.requestID);
  let row = await rewardAttempt(input.store, input.userID, attemptID);
  if (!row) {
    const nonce = [...crypto.getRandomValues(new Uint8Array(32))].map((v) =>
      v.toString(16).padStart(2, "0")
    ).join("");
    const prepared: RewardRecord = {
      user_id: input.userID,
      attempt_id: attemptID,
      custom_data: `${attemptID}.legacy.${nonce}`,
      ad_unit_id: input.adUnit,
      issued_at: (input.now || new Date()).toISOString(),
      state: "pending",
    };
    try {
      await input.guard.boundary(() => input.store.create(prepared));
    } catch { /* reconcile lost ACK */ }
    row = await rewardAttempt(input.store, input.userID, attemptID);
    if (!row) throw unavailable();
  }
  if (row.state !== "pending") {
    throw new GenerationRewardError(
      "reward_already_earned",
      "This viewing already earned its generation bonus.",
    );
  }
  return {
    attempt_id: row.attempt_id,
    custom_data: row.custom_data,
    ad_unit_id: row.ad_unit_id,
    user_id: input.userID,
    ssv_user_id: input.userID,
  };
}
export type RewardCallback = {
  transactionID: string;
  customData: string;
  userID: string;
  adUnit: string;
  rewardAmount: number;
  rewardItem: string;
  timestamp: number;
};
/** The callback must already have passed Google's signature verifier. */
export async function grantVerifiedGenerationReward(
  input: {
    store: RewardStore;
    guard: RewardWriteGuard;
    callback: RewardCallback;
    now?: Date;
  },
) {
  const c = input.callback, now = input.now || new Date();
  const invalid = () =>
    new GenerationRewardError(
      "invalid_reward_claim",
      "Invalid generation reward callback.",
      400,
    );
  const match = /^([0-9a-f-]{36})(?:\.legacy)?\.([0-9a-f]{64})$/.exec(c.customData);
  if (!match) throw invalid();
  const row = await rewardAttempt(input.store, c.userID, rewardUUID(match[1]));
  if (
    !row || row.custom_data !== c.customData ||
    (c.adUnit !== row.ad_unit_id &&
      c.adUnit !== row.ad_unit_id.split("/").at(-1)) ||
    c.rewardAmount !== 1 || c.rewardItem !== "generation"
  ) throw invalid();
  const issued = Date.parse(row.issued_at);
  if (
    !Number.isFinite(issued) || c.timestamp < issued - 60_000 ||
    c.timestamp > issued + 86_400_000 || c.timestamp > now.getTime() + 300_000
  ) throw invalid();
  if (row.transaction_id) {
    if (row.transaction_id !== c.transactionID) throw invalid();
    return { success: true, duplicate: true };
  }
  const existing = await input.store.filter(
    { transaction_id: c.transactionID },
    "created_date",
    2,
    0,
  );
  if (existing.length) throw invalid();
  try {
    await input.guard.boundary(() =>
      input.store.updateMany({
        id: row.id,
        state: "pending",
        custom_data: row.custom_data,
      }, {
        $set: {
          state: "earned",
          transaction_id: c.transactionID,
          earned_at: new Date(c.timestamp).toISOString(),
        },
      })
    );
  } catch { /* reconcile exact signed event */ }
  const saved = await rewardAttempt(input.store, c.userID, row.attempt_id);
  if (
    saved?.transaction_id !== c.transactionID ||
    !["earned", "reserved", "spent"].includes(saved.state)
  ) throw unavailable();
  return { success: true, duplicate: false };
}
export async function reserveGenerationReward(
  input: {
    store: RewardStore;
    guard: RewardWriteGuard;
    userID: string;
    requestID: string;
  },
): Promise<RewardRecord | null> {
  const rows = await input.store.filter(
    { user_id: input.userID, state: "earned" },
    "created_date",
    1,
    0,
  );
  const row = rows[0];
  if (!row?.id) return null;
  try {
    await input.guard.boundary(() =>
      input.store.updateMany({
        id: row.id,
        user_id: input.userID,
        state: "earned",
      }, {
        $set: { state: "reserved", generation_request_id: input.requestID },
      })
    );
  } catch { /* reconcile before starting AI */ }
  const saved = await rewardAttempt(input.store, input.userID, row.attempt_id);
  if (
    saved?.state !== "reserved" ||
    saved.generation_request_id !== input.requestID
  ) throw unavailable();
  return saved;
}
export async function settleGenerationReward(
  input: {
    store: RewardStore;
    guard: RewardWriteGuard;
    reward: RewardRecord;
    requestID: string;
    success: boolean;
  },
) {
  const state = input.success ? "spent" : "earned";
  // Exact-state CAS makes retries and a lost acknowledgement safe; a definitive
  // failed operation can restore at most the credit it actually reserved.
  for (let retry = 0; retry < 3; retry++) {
    try {
      await input.guard.boundary(() =>
        input.store.updateMany({
          id: input.reward.id,
          state: "reserved",
          generation_request_id: input.requestID,
        }, {
          $set: {
            state,
            ...(input.success ? {} : { generation_request_id: "" }),
          },
        })
      );
    } catch { /* reconcile */ }
    const saved = await rewardAttempt(
      input.store,
      input.reward.user_id,
      input.reward.attempt_id,
    );
    if (
      saved?.state === state &&
      (input.success
        ? saved.generation_request_id === input.requestID
        : !saved.generation_request_id)
    ) return;
  }
  throw unavailable();
}
