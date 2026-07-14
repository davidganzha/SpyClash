import {
  canContinueAppleAccountBinding,
  canonicalAppleAccountRecord,
  canRebindAppleEntitlementOwner,
  decideAppleAccountBinding,
  decideAppleNotificationOwner,
  isAppleAccountLeaseActive,
  isDeletedAccountTombstone,
} from "./apple-account-binding.ts";
import { entitlementRetentionPatch } from "../deleteAccount/account-deletion.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

const TOMBSTONE_A = `deleted:${"a".repeat(40)}`;
const TOMBSTONE_B = `deleted:${"b".repeat(40)}`;

Deno.test("Apple binding recognizes the exact deleteAccount tombstone format", async () => {
  const retained = await entitlementRetentionPatch("base44-user-123");
  assert(
    isDeletedAccountTombstone(retained.user_id),
    "deleteAccount generated a tombstone that Apple restore would reject",
  );
  assert(
    !isDeletedAccountTombstone(`deleted:${"a".repeat(39)}`),
    "short tombstone was accepted",
  );
  assert(
    !isDeletedAccountTombstone(`deleted:${"A".repeat(40)}`),
    "uppercase tombstone was accepted",
  );
  assert(
    !isDeletedAccountTombstone("user-live"),
    "live owner was treated as deleted",
  );
});

Deno.test("Apple binding keeps the current owner and rejects missing bindings", () => {
  assert(
    decideAppleAccountBinding(["user-new"], "user-new").kind === "same_owner",
    "current owner was not accepted",
  );
  assert(
    decideAppleAccountBinding([], "user-new").kind === "missing",
    "missing AppStoreAccount was not rejected",
  );
  assert(
    decideAppleAccountBinding([""], "user-new").kind === "missing",
    "ownerless AppStoreAccount was not rejected",
  );
});

Deno.test("Apple binding permits one deleted owner including partial retries", () => {
  const initial = decideAppleAccountBinding([TOMBSTONE_A], "user-new");
  assert(
    initial.kind === "rebind_deleted",
    "deleted owner was not reclaimable",
  );
  assert(
    initial.kind === "rebind_deleted" &&
      initial.tombstoneUserID === TOMBSTONE_A,
    "wrong tombstone was selected",
  );

  const partial = decideAppleAccountBinding(
    ["user-new", TOMBSTONE_A],
    "user-new",
  );
  assert(
    partial.kind === "rebind_deleted",
    "partial AppStoreAccount retry was not resumable",
  );
});

Deno.test("Apple binding rejects live third parties and ambiguous tombstones", () => {
  assert(
    decideAppleAccountBinding(["user-existing"], "user-new").kind ===
      "conflict",
    "live third-party owner was reclaimable",
  );
  assert(
    decideAppleAccountBinding([TOMBSTONE_A, TOMBSTONE_B], "user-new")
      .kind === "conflict",
    "multiple deleted owners were treated as one account",
  );
  assert(
    decideAppleAccountBinding(["user-new", "user-existing"], "user-new")
      .kind === "conflict",
    "partial update with a live third party was accepted",
  );
});

Deno.test("Apple entitlement migration accepts only target or selected tombstone", () => {
  assert(
    canRebindAppleEntitlementOwner(TOMBSTONE_A, "user-new", TOMBSTONE_A),
    "selected tombstone was rejected",
  );
  assert(
    canRebindAppleEntitlementOwner("user-new", "user-new", TOMBSTONE_A),
    "idempotently migrated row was rejected",
  );
  assert(
    !canRebindAppleEntitlementOwner("user-existing", "user-new", TOMBSTONE_A),
    "live third-party entitlement was accepted",
  );
  assert(
    !canRebindAppleEntitlementOwner(TOMBSTONE_B, "user-new", TOMBSTONE_A),
    "different tombstone entitlement was accepted",
  );
});

Deno.test("Apple binding transition permits retries but not deletion races", () => {
  const sameOwner = decideAppleAccountBinding(["user-new"], "user-new");
  const deletedA = decideAppleAccountBinding([TOMBSTONE_A], "user-new");
  const deletedB = decideAppleAccountBinding([TOMBSTONE_B], "user-new");

  assert(
    canContinueAppleAccountBinding(deletedA, sameOwner),
    "completed concurrent retry was not accepted",
  );
  assert(
    canContinueAppleAccountBinding(deletedA, deletedA),
    "same tombstone retry was not accepted",
  );
  assert(
    !canContinueAppleAccountBinding(deletedA, deletedB),
    "restore switched to a different deleted owner",
  );
  assert(
    !canContinueAppleAccountBinding(sameOwner, deletedA),
    "ordinary sync reclaimed a tombstone created by concurrent deletion",
  );
});

Deno.test("Apple notification requires one unambiguous durable owner", () => {
  const same = decideAppleNotificationOwner([TOMBSTONE_A, TOMBSTONE_A]);
  assert(
    same.kind === "single_owner" && same.userID === TOMBSTONE_A,
    "duplicate rows for one owner were not accepted",
  );
  assert(
    decideAppleNotificationOwner([TOMBSTONE_A, "user-new"]).kind ===
      "conflict",
    "notification accepted a partially migrated binding",
  );
  assert(
    decideAppleNotificationOwner([]).kind === "missing",
    "notification accepted a missing binding",
  );
});

Deno.test("Apple lease chooses one deterministic CAS row and detects active leases", () => {
  const timestamp = "2026-07-14T12:00:00.000Z";
  const canonical = canonicalAppleAccountRecord([
    { id: "row-b", created_date: timestamp },
    { id: "row-a", created_date: timestamp },
  ]);
  assert(canonical?.id === "row-a", "lease CAS row was not deterministic");

  const now = new Date("2026-07-14T12:00:00.000Z");
  assert(
    isAppleAccountLeaseActive("2026-07-14T12:05:00.000Z", now),
    "future lease was not active",
  );
  assert(
    !isAppleAccountLeaseActive("2026-07-14T11:59:59.000Z", now),
    "expired lease remained active",
  );
});
