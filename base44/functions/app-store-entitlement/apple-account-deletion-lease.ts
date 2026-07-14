import {
  type AppleAccountLeaseCandidate,
  canonicalAppleAccountRecord,
  isAppleAccountLeaseActive,
} from "./apple-account-binding.ts";

const ENTITY_PAGE_SIZE = 100;
const MAX_STABILIZATION_PASSES = 8;

// Keep this identical to the bounded lease used by app-store-entitlement. Both
// functions coordinate through the canonical AppStoreAccount row itself.
export const APPLE_ACCOUNT_DELETION_LEASE_MILLISECONDS = 5 * 60 * 1_000;

export type AppleAccountDeletionRecord = AppleAccountLeaseCandidate & {
  app_account_token?: string;
  reservation_state?: string;
};

export type AppleAccountDeletionLease = {
  appAccountToken: string;
  accountID: string;
  ownerUserID: string;
  observedLastUsedAt: string;
  leaseUntil: string;
  isDeletionSentinel: boolean;
};

export type AppleAccountDeletionLeaseErrorCode =
  | "incomplete_binding"
  | "mixed_owners"
  | "active_lease"
  | "cas_contention"
  | "stabilization_failed"
  | "lease_rollback_failed"
  | "precommit_failed";

export class AppleAccountDeletionLeaseError extends Error {
  readonly code: AppleAccountDeletionLeaseErrorCode;
  readonly ambiguousLease?: AppleAccountDeletionLease;

  constructor(
    code: AppleAccountDeletionLeaseErrorCode,
    message: string,
    ambiguousLease?: AppleAccountDeletionLease,
  ) {
    super(message);
    this.name = "AppleAccountDeletionLeaseError";
    this.code = code;
    this.ambiguousLease = ambiguousLease;
  }
}

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function requireTombstone(value: unknown): string {
  const tombstone = clean(value);
  if (!/^deleted:[0-9a-f]{40}$/.test(tombstone)) {
    throw new AppleAccountDeletionLeaseError(
      "incomplete_binding",
      "A valid deleted-account tombstone is required.",
    );
  }
  return tombstone;
}

function canonicalToken(value: unknown): string {
  const token = clean(value).toLowerCase();
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      .test(token)
  ) {
    throw new AppleAccountDeletionLeaseError(
      "incomplete_binding",
      "An App Store account binding has an invalid account token.",
    );
  }
  return token;
}

async function allMatchingRecords<T>(
  store: any,
  filter: Record<string, unknown>,
): Promise<T[]> {
  const records: T[] = [];
  for (let skip = 0;; skip += ENTITY_PAGE_SIZE) {
    const page: T[] = await store.filter(
      filter,
      "created_date",
      ENTITY_PAGE_SIZE,
      skip,
    ) || [];
    records.push(...page);
    if (page.length < ENTITY_PAGE_SIZE) return records;
  }
}

function recordIdentity(record: AppleAccountDeletionRecord): string {
  const id = clean(record.id);
  if (id) return id;
  return [
    clean(record.app_account_token),
    clean(record.user_id),
    clean(record.created_date),
    clean(record.last_used_at),
  ].join(":");
}

async function recordsForDeletionOwners(
  store: any,
  userID: string,
  tombstoneUserID: string,
): Promise<AppleAccountDeletionRecord[]> {
  const [owned, previouslyPrecommitted] = await Promise.all([
    allMatchingRecords<AppleAccountDeletionRecord>(store, {
      user_id: userID,
    }),
    allMatchingRecords<AppleAccountDeletionRecord>(store, {
      user_id: tombstoneUserID,
    }),
  ]);
  const unique = new Map<string, AppleAccountDeletionRecord>();
  for (const record of [...owned, ...previouslyPrecommitted]) {
    unique.set(recordIdentity(record), record);
  }
  return [...unique.values()];
}

function tokensForRecords(
  records: readonly AppleAccountDeletionRecord[],
): string[] {
  return [
    ...new Set(
      records.map((record) => canonicalToken(record.app_account_token)),
    ),
  ].sort();
}

function requireAllowedTokenRecords(
  records: readonly AppleAccountDeletionRecord[],
  appAccountToken: string,
  userID: string,
  tombstoneUserID: string,
): AppleAccountDeletionRecord[] {
  if (records.length === 0) {
    throw new AppleAccountDeletionLeaseError(
      "cas_contention",
      "The App Store account binding changed concurrently.",
    );
  }
  for (const record of records) {
    if (canonicalToken(record.app_account_token) !== appAccountToken) {
      throw new AppleAccountDeletionLeaseError(
        "incomplete_binding",
        "An App Store account binding has inconsistent account tokens.",
      );
    }
    const owner = clean(record.user_id);
    if (owner !== userID && owner !== tombstoneUserID) {
      throw new AppleAccountDeletionLeaseError(
        "mixed_owners",
        "An App Store account token is linked to another account owner.",
      );
    }
  }
  return [...records];
}

