import {
  availableRewardCredits,
  generationRewardStatus,
  grantVerifiedGenerationReward,
  prepareRewardAttempt,
  reserveGenerationReward,
  type RewardRecord,
  type RewardStore,
  settleGenerationReward,
} from "./generation-rewards.ts";
function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
async function rejects(operation: () => Promise<unknown>) {
  try {
    await operation();
  } catch {
    return;
  }
  throw new Error("Expected rejection");
}
const userID = "account-1", requestID = "a1a1a1a1-a1a1-41a1-81a1-a1a1a1a1a1a1";
const adUnit = "ca-app-pub-1111111111111111/1234567890",
  now = new Date("2026-11-05T12:00:00Z");
const guard = {
  boundary: async <T>(operation: () => Promise<T>) => await operation(),
};
class Store implements RewardStore {
  rows: RewardRecord[] = [];
  loseCreate = false;
  loseUpdate = false;
  async filter(
    query: Record<string, unknown>,
    _sort: string,
    limit: number,
    skip: number,
  ) {
    return structuredClone(
      this.rows.filter((row) =>
        Object.entries(query).every(([key, value]) =>
          (row as any)[key] === value
        )
      ).slice(skip, skip + limit),
    );
  }
  async create(row: RewardRecord) {
    const saved = { ...row, id: crypto.randomUUID() };
    this.rows.push(saved);
    if (this.loseCreate) {
      this.loseCreate = false;
      throw new Error("lost ACK");
    }
    return structuredClone(saved);
  }
  async updateMany(
    query: Record<string, unknown>,
    update: Record<string, Record<string, unknown>>,
  ) {
    const rows = this.rows.filter((row) =>
      Object.entries(query).every(([key, value]) => (row as any)[key] === value)
    );
    for (const row of rows) Object.assign(row, update.$set);
    if (this.loseUpdate) {
      this.loseUpdate = false;
      throw new Error("lost ACK");
    }
    return { updated: rows.length };
  }
}
async function earned(store = new Store()) {
  const prepared = await prepareRewardAttempt({
    store,
    guard,
    userID,
    requestID,
    adUnit,
    now,
  });
  const callback = {
    transactionID: "txn1",
    customData: prepared.custom_data,
    userID,
    adUnit: "1234567890",
    rewardAmount: 1,
    rewardItem: "generation",
    timestamp: now.getTime() + 1000,
  };
  await grantVerifiedGenerationReward({
    store,
    guard,
    callback,
    now: new Date(now.getTime() + 2000),
  });
  return { store, callback, prepared };
}
Deno.test("reward preparation retries a lost create acknowledgement without duplicate attempt", async () => {
  const store = new Store();
  store.loseCreate = true;
  const a = await prepareRewardAttempt({
    store,
    guard,
    userID,
    requestID,
    adUnit,
    now,
  });
  const b = await prepareRewardAttempt({
    store,
    guard,
    userID,
    requestID,
    adUnit,
    now,
  });
  assert(a.custom_data === b.custom_data && store.rows.length === 1);
  assert(a.user_id === userID);
});
Deno.test("verified reward duplicate and lost write acknowledgement mint one credit", async () => {
  const store = new Store();
  store.loseUpdate = true;
  const f = await earned(store);
  await grantVerifiedGenerationReward({
    store,
    guard,
    callback: f.callback,
    now: new Date(now.getTime() + 5000),
  });
  assert(await availableRewardCredits(store, userID) === 1);
});
Deno.test("reward rejects other owner, token, ad unit, amount, item and impossible event time", async () => {
  const f = await earned();
  for (
    const patch of [
      { userID: "other" },
      { customData: f.callback.customData + "0" },
      { adUnit: "9999999999" },
      { rewardAmount: 2 },
      { rewardItem: "coins" },
      { timestamp: now.getTime() - 120_000 },
      { timestamp: now.getTime() + 90_000_000 },
    ]
  ) {
    await rejects(() =>
      grantVerifiedGenerationReward({
        store: f.store,
        guard,
        callback: { ...f.callback, ...patch },
        now: new Date(now.getTime() + 100_000_000),
      })
    );
  }
});
Deno.test("late delivery grants earned credit without imposing credit expiration", async () => {
  const store = new Store();
  const p = await prepareRewardAttempt({
    store,
    guard,
    userID,
    requestID,
    adUnit,
    now,
  });
  await grantVerifiedGenerationReward({
    store,
    guard,
    callback: {
      transactionID: "late",
      customData: p.custom_data,
      userID,
      adUnit,
      rewardAmount: 1,
      rewardItem: "generation",
      timestamp: now.getTime() + 1000,
    },
    now: new Date("2027-01-01T00:00:00Z"),
  });
  assert(await availableRewardCredits(store, userID) === 1);
});
Deno.test("credit reservation is exclusive and definitive failure refunds once across lost ACK", async () => {
  const { store } = await earned();
  store.loseUpdate = true;
  const reward = await reserveGenerationReward({
    store,
    guard,
    userID,
    requestID: "generation1",
  });
  assert(reward);
  assert(
    await reserveGenerationReward({
      store,
      guard,
      userID,
      requestID: "generation2",
    }) === null,
  );
  assert(await availableRewardCredits(store, userID) === 0);
  store.loseUpdate = true;
  await settleGenerationReward({
    store,
    guard,
    reward,
    requestID: "generation1",
    success: false,
  });
  await settleGenerationReward({
    store,
    guard,
    reward,
    requestID: "generation1",
    success: false,
  });
  assert(await availableRewardCredits(store, userID) === 1);
});
Deno.test("successful credit spend cannot be refunded by stale failure or duplicate callback", async () => {
  const f = await earned();
  const reward = await reserveGenerationReward({
    store: f.store,
    guard,
    userID,
    requestID: "generation1",
  });
  assert(reward);
  await settleGenerationReward({
    store: f.store,
    guard,
    reward,
    requestID: "generation1",
    success: true,
  });
  await rejects(() =>
    settleGenerationReward({
      store: f.store,
      guard,
      reward,
      requestID: "generation1",
      success: false,
    })
  );
  await grantVerifiedGenerationReward({
    store: f.store,
    guard,
    callback: f.callback,
    now: new Date(now.getTime() + 3000),
  });
  assert(await availableRewardCredits(f.store, userID) === 0);
});
Deno.test("status has exactly three daily free attempts and separate persistent bonus", async () => {
  const { store } = await earned();
  const quotaStore = { filter: async () => [{ generations_used: 3 }] };
  const status = await generationRewardStatus({
    rewardStore: store,
    quotaStore,
    userID,
    unlimited: false,
    enabled: true,
    adUnit,
    now,
  });
  assert(
    status.free_remaining === 0 && status.bonus_credits === 1 &&
      status.daily_limit === 3,
  );
  assert(status.resets_at === "2026-11-06T00:00:00.000Z");
  const limitless = await generationRewardStatus({
    rewardStore: store,
    quotaStore,
    userID,
    unlimited: true,
    enabled: true,
    adUnit,
    now,
  });
  assert(limitless.free_remaining === null && !limitless.ad_available);
});
Deno.test("disabled rollout never reads new storage or enables advertising", async () => {
  const unavailable = {
    filter: () => {
      throw new Error("must not read");
    },
  };
  const status = await generationRewardStatus({
    rewardStore: unavailable as any,
    quotaStore: unavailable,
    userID,
    unlimited: true,
    enabled: false,
    adUnit,
    now,
  });
  assert(!status.enabled && !status.ad_available);
});
