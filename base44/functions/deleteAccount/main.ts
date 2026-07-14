import { createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import { entitlementRetentionPatch } from "./account-deletion.ts";
import {
  acquireAppleAccountDeletionLeases,
  type AppleAccountDeletionLease,
  AppleAccountDeletionLeaseError,
  commitAppleAccountDeletionLeases,
  leasedCanonicalAppleAccountIDs,
  releaseAppleAccountDeletionLeases,
} from "./apple-account-deletion-lease.ts";

type Entity = Record<string, any>;
type BillingRedactionSnapshot = {
  entitlements: Entity[];
  appStoreAccounts: Entity[];
};

const MAX_CLEANUP_PASSES = 8;

function list(value: unknown): any[] {
  return Array.isArray(value) ? value : [];
}

function clean(value: unknown): string {
  return String(value || "").trim();
}

function errorMessage(error: unknown): string {
  return error instanceof Error
    ? error.message
    : String(error || "Unknown error");
}

async function recordsMatching(
  store: any,
  filter: Record<string, unknown>,
): Promise<Entity[]> {
  const pageSize = 100;
  const records: Entity[] = [];
  for (let skip = 0;; skip += pageSize) {
    const page = await store.filter(
      filter,
      "created_date",
      pageSize,
      skip,
    ) || [];
    records.push(...page);
    if (page.length < pageSize) return records;
  }
}

async function allRecords(store: any): Promise<Entity[]> {
  const pageSize = 100;
  const records: Entity[] = [];
  for (let skip = 0;; skip += pageSize) {
    const page = await store.list("created_date", pageSize, skip) || [];
    records.push(...page);
    if (page.length < pageSize) return records;
  }
}

async function deleteAllMatching(
  store: any,
  filter: Record<string, unknown>,
): Promise<void> {
  for (let pass = 0; pass < MAX_CLEANUP_PASSES; pass += 1) {
    const records = await recordsMatching(store, filter);
    if (!records.length) return;
    for (const record of records) await store.delete(record.id);
  }
  if ((await recordsMatching(store, filter)).length) {
    throw new Error("Account records continued changing during deletion");
  }
}

function roomReferencesEmail(room: Entity, email: string): boolean {
  return room.host_email === email ||
    list(room.players).some((player) => player?.email === email) ||
    list(room.spectators).includes(email) ||
    list(room.ready_players).includes(email) ||
    list(room.cards_read).includes(email) ||
    list(room.vote_requests).includes(email) ||
    list(room.detective_votes).some((vote) =>
      vote?.voter_email === email || vote?.voted_for_email === email
    ) ||
    list(room.player_feedback).some((feedback) => feedback?.email === email) ||
    list(room.eliminated_emails).includes(email) ||
    [
      room.spy_email,
      room.current_asker_email,
      room.current_answerer_email,
      room.roulette_target_email,
    ].includes(email);
}

async function deleteReferencedRooms(store: any, email: string): Promise<void> {
  for (let pass = 0; pass < MAX_CLEANUP_PASSES; pass += 1) {
    const matching = (await allRecords(store)).filter((room) =>
      roomReferencesEmail(room, email)
    );
    if (!matching.length) return;
    // GameRoom records are ephemeral shared sessions. Deleting a matching room
    // avoids overwriting another player's concurrent join/vote with a stale
    // array snapshot while guaranteeing that the deleted email is gone.
    for (const room of matching) await store.delete(room.id);
  }
  if (
    (await allRecords(store)).some((room) => roomReferencesEmail(room, email))
  ) {
    throw new Error("Room references continued changing during deletion");
  }
}

async function restoreBillingIdentity(
  base44: any,
  user: Entity,
  snapshot: BillingRedactionSnapshot,
  retentionPatch: { user_id: string; user_email: string },
  appleLeases: readonly AppleAccountDeletionLease[],
): Promise<void> {
  const entitlementStore = base44.asServiceRole.entities.Entitlement;
  const accountStore = base44.asServiceRole.entities.AppStoreAccount;
  const leasedCanonicalIDs = leasedCanonicalAppleAccountIDs(appleLeases);
  const failures: string[] = [];

  for (const entitlement of snapshot.entitlements) {
    try {
      const patch: Entity = { user_id: user.id };
      const email = clean(entitlement.user_email) || clean(user.email);
      if (email) patch.user_email = email;
      await entitlementStore.update(entitlement.id, patch);
    } catch (error) {
      failures.push(`entitlement:${entitlement.id}:${errorMessage(error)}`);
    }
  }
  for (const account of snapshot.appStoreAccounts) {
    // Canonical Apple rows are restored only by releasing their exact CAS
    // lease. Never issue an unconditional update against those coordination
    // records.
    if (leasedCanonicalIDs.has(clean(account.id))) continue;
    try {
      const restored = await accountStore.updateMany(
        { id: account.id, user_id: retentionPatch.user_id },
        { $set: { user_id: user.id } },
      );
      if (Number(restored?.updated) === 1) continue;

      // A redaction failure may occur before this particular row was changed.
      const alreadyOwned = await recordsMatching(accountStore, {
        id: account.id,
        user_id: user.id,
      });
      if (alreadyOwned.length !== 1) {
        throw new Error("App Store account ownership changed concurrently");
      }
    } catch (error) {
      failures.push(`app-store-account:${account.id}:${errorMessage(error)}`);
    }
  }
  if (failures.length) {
    throw new Error(`Billing identity rollback failed: ${failures.join("; ")}`);
  }
}

async function snapshotBillingIdentity(
  base44: any,
  user: Entity,
): Promise<BillingRedactionSnapshot> {
  const entitlementStore = base44.asServiceRole.entities.Entitlement;
  const accountStore = base44.asServiceRole.entities.AppStoreAccount;
  return {
    entitlements: await recordsMatching(entitlementStore, { user_id: user.id }),
    appStoreAccounts: await recordsMatching(accountStore, { user_id: user.id }),
  };
}

async function redactBillingIdentity(
  base44: any,
  user: Entity,
  snapshot: BillingRedactionSnapshot,
  retentionPatch: { user_id: string; user_email: string },
  appleLeases: readonly AppleAccountDeletionLease[],
): Promise<void> {
  const entitlementStore = base44.asServiceRole.entities.Entitlement;
  const accountStore = base44.asServiceRole.entities.AppStoreAccount;
  const leasedCanonicalIDs = leasedCanonicalAppleAccountIDs(appleLeases);
  const snapshotAccountIDs = new Set(
    snapshot.appStoreAccounts.map((account) => clean(account.id)),
  );
  for (const lease of appleLeases) {
    if (!snapshotAccountIDs.has(lease.accountID)) {
      throw new Error(
        "A leased App Store account disappeared before redaction",
      );
    }
  }

  for (const entitlement of snapshot.entitlements) {
    await entitlementStore.update(entitlement.id, retentionPatch);
  }
  for (const account of snapshot.appStoreAccounts) {
    if (leasedCanonicalIDs.has(clean(account.id))) continue;
    const redacted = await accountStore.updateMany(
      { id: account.id, user_id: user.id },
      { $set: { user_id: retentionPatch.user_id } },
    );
    if (Number(redacted?.updated) !== 1) {
      throw new Error(
        `App Store account ${clean(account.id)} changed during redaction`,
      );
    }
  }
}

async function rollbackBillingIdentityAndAppleLeases(
  base44: any,
  user: Entity,
  snapshot: BillingRedactionSnapshot | undefined,
  retentionPatch: { user_id: string; user_email: string },
  appleLeases: readonly AppleAccountDeletionLease[],
): Promise<void> {
  const failures: string[] = [];
  if (snapshot) {
    try {
      await restoreBillingIdentity(
        base44,
        user,
        snapshot,
        retentionPatch,
        appleLeases,
      );
    } catch (error) {
      failures.push(errorMessage(error));
    }
  }
  try {
    await releaseAppleAccountDeletionLeases(
      base44.asServiceRole.entities.AppStoreAccount,
      appleLeases,
    );
  } catch (error) {
    failures.push(errorMessage(error));
  }
  if (failures.length) {
    throw new Error(`Account deletion rollback failed: ${failures.join("; ")}`);
  }
}

function appleLeaseErrorStatus(error: unknown): number {
  if (!(error instanceof AppleAccountDeletionLeaseError)) return 500;
  if (error.code === "mixed_owners") return 409;
  if (error.code === "active_lease" || error.code === "cas_contention") {
    return 503;
  }
  return 500;
}

Deno.serve(async (req) => {
  try {
    const base44 = createClientFromRequest(req);
    const user = await base44.auth.me();

    if (!user) {
      return Response.json({ error: "Unauthorized" }, { status: 401 });
    }

    const userEmail = clean(user.email);
    if (!clean(user.id) || !userEmail) {
      console.error("deleteAccount missing stable user identity");
      return Response.json({ error: "Account identity is incomplete" }, {
        status: 500,
      });
    }

    // Delete account-owned/shared content first. Each helper repeatedly queries
    // from the start so concurrent inserts cannot hide behind a shifting skip
    // offset. Game rooms are ephemeral, so deleting a referenced room is safer
    // than overwriting another player's concurrent update with a stale patch.
    try {
      await deleteAllMatching(base44.asServiceRole.entities.GameHistory, {
        player_email: userEmail,
      });
      await deleteAllMatching(base44.asServiceRole.entities.WordPack, {
        owner_email: userEmail,
      });
      await deleteAllMatching(base44.asServiceRole.entities.Friendship, {
        requester_id: user.id,
      });
      await deleteAllMatching(base44.asServiceRole.entities.Friendship, {
        addressee_id: user.id,
      });
      await deleteReferencedRooms(
        base44.asServiceRole.entities.GameRoom,
        userEmail,
      );
    } catch (e) {
      console.error("account content cleanup failed", errorMessage(e));
      return Response.json({ error: "Failed to delete account data" }, {
        status: 500,
      });
    }

    // Usage buckets are operational data. Delete them only after account
    // content has been removed so a retry never loses the records needed to
    // identify unfinished content cleanup.
    try {
      await deleteAllMatching(
        base44.asServiceRole.entities.AiGenerationUsage,
        { user_id: user.id },
      );
      // Remove quota rows created by the retired pre-user_id implementation.
      // Base44 keeps the creator identity in its created_by_id system field.
      await deleteAllMatching(
        base44.asServiceRole.entities.AiGenerationQuota,
        { created_by_id: user.id },
      );
    } catch (e) {
      console.error("AI usage cleanup failed", errorMessage(e));
      return Response.json(
        { error: "Failed to delete account usage records" },
        { status: 500 },
      );
    }

    // Join the same deterministic AppStoreAccount CAS lease used by Apple
    // purchase sync and notifications. Every canonical token row remains
    // leased until User.delete either succeeds or is rolled back.
    const retentionPatch = await entitlementRetentionPatch(user.id);
    const accountStore = base44.asServiceRole.entities.AppStoreAccount;
    let appleLeases: AppleAccountDeletionLease[];
    try {
      appleLeases = await acquireAppleAccountDeletionLeases(
        accountStore,
        user.id,
      );
    } catch (e) {
      console.error("Apple account deletion lease failed", errorMessage(e));
      return Response.json({
        error: e instanceof AppleAccountDeletionLeaseError &&
            e.code === "active_lease"
          ? "App Store billing is updating. Retry account deletion shortly."
          : "Failed to lock retained App Store billing records",
      }, { status: appleLeaseErrorStatus(e) });
    }

    // Provider transaction records and Apple token reservations may need to
    // survive for fraud prevention, refunds, chargebacks, future provider
    // notifications, and legal obligations. Redact entitlements and only
    // noncanonical AppStoreAccount rows while canonical rows stay leased.
    let billingSnapshot: BillingRedactionSnapshot | undefined;
    try {
      billingSnapshot = await snapshotBillingIdentity(base44, user);
      await redactBillingIdentity(
        base44,
        user,
        billingSnapshot,
        retentionPatch,
        appleLeases,
      );
    } catch (e) {
      console.error("billing identity redaction failed", errorMessage(e));
      try {
        await rollbackBillingIdentityAndAppleLeases(
          base44,
          user,
          billingSnapshot,
          retentionPatch,
          appleLeases,
        );
      } catch (rollbackError) {
        console.error(
          "billing identity rollback after redaction failure failed",
          errorMessage(rollbackError),
        );
      }
      return Response.json({
        error: "Failed to redact retained billing records",
      }, { status: 500 });
    }

    try {
      await base44.asServiceRole.entities.User.delete(user.id);
    } catch (e) {
      console.error("user delete failed", errorMessage(e));
      try {
        await rollbackBillingIdentityAndAppleLeases(
          base44,
          user,
          billingSnapshot,
          retentionPatch,
          appleLeases,
        );
      } catch (rollbackError) {
        console.error(
          "billing identity rollback after user delete failure failed",
          errorMessage(rollbackError),
        );
      }
      return Response.json({ error: "Failed to delete user record" }, {
        status: 500,
      });
    }

    // User.delete is the deletion commit point. Tombstone and release every
    // leased canonical row last, using the exact owner + timestamp CAS tuple.
    try {
      await commitAppleAccountDeletionLeases(
        accountStore,
        appleLeases,
        retentionPatch.user_id,
      );
    } catch (e) {
      console.error(
        "canonical App Store account deletion commit failed",
        errorMessage(e),
      );
      return Response.json({
        error: "Account deleted, but retained App Store records need repair",
      }, { status: 500 });
    }

    return Response.json({ success: true });
  } catch (error) {
    console.error(
      "deleteAccount fatal",
      errorMessage(error),
      error instanceof Error ? error.stack : undefined,
    );
    return Response.json({ error: errorMessage(error) || "Internal error" }, {
      status: 500,
    });
  }
});