async function tokenRecords(
  store: any,
  appAccountToken: string,
  userID: string,
  tombstoneUserID: string,
) {
  return requireAllowedTokenRecords(
    await allMatchingRecords<AppleAccountDeletionRecord>(store, {
      app_account_token: appAccountToken,
    }),
    appAccountToken,
    userID,
    tombstoneUserID,
  );
}

async function hasExactLeaseRecord(input: {
  store: any;
  accountID: string;
  ownerUserID: string;
  leaseUntil: string;
}): Promise<boolean> {
  const records = await allMatchingRecords<AppleAccountDeletionRecord>(
    input.store,
    {
      id: input.accountID,
      user_id: input.ownerUserID,
      last_used_at: input.leaseUntil,
    },
  );
  return records.length === 1;
}

async function acquireOneTokenLease(input: {
  store: any;
  appAccountToken: string;
  userID: string;
  tombstoneUserID: string;
  leaseUntil: string;
  now: Date;
  provisionedSentinelIDs: ReadonlySet<string>;
}): Promise<AppleAccountDeletionLease> {
  const accounts = await tokenRecords(
    input.store,
    input.appAccountToken,
    input.userID,
    input.tombstoneUserID,
  );
  const canonical = canonicalAppleAccountRecord(accounts);
  const accountID = clean(canonical?.id);
  const ownerUserID = clean(canonical?.user_id);
  const observedLastUsedAt = clean(canonical?.last_used_at);
  if (!accountID || !ownerUserID || !observedLastUsedAt) {
    throw new AppleAccountDeletionLeaseError(
      "incomplete_binding",
      "The canonical App Store account binding is incomplete.",
    );
  }

  const isOwnProvisionedSentinel =
    input.provisionedSentinelIDs.has(accountID) &&
    ownerUserID === input.userID &&
    observedLastUsedAt === input.leaseUntil;
  if (
    isAppleAccountLeaseActive(observedLastUsedAt, input.now) &&
    !isOwnProvisionedSentinel
  ) {
    throw new AppleAccountDeletionLeaseError(
      "active_lease",
      "The App Store account binding is being updated.",
    );
  }

  if (isOwnProvisionedSentinel) {
    return {
      appAccountToken: input.appAccountToken,
      accountID,
      ownerUserID,
      observedLastUsedAt,
      leaseUntil: input.leaseUntil,
      isDeletionSentinel: true,
    };
  }

  const candidate: AppleAccountDeletionLease = {
    appAccountToken: input.appAccountToken,
    accountID,
    ownerUserID,
    observedLastUsedAt,
    leaseUntil: input.leaseUntil,
    isDeletionSentinel: false,
  };
  let result: any;
  try {
    result = await input.store.updateMany(
      {
        id: accountID,
        user_id: ownerUserID,
        last_used_at: observedLastUsedAt,
      },
      { $set: { last_used_at: input.leaseUntil } },
    );
  } catch {
    try {
      if (
        await hasExactLeaseRecord({
          store: input.store,
          accountID,
          ownerUserID,
          leaseUntil: input.leaseUntil,
        })
      ) return candidate;
    } catch {
      // Register the ambiguous tuple so outer rollback tries both timestamps.
    }
    throw new AppleAccountDeletionLeaseError(
      "cas_contention",
      "The App Store account lease result could not be reconciled.",
      candidate,
    );
  }
  if (Number(result?.updated) !== 1) {
    throw new AppleAccountDeletionLeaseError(
      "cas_contention",
      "The App Store account binding changed concurrently.",
    );
  }
  return candidate;
}

