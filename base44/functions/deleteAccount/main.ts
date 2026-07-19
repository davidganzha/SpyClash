import { createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import { entitlementRetentionPatch } from "./account-deletion.ts";
import {
  acquireAppleAccountDeletionLeases,
  type AppleAccountDeletionLease,
  AppleAccountDeletionLeaseError,
  leasedCanonicalAppleAccountIDs,
  precommitAppleAccountDeletionLeases,
  releasePrecommittedAppleAccountLeasesBestEffort,
  renewAppleAccountDeletionLeases,
  rollbackAppleAccountDeletionLeases,
} from "./apple-account-deletion-lease.ts";
import { deleteUserRecord, UserDeletionFailure } from "./user-deletion.ts";
import { deleteAccountRelationshipRecords } from "./relationship-cleanup.ts";
import { deletionFailureDisposition } from "./deletion-state-machine.ts";
import {
  acquireBillingDeletionMarker,
  assertBillingDeletionMarker,
  type BillingIdentityLease,
  BillingIdentityLifecycleError,
  releaseBillingDeletionMarker,
  renewBillingDeletionMarker,
} from "./billing-identity-lifecycle.ts";

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
      let restored = false;
      for (const expectedOwner of [retentionPatch.user_id, user.id]) {
        const result = await entitlementStore.updateMany(
          { id: entitlement.id, user_id: expectedOwner },
          {
            $set: {
              user_id: user.id,
              user_email: clean(user.email),
              write_revision: crypto.randomUUID(),
            },
          },
        );
        if (Number(result?.updated) === 1) {
          restored = true;
          break;
        }
      }
      if (!restored) {
        const alreadyRestored = await recordsMatching(entitlementStore, {
          id: entitlement.id,
          user_id: user.id,
        });
        restored = alreadyRestored.length === 1 &&
          clean(alreadyRestored[0].user_email) === clean(user.email);
      }
      if (!restored) {
        throw new Error("Entitlement ownership changed concurrently");
      }
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
      let restored = false;
      for (const expectedOwner of [retentionPatch.user_id, user.id]) {
        const result = await accountStore.updateMany(
          { id: account.id, user_id: expectedOwner },
          {
            $set: {
              user_id: user.id,
              reservation_state: "active",
            },
          },
        );
        if (Number(result?.updated) === 1) {
          restored = true;
          break;
        }
      }
      if (!restored) {
        const alreadyRestored = await recordsMatching(accountStore, {
          id: account.id,
          user_id: user.id,
        });
        restored = alreadyRestored.length === 1;
      }
      if (!restored) {
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
  tombstoneUserID: string,
): Promise<BillingRedactionSnapshot> {
  const entitlementStore = base44.asServiceRole.entities.Entitlement;
  const accountStore = base44.asServiceRole.entities.AppStoreAccount;
  const merge = (records: Entity[]) => {
    const unique = new Map<string, Entity>();
    for (const record of records) {
      unique.set(clean(record.id), record);
    }
    return [...unique.values()];
  };
  return {
    entitlements: merge([
      ...await recordsMatching(entitlementStore, { user_id: user.id }),
      ...await recordsMatching(entitlementStore, {
        user_id: tombstoneUserID,
      }),
    ]),
    appStoreAccounts: merge([
      ...await recordsMatching(accountStore, { user_id: user.id }),
      ...await recordsMatching(accountStore, { user_id: tombstoneUserID }),
    ]),
  };
}

function mergeBillingSnapshots(
  current: BillingRedactionSnapshot,
  next: BillingRedactionSnapshot,
): BillingRedactionSnapshot {
  const merge = (records: Entity[]) => {
    const unique = new Map<string, Entity>();
    for (const record of records) unique.set(clean(record.id), record);
    return [...unique.values()];
  };
  return {
    entitlements: merge([...current.entitlements, ...next.entitlements]),
    appStoreAccounts: merge([
      ...current.appStoreAccounts,
      ...next.appStoreAccounts,
    ]),
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
    const redacted = await entitlementStore.updateMany(
      { id: entitlement.id, user_id: user.id },
      {
        $set: {
          ...retentionPatch,
          write_revision: crypto.randomUUID(),
        },
      },
    );
    if (Number(redacted?.updated) === 1) continue;
    const alreadyRedacted = await recordsMatching(entitlementStore, {
      id: entitlement.id,
      user_id: retentionPatch.user_id,
    });
    if (alreadyRedacted.length !== 1) {
      throw new Error(
        `Entitlement ${clean(entitlement.id)} changed during redaction`,
      );
    }
  }
  for (const account of snapshot.appStoreAccounts) {
    if (leasedCanonicalIDs.has(clean(account.id))) continue;
    const redacted = await accountStore.updateMany(
      { id: account.id, user_id: user.id },
      { $set: { user_id: retentionPatch.user_id } },
    );
    if (Number(redacted?.updated) === 1) continue;
    const alreadyRedacted = await recordsMatching(accountStore, {
      id: account.id,
      user_id: retentionPatch.user_id,
    });
    if (alreadyRedacted.length !== 1) {
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
  billingDeletionMarker: BillingIdentityLease,
): Promise<void> {
  const lifecycleStore = base44.asServiceRole.entities.BillingIdentityLifecycle;
  // Never restore raw billing identity after another deletion invocation has
  // taken over this marker. A failed assertion intentionally leaves the
  // retained rows tombstoned for a later retry.
  await renewBillingDeletionMarker(lifecycleStore, billingDeletionMarker);
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
    await rollbackAppleAccountDeletionLeases(
      base44.asServiceRole.entities.AppStoreAccount,
      appleLeases,
      user.id,
      retentionPatch.user_id,
    );
  } catch (error) {
    failures.push(errorMessage(error));
  }
  if (failures.length) {
    throw new Error(`Account deletion rollback failed: ${failures.join("; ")}`);
  }
  await releaseBillingDeletionMarker(lifecycleStore, billingDeletionMarker);
}

function appleLeaseErrorStatus(error: unknown): number {
  if (error instanceof BillingIdentityLifecycleError) {
    return error.code === "incomplete_state" ? 500 : 503;
  }
  if (!(error instanceof AppleAccountDeletionLeaseError)) return 500;
  if (error.code === "mixed_owners") return 409;
  if (
    error.code === "active_lease" || error.code === "cas_contention" ||
    error.code === "stabilization_failed"
  ) {
    return 503;
  }
  return 500;
}

async function renewDeletionCoordination(input: {
  lifecycleStore: any;
  billingDeletionMarker: BillingIdentityLease;
  accountStore: any;
  appleLeases: AppleAccountDeletionLease[];
  userID: string;
  tombstoneUserID: string;
}) {
  await renewBillingDeletionMarker(
    input.lifecycleStore,
    input.billingDeletionMarker,
  );
  await renewAppleAccountDeletionLeases(
    input.accountStore,
    input.appleLeases,
    input.userID,
    input.tombstoneUserID,
  );
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

    // The admin-only lifecycle row is keyed by a one-way subject hash. Acquire
    // its deleting marker before any content cleanup so every mediated writer
    // either finishes under its exact lease or deletion remains untouched.
    const retentionPatch = await entitlementRetentionPatch(user.id);
    const userStore = base44.asServiceRole.entities.User;
    const billingLifecycleStore =
      base44.asServiceRole.entities.BillingIdentityLifecycle;
    let billingDeletionMarker: BillingIdentityLease;
    try {
      billingDeletionMarker = await acquireBillingDeletionMarker(
        billingLifecycleStore,
        user.id,
      );
    } catch (e) {
      console.error(
        "billing identity deletion preflight failed",
        errorMessage(e),
      );
      return Response.json({
        error: "Billing identity is updating. Retry account deletion shortly.",
      }, { status: appleLeaseErrorStatus(e) });
    }

    // Lock Apple billing before deleting any content. A live provider writer or
    // a foreign/mixed binding must leave the still-live account untouched. The
    // zero-binding path creates a future-leased real AppStoreAccount sentinel,
    // which also closes prepare's pre-check/create race.
    const accountStore = base44.asServiceRole.entities.AppStoreAccount;
    let appleLeases: AppleAccountDeletionLease[];
    try {
      appleLeases = await acquireAppleAccountDeletionLeases(
        accountStore,
        user.id,
        retentionPatch.user_id,
      );
    } catch (e) {
      console.error("Apple account deletion preflight failed", errorMessage(e));
      try {
        await releaseBillingDeletionMarker(
          billingLifecycleStore,
          billingDeletionMarker,
        );
      } catch (releaseError) {
        console.error(
          "billing identity marker release after Apple preflight failed",
          errorMessage(releaseError),
        );
      }
      return Response.json({
        error: e instanceof AppleAccountDeletionLeaseError &&
            e.code === "active_lease"
          ? "App Store billing is updating. Retry account deletion shortly."
          : "Failed to lock retained App Store billing records",
      }, { status: appleLeaseErrorStatus(e) });
    }

    let billingSnapshot: BillingRedactionSnapshot | undefined;
    try {
      billingSnapshot = await snapshotBillingIdentity(
        base44,
        user,
        retentionPatch.user_id,
      );
    } catch (e) {
      console.error("billing identity snapshot failed", errorMessage(e));
      try {
        await rollbackBillingIdentityAndAppleLeases(
          base44,
          user,
          undefined,
          retentionPatch,
          appleLeases,
          billingDeletionMarker,
        );
      } catch (rollbackError) {
        console.error(
          "Apple lease rollback after snapshot failure failed",
          errorMessage(rollbackError),
        );
      }
      return Response.json({ error: "Failed to prepare account deletion" }, {
        status: 500,
      });
    }

    let irreversibleCleanupStarted = false;
    try {
      // Each helper repeatedly queries from the start so concurrent inserts
      // cannot hide behind a shifting skip offset.
      irreversibleCleanupStarted = true;
      await deleteAllMatching(base44.asServiceRole.entities.GameHistory, {
        player_email: userEmail,
      });
      await renewDeletionCoordination({
        lifecycleStore: billingLifecycleStore,
        billingDeletionMarker,
        accountStore,
        appleLeases,
        userID: user.id,
        tombstoneUserID: retentionPatch.user_id,
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
      await deleteAccountRelationshipRecords({
        profileCommentStore: base44.asServiceRole.entities.ProfileComment,
        roomInviteStore: base44.asServiceRole.entities.RoomInvite,
        membershipGrantStore: base44.asServiceRole.entities.MembershipGrant,
        reportStore: base44.asServiceRole.entities.CommunityReport,
        wordPackStore: base44.asServiceRole.entities.WordPack,
        gameHistoryStore: base44.asServiceRole.entities.GameHistory,
        pushDeviceStore: base44.asServiceRole.entities.PushDeviceRegistration,
        liveActivityStore:
          base44.asServiceRole.entities.LiveActivityRegistration,
        pushEventStore: base44.asServiceRole.entities.PushNotificationEvent,
        userID: user.id,
        tombstoneUserID: retentionPatch.user_id,
      });
      await renewDeletionCoordination({
        lifecycleStore: billingLifecycleStore,
        billingDeletionMarker,
        accountStore,
        appleLeases,
        userID: user.id,
        tombstoneUserID: retentionPatch.user_id,
      });

      // GameRoom records are ephemeral shared sessions. Deleting a referenced
      // room avoids a stale array write against another player's live session.
      await deleteReferencedRooms(
        base44.asServiceRole.entities.GameRoom,
        userEmail,
      );
      await renewDeletionCoordination({
        lifecycleStore: billingLifecycleStore,
        billingDeletionMarker,
        accountStore,
        appleLeases,
        userID: user.id,
        tombstoneUserID: retentionPatch.user_id,
      });

      // Usage buckets are operational data. Delete them only after account
      // content so a retry retains evidence of unfinished content cleanup.
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
      await renewDeletionCoordination({
        lifecycleStore: billingLifecycleStore,
        billingDeletionMarker,
        accountStore,
        appleLeases,
        userID: user.id,
        tombstoneUserID: retentionPatch.user_id,
      });

      // A prepare request that began in the zero-row window may have created a
      // second token before observing the sentinel. Renewal absorbs it; the
      // refreshed snapshot ensures every noncanonical row is also redacted.
      billingSnapshot = mergeBillingSnapshots(
        billingSnapshot,
        await snapshotBillingIdentity(
          base44,
          user,
          retentionPatch.user_id,
        ),
      );
      await redactBillingIdentity(
        base44,
        user,
        billingSnapshot,
        retentionPatch,
        appleLeases,
      );
      await renewDeletionCoordination({
        lifecycleStore: billingLifecycleStore,
        billingDeletionMarker,
        accountStore,
        appleLeases,
        userID: user.id,
        tombstoneUserID: retentionPatch.user_id,
      });
      billingSnapshot = mergeBillingSnapshots(
        billingSnapshot,
        await snapshotBillingIdentity(
          base44,
          user,
          retentionPatch.user_id,
        ),
      );
      await redactBillingIdentity(
        base44,
        user,
        billingSnapshot,
        retentionPatch,
        appleLeases,
      );

      await renewBillingDeletionMarker(
        billingLifecycleStore,
        billingDeletionMarker,
      );

      // Canonical rows become tombstones while their future leases remain
      // active. Any multi-token partial failure is still rollback-safe because
      // User has not been deleted yet.
      await precommitAppleAccountDeletionLeases(
        accountStore,
        appleLeases,
        user.id,
        retentionPatch.user_id,
      );
      await assertBillingDeletionMarker(
        billingLifecycleStore,
        billingDeletionMarker,
      );
    } catch (e) {
      console.error("account deletion transaction failed", errorMessage(e));
      const disposition = deletionFailureDisposition(
        irreversibleCleanupStarted,
      );
      if (disposition === "rollback_before_cleanup") {
        try {
          await rollbackBillingIdentityAndAppleLeases(
            base44,
            user,
            billingSnapshot,
            retentionPatch,
            appleLeases,
            billingDeletionMarker,
          );
        } catch (rollbackError) {
          console.error(
            "billing identity rollback before content cleanup failed",
            errorMessage(rollbackError),
          );
        }
      } else {
        console.error(
          "irreversible cleanup started; deletion marker retained for retry",
        );
      }
      return Response.json({
        error: disposition === "retain_deleting_for_retry"
          ? "Account deletion is incomplete and will continue on retry."
          : "Failed to delete account data safely",
      }, {
        status: disposition === "retain_deleting_for_retry"
          ? 503
          : appleLeaseErrorStatus(e),
      });
    }

    try {
      await deleteUserRecord(
        userStore,
        user.id,
      );
    } catch (e) {
      console.error("user delete failed", errorMessage(e));
      const confirmedPresent = e instanceof UserDeletionFailure &&
        e.code === "confirmed_present";
      // Content cleanup is irreversible by this point. A confirmed-present or
      // ambiguous User.delete must keep state=deleting and all billing
      // tombstones so the same idempotent endpoint can continue after lease
      // expiry. Restoring a live account here would expose partial erasure.
      console.error(
        confirmedPresent
          ? "user remains; deleting state retained for retry"
          : "user deletion is ambiguous; deleting state retained",
      );
      return Response.json({
        error: "Account deletion is being reconciled. Retry shortly.",
      }, { status: 503 });
    }

    // Raw identity is already gone from every canonical row. Release is best
    // effort after User.delete: failure can only delay Apple writers until the
    // bounded lease expires; it cannot leave an unretryable privacy leak.
    const releaseFailures =
      await releasePrecommittedAppleAccountLeasesBestEffort(
        accountStore,
        appleLeases,
        retentionPatch.user_id,
      );
    if (releaseFailures.length) {
      console.error(
        "post-delete Apple lease release delayed",
        releaseFailures.join(","),
      );
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
