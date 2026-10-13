const DELETED_ACCOUNT_TOMBSTONE = /^deleted:[0-9a-f]{40}$/;

export type AppleAccountBindingDecision =
  | { kind: "missing" }
  | { kind: "same_owner" }
  | { kind: "rebind_deleted"; tombstoneUserID: string }
  | { kind: "conflict" };

export type AppleNotificationOwnerDecision =
  | { kind: "missing" }
  | { kind: "single_owner"; userID: string }
  | { kind: "conflict" };

export type AppleAccountLeaseCandidate = {
  id?: string;
  user_id?: string;
  last_used_at?: string;
  created_date?: string;
};

function ownerID(value: unknown): string {
  return String(value ?? "").trim();
}

export function isDeletedAccountTombstone(value: unknown): boolean {
  return DELETED_ACCOUNT_TOMBSTONE.test(ownerID(value));
}

/**
 * Makes a deterministic ownership decision across every durable
 * AppStoreAccount row for one appAccountToken.
 *
 * A mixture of the target user and one tombstone is an expected partial-retry
 * state: entitlement rows are migrated before AppStoreAccount rows. Any live
 * third-party owner or multiple tombstones remains a hard conflict.
 */
export function decideAppleAccountBinding(
  accountUserIDs: readonly unknown[],
  authenticatedUserIDValue: unknown,
): AppleAccountBindingDecision {
  const authenticatedUserID = ownerID(authenticatedUserIDValue);
  if (!authenticatedUserID || accountUserIDs.length === 0) {
    return { kind: "missing" };
  }

  const owners = accountUserIDs.map(ownerID);
  if (owners.some((owner) => !owner)) {
    return { kind: "missing" };
  }

  const otherOwners = [
    ...new Set(
      owners.filter((owner) => owner !== authenticatedUserID),
    ),
  ];
  if (otherOwners.length === 0) {
    return { kind: "same_owner" };
  }
  if (
    otherOwners.length === 1 &&
    isDeletedAccountTombstone(otherOwners[0])
  ) {
    return {
      kind: "rebind_deleted",
      tombstoneUserID: otherOwners[0],
    };
  }
  return { kind: "conflict" };
}

export function canRebindAppleEntitlementOwner(
  recordUserIDValue: unknown,
  authenticatedUserIDValue: unknown,
  tombstoneUserIDValue: unknown,
): boolean {
  const recordUserID = ownerID(recordUserIDValue);
  const authenticatedUserID = ownerID(authenticatedUserIDValue);
  const tombstoneUserID = ownerID(tombstoneUserIDValue);
  return Boolean(
    recordUserID &&
      authenticatedUserID &&
      isDeletedAccountTombstone(tombstoneUserID) &&
      (recordUserID === authenticatedUserID ||
        recordUserID === tombstoneUserID),
  );
}

/**
 * Re-validates the binding after the canonical Apple API call. A normal sync
 * cannot turn into a deleted-account reclaim mid-flight, while an already
 * authorized reclaim may observe its own successful concurrent retry.
 */
export function canContinueAppleAccountBinding(
  initial: AppleAccountBindingDecision,
  current: AppleAccountBindingDecision,
): boolean {
  if (initial.kind === "same_owner") {
    return current.kind === "same_owner";
  }
  if (initial.kind !== "rebind_deleted") return false;
  return current.kind === "same_owner" ||
    (current.kind === "rebind_deleted" &&
      current.tombstoneUserID === initial.tombstoneUserID);
}

export function decideAppleNotificationOwner(
  accountUserIDs: readonly unknown[],
): AppleNotificationOwnerDecision {
  if (accountUserIDs.length === 0) return { kind: "missing" };
  const owners = accountUserIDs.map(ownerID);
  if (owners.some((owner) => !owner)) return { kind: "missing" };
  const uniqueOwners = [...new Set(owners)];
  return uniqueOwners.length === 1
    ? { kind: "single_owner", userID: uniqueOwners[0] }
    : { kind: "conflict" };
}

export function canonicalAppleAccountRecord<
  T extends AppleAccountLeaseCandidate,
>(records: readonly T[]): T | undefined {
  return [...records].sort((left, right) => {
    const dateOrder = String(left.created_date || "").localeCompare(
      String(right.created_date || ""),
    );
    if (dateOrder !== 0) return dateOrder;
    return String(left.id || "").localeCompare(String(right.id || ""));
  })[0];
}

export function isAppleAccountLeaseActive(
  lastUsedAtValue: unknown,
  now = new Date(),
  clockSkewMilliseconds = 5_000,
): boolean {
  const leaseUntil = Date.parse(String(lastUsedAtValue || ""));
  return Number.isFinite(leaseUntil) &&
    leaseUntil > now.getTime() + clockSkewMilliseconds;
}