async function verifyHeldLeases(input: {
  store: any;
  leases: readonly AppleAccountDeletionLease[];
  userID: string;
  tombstoneUserID: string;
}) {
  const current = await recordsForDeletionOwners(
    input.store,
    input.userID,
    input.tombstoneUserID,
  );
  const tokens = tokensForRecords(current);
  const leasedTokens = [...input.leases]
    .map((lease) => lease.appAccountToken)
    .sort();
  if (tokens.join("\n") !== leasedTokens.join("\n")) {
    throw new AppleAccountDeletionLeaseError(
      "cas_contention",
      "The user's App Store account tokens changed during deletion.",
    );
  }

  for (const lease of input.leases) {
    const records = await tokenRecords(
      input.store,
      lease.appAccountToken,
      input.userID,
      input.tombstoneUserID,
    );
    const canonical = canonicalAppleAccountRecord(records);
    if (
      clean(canonical?.id) !== lease.accountID ||
      clean(canonical?.user_id) !== lease.ownerUserID ||
      clean(canonical?.last_used_at) !== lease.leaseUntil
    ) {
      throw new AppleAccountDeletionLeaseError(
        "cas_contention",
        "The canonical App Store account lease changed during deletion.",
      );
    }
  }
}

async function stabilizeTokenLeases(input: {
  store: any;
  leases: AppleAccountDeletionLease[];
  userID: string;
  tombstoneUserID: string;
  leaseUntil: string;
  now: Date;
  provisionedSentinelIDs?: ReadonlySet<string>;
}) {
  const provisionedSentinelIDs = input.provisionedSentinelIDs || new Set();
  for (let pass = 0; pass < MAX_STABILIZATION_PASSES; pass += 1) {
    const records = await recordsForDeletionOwners(
      input.store,
      input.userID,
      input.tombstoneUserID,
    );
    const tokens = tokensForRecords(records);
    const alreadyLeased = new Set(
      input.leases.map((lease) => lease.appAccountToken),
    );
    for (const appAccountToken of tokens) {
      if (alreadyLeased.has(appAccountToken)) continue;
      try {
        const lease = await acquireOneTokenLease({
          store: input.store,
          appAccountToken,
          userID: input.userID,
          tombstoneUserID: input.tombstoneUserID,
          leaseUntil: input.leaseUntil,
          now: input.now,
          provisionedSentinelIDs,
        });
        input.leases.push(lease);
      } catch (error) {
        if (
          error instanceof AppleAccountDeletionLeaseError &&
          error.ambiguousLease
        ) {
          input.leases.push(error.ambiguousLease);
        }
        throw error;
      }
      alreadyLeased.add(appAccountToken);
    }
    input.leases.sort((left, right) =>
      left.appAccountToken.localeCompare(right.appAccountToken)
    );

    try {
      await verifyHeldLeases(input);
      return;
    } catch (error) {
      if (
        !(error instanceof AppleAccountDeletionLeaseError) ||
        error.code !== "cas_contention"
      ) {
        throw error;
      }
    }
  }
  throw new AppleAccountDeletionLeaseError(
    "stabilization_failed",
    "App Store account bindings continued changing during deletion.",
  );
}

/**
 * Restores every canonical row to the live user and releases its lease. Both
 * possible owner states are CAS-tested so an unknown/partial precommit result
 * is recoverable while User still exists.
 */
export async function rollbackAppleAccountDeletionLeases(
  store: any,
  leases: readonly AppleAccountDeletionLease[],
  userIDValue: unknown,
  tombstoneUserIDValue: unknown,
  now = new Date(),
): Promise<void> {
  const userID = clean(userIDValue);
  const tombstoneUserID = requireTombstone(tombstoneUserIDValue);
  const failures: string[] = [];
  for (const lease of [...leases].reverse()) {
    let restored = false;
    const possibleTimestamps = [
      ...new Set([lease.leaseUntil, lease.observedLastUsedAt]),
    ];
    for (const expectedTimestamp of possibleTimestamps) {
      for (const expectedOwner of [tombstoneUserID, userID]) {
        try {
          const result = await store.updateMany(
            {
              id: lease.accountID,
              user_id: expectedOwner,
              last_used_at: expectedTimestamp,
            },
            {
              $set: {
                user_id: userID,
                last_used_at: now.toISOString(),
                reservation_state: "active",
              },
            },
          );
          if (Number(result?.updated) === 1) {
            restored = true;
            break;
          }
        } catch {
          // A request can fail after Base44 applied it. Verify below before
          // declaring rollback failure.
        }
      }
      if (restored) break;
    }
    if (!restored) {
      try {
        const current = await allMatchingRecords<AppleAccountDeletionRecord>(
          store,
          { id: lease.accountID, user_id: userID },
        );
        restored = current.length === 1 &&
          !isAppleAccountLeaseActive(current[0].last_used_at, now);
      } catch {
        restored = false;
      }
    }
    if (!restored) failures.push(lease.accountID);
  }
  if (failures.length) {
    throw new AppleAccountDeletionLeaseError(
      "lease_rollback_failed",
      `Failed to roll back App Store account leases: ${failures.join(", ")}`,
    );
  }
}

/**
 * Establishes a canonical lease for every existing token before destructive
 * cleanup. If no token exists, a real future-leased sentinel is created. It is
 * retained as a normal token on rollback and tombstoned on successful delete.
 */
export async function acquireAppleAccountDeletionLeases(
  store: any,
  userIDValue: unknown,
  tombstoneUserIDValue: unknown,
  now = new Date(),
  randomUUID: () => string = () => crypto.randomUUID(),
): Promise<AppleAccountDeletionLease[]> {
  const userID = clean(userIDValue);
  const tombstoneUserID = requireTombstone(tombstoneUserIDValue);
  if (!userID || userID === tombstoneUserID) {
    throw new AppleAccountDeletionLeaseError(
      "incomplete_binding",
      "A live user id is required to lease App Store account bindings.",
    );
  }

  const leaseUntil = new Date(
    now.getTime() + APPLE_ACCOUNT_DELETION_LEASE_MILLISECONDS,
  ).toISOString();
  const leases: AppleAccountDeletionLease[] = [];
  const provisionedSentinelIDs = new Set<string>();

  try {
    const liveOwned = await allMatchingRecords<AppleAccountDeletionRecord>(
      store,
      { user_id: userID },
    );
    // A crashed precommit can leave only tombstone-owned rows while User is
    // still alive. reserveAccountToken filters by the live user id, so retain
    // one live future-leased sentinel throughout the retry as well.
    if (liveOwned.length === 0) {
      const sentinelToken = canonicalToken(randomUUID());
      const created = await store.create({
        user_id: userID,
        app_account_token: sentinelToken,
        reservation_state: "deletion_sentinel",
        created_at: now.toISOString(),
        last_used_at: leaseUntil,
      });
      const sentinelID = clean(created?.id);
      if (!sentinelID) {
        throw new AppleAccountDeletionLeaseError(
          "incomplete_binding",
          "The App Store deletion sentinel is missing its entity id.",
        );
      }
      provisionedSentinelIDs.add(sentinelID);
    }
    const records = await recordsForDeletionOwners(
      store,
      userID,
      tombstoneUserID,
    );
    if (records.length === 0) {
      throw new AppleAccountDeletionLeaseError(
        "cas_contention",
        "The App Store deletion sentinel was not persisted.",
      );
    }

    await stabilizeTokenLeases({
      store,
      leases,
      userID,
      tombstoneUserID,
      leaseUntil,
      now,
      provisionedSentinelIDs,
    });
    return leases;
  } catch (error) {
    try {
      await rollbackAppleAccountDeletionLeases(
        store,
        leases,
        userID,
        tombstoneUserID,
        now,
      );
    } catch {
      // Preserve the acquisition error. Any unreleased lease is bounded and a
      // retry can resume from this user's deterministic tombstone.
    }
    throw error;
  }
}

/** Renews held leases and absorbs any token created in the initial zero-row race. */
export async function renewAppleAccountDeletionLeases(
  store: any,
  leases: AppleAccountDeletionLease[],
  userIDValue: unknown,
  tombstoneUserIDValue: unknown,
  now = new Date(),
): Promise<void> {
  const userID = clean(userIDValue);
  const tombstoneUserID = requireTombstone(tombstoneUserIDValue);
  const currentFurthestExpiry = leases.reduce(
    (latest, lease) => Math.max(latest, Date.parse(lease.leaseUntil) || 0),
    0,
  );
  const leaseUntil = new Date(Math.max(
    now.getTime() + APPLE_ACCOUNT_DELETION_LEASE_MILLISECONDS,
    currentFurthestExpiry + 1_000,
  )).toISOString();

  for (const lease of leases) {
    const previousLeaseUntil = lease.leaseUntil;
    let result: any;
    try {
      result = await store.updateMany(
        {
          id: lease.accountID,
          user_id: lease.ownerUserID,
          last_used_at: previousLeaseUntil,
        },
        { $set: { last_used_at: leaseUntil } },
      );
    } catch {
      lease.observedLastUsedAt = previousLeaseUntil;
      lease.leaseUntil = leaseUntil;
      try {
        if (
          await hasExactLeaseRecord({
            store,
            accountID: lease.accountID,
            ownerUserID: lease.ownerUserID,
            leaseUntil,
          })
        ) continue;
      } catch {
        // Main rollback now knows both the old and possibly-applied timestamp.
      }
      throw new AppleAccountDeletionLeaseError(
        "cas_contention",
        "An App Store account lease renewal result could not be reconciled.",
      );
    }
    if (Number(result?.updated) !== 1) {
      throw new AppleAccountDeletionLeaseError(
        "cas_contention",
        "An App Store account lease changed before it could be renewed.",
      );
    }
    lease.observedLastUsedAt = previousLeaseUntil;
    lease.leaseUntil = leaseUntil;
  }

  await stabilizeTokenLeases({
    store,
    leases,
    userID,
    tombstoneUserID,
    leaseUntil,
    now,
  });
}

/**
 * Moves every canonical row to the deterministic tombstone without releasing
 * the future lease. Because User still exists, any partial failure can be
 * rolled back and retried safely.
 */
export async function precommitAppleAccountDeletionLeases(
  store: any,
  leases: AppleAccountDeletionLease[],
  userIDValue: unknown,
  tombstoneUserIDValue: unknown,
): Promise<void> {
  const userID = clean(userIDValue);
  const tombstoneUserID = requireTombstone(tombstoneUserIDValue);
  await verifyHeldLeases({ store, leases, userID, tombstoneUserID });

  // Noncanonical rows must already be redacted. This also catches a token row
  // created after the last stabilization pass before User.delete can run.
  for (const lease of leases) {
    const records = await tokenRecords(
      store,
      lease.appAccountToken,
      userID,
      tombstoneUserID,
    );
    for (const record of records) {
      if (clean(record.id) === lease.accountID) continue;
      if (clean(record.user_id) !== tombstoneUserID) {
        throw new AppleAccountDeletionLeaseError(
          "precommit_failed",
          "A noncanonical App Store account was not redacted.",
        );
      }
    }
  }

  // Keep the live sentinel visible to prepare until the final canonical CAS.
  // prepare also checks the tombstone marker, so this ordering is defense in
  // depth rather than the sole guard for the final precommit/User.delete gap.
  const precommitOrder = [...leases].sort((left, right) =>
    Number(left.isDeletionSentinel) - Number(right.isDeletionSentinel) ||
    left.appAccountToken.localeCompare(right.appAccountToken)
  );
  for (const lease of precommitOrder) {
    if (lease.ownerUserID === tombstoneUserID) continue;
    const result = await store.updateMany(
      {
        id: lease.accountID,
        user_id: lease.ownerUserID,
        last_used_at: lease.leaseUntil,
      },
      {
        $set: {
          user_id: tombstoneUserID,
          last_used_at: lease.leaseUntil,
        },
      },
    );
    if (Number(result?.updated) !== 1) {
      throw new AppleAccountDeletionLeaseError(
        "precommit_failed",
        `Failed to precommit App Store account ${lease.accountID}.`,
      );
    }
    lease.ownerUserID = tombstoneUserID;
  }

  await verifyHeldLeases({ store, leases, userID, tombstoneUserID });
  for (const lease of leases) {
    const records = await tokenRecords(
      store,
      lease.appAccountToken,
      userID,
      tombstoneUserID,
    );
    if (records.some((record) => clean(record.user_id) !== tombstoneUserID)) {
      throw new AppleAccountDeletionLeaseError(
        "precommit_failed",
        "App Store account deletion precommit did not converge.",
      );
    }
  }
}

/**
 * Releases already-redacted canonical rows after User.delete. A failure cannot
 * re-expose user identity; it only keeps Apple writers blocked until expiry.
 */
export async function releasePrecommittedAppleAccountLeasesBestEffort(
  store: any,
  leases: readonly AppleAccountDeletionLease[],
  tombstoneUserIDValue: unknown,
  now = new Date(),
): Promise<string[]> {
  const tombstoneUserID = requireTombstone(tombstoneUserIDValue);
  const failures: string[] = [];
  for (const lease of leases) {
    try {
      const result = await store.updateMany(
        {
          id: lease.accountID,
          user_id: tombstoneUserID,
          last_used_at: lease.leaseUntil,
        },
        { $set: { last_used_at: now.toISOString() } },
      );
      if (Number(result?.updated) !== 1) {
        const alreadySafe = await allMatchingRecords<
          AppleAccountDeletionRecord
        >(store, { id: lease.accountID, user_id: tombstoneUserID });
        if (alreadySafe.length !== 1) failures.push(lease.accountID);
      }
    } catch {
      failures.push(lease.accountID);
    }
  }
  return failures;
}

export function leasedCanonicalAppleAccountIDs(
  leases: readonly AppleAccountDeletionLease[],
): ReadonlySet<string> {
  return new Set(leases.map((lease) => lease.accountID));
}
