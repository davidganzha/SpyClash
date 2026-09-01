// Run only through scripts/run-base44-reserved-spy-id-assignment.sh. Base44
// injects this authenticated SDK client without exposing an access token.
declare const base44: any;

const EXPECTED_APP_ID = "69a0e57fa939f578082f8091";
const EXPECTED_ACTION = "PARTNER_NOTE_67_ASSIGN_RESERVED_SPY_ID_067_067";
const RESERVED_SPY_ID = "067-067";
const REPORT_PREFIX = "SPYCLASH_RESERVED_SPY_ID_REPORT=";
const PAGE_SIZE = 100;
const MAX_PAGES = 100;
const APPLY = Deno.env.get("SPYCLASH_RESERVED_SPY_ID_APPLY") === "1";

type Entity = Record<string, any>;
type FriendshipPatch = {
  id: string;
  updated_date: string;
  set: Record<string, string>;
};

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function normalizeSpyID(value: unknown): string | null {
  const match = clean(value).match(/^([0-9]{3})[- ]?([0-9]{3})$/);
  return match ? `${match[1]}-${match[2]}` : null;
}

function stableJson(value: unknown): string {
  if (
    value === null || typeof value === "boolean" ||
    typeof value === "number" || typeof value === "string"
  ) {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map(stableJson).join(",")}]`;
  }
  if (typeof value === "object" && value !== null) {
    const record = value as Record<string, unknown>;
    const entries = Object.keys(record)
      .filter((key) => record[key] !== undefined)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableJson(record[key])}`)
      .join(",");
    return `{${entries}}`;
  }
  throw new Error("Assignment plan contains a non-JSON value.");
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function requireDigest(value: unknown, label: string): string {
  const digest = clean(value).toLocaleLowerCase();
  if (!/^[0-9a-f]{64}$/.test(digest)) {
    throw new Error(`${label} must be a lowercase SHA-256 digest.`);
  }
  return digest;
}

function emit(report: Record<string, unknown>) {
  console.log(`${REPORT_PREFIX}${JSON.stringify(report)}`);
}

async function filteredRecords(
  store: any,
  entityName: string,
  query: Record<string, unknown>,
): Promise<Entity[]> {
  const records: Entity[] = [];
  const seenIDs = new Set<string>();
  for (let pageIndex = 0; pageIndex < MAX_PAGES; pageIndex += 1) {
    const page = await store.filter(
      query,
      "created_date",
      PAGE_SIZE,
      pageIndex * PAGE_SIZE,
    ) || [];
    if (!Array.isArray(page) || page.length > PAGE_SIZE) {
      throw new Error(`${entityName} returned an invalid page.`);
    }
    for (const record of page) {
      const id = clean(record?.id);
      if (!id || seenIDs.has(id)) {
        throw new Error(`${entityName} returned an invalid identity set.`);
      }
      seenIDs.add(id);
      records.push(record);
    }
    if (page.length < PAGE_SIZE) return records;
  }
  throw new Error(`${entityName} exceeded the pagination safety ceiling.`);
}

async function listedRecords(
  store: any,
  entityName: string,
): Promise<Entity[]> {
  const records: Entity[] = [];
  const seenIDs = new Set<string>();
  for (let pageIndex = 0; pageIndex < MAX_PAGES; pageIndex += 1) {
    const page = await store.list(
      "created_date",
      PAGE_SIZE,
      pageIndex * PAGE_SIZE,
    ) || [];
    if (!Array.isArray(page) || page.length > PAGE_SIZE) {
      throw new Error(`${entityName} returned an invalid page.`);
    }
    for (const record of page) {
      const id = clean(record?.id);
      if (!id || seenIDs.has(id)) {
        throw new Error(`${entityName} returned an invalid identity set.`);
      }
      seenIDs.add(id);
      records.push(record);
    }
    if (page.length < PAGE_SIZE) return records;
  }
  throw new Error(`${entityName} exceeded the pagination safety ceiling.`);
}

async function exactUser(userID: string): Promise<Entity | null> {
  const rows = await filteredRecords(
    base44.entities.User,
    "User",
    { id: userID },
  );
  if (rows.length > 1) throw new Error("Target User identity is ambiguous.");
  return rows[0] || null;
}

function uniqueByID(records: Entity[]): Entity[] {
  const seen = new Set<string>();
  return records.filter((record) => {
    const id = clean(record?.id);
    if (!id || seen.has(id)) return false;
    seen.add(id);
    return true;
  });
}

async function targetFriendships(targetUserID: string): Promise<Entity[]> {
  const [requested, received] = await Promise.all([
    filteredRecords(
      base44.entities.Friendship,
      "Friendship",
      { requester_id: targetUserID },
    ),
    filteredRecords(
      base44.entities.Friendship,
      "Friendship",
      { addressee_id: targetUserID },
    ),
  ]);
  return uniqueByID([...requested, ...received]).sort((left, right) =>
    clean(left.id).localeCompare(clean(right.id))
  );
}

async function holdersOfReservedSpyID(): Promise<Entity[]> {
  const users = await listedRecords(
    base44.entities.User,
    "User",
  );
  return users.filter((user) =>
    normalizeSpyID(user?.spy_id) === RESERVED_SPY_ID
  );
}

async function loadState(targetUserID: string) {
  const [target, friendships, holders] = await Promise.all([
    exactUser(targetUserID),
    targetFriendships(targetUserID),
    holdersOfReservedSpyID(),
  ]);
  return { target, friendships, holders };
}

function friendshipPatches(
  targetUserID: string,
  friendships: Entity[],
): { patches: FriendshipPatch[]; invalidRows: number } {
  const patches: FriendshipPatch[] = [];
  let invalidRows = 0;
  for (const friendship of friendships) {
    const requesterID = clean(friendship.requester_id);
    const addresseeID = clean(friendship.addressee_id);
    const set: Record<string, string> = {};
    if (requesterID === targetUserID) {
      if (clean(friendship.requester_spy_id) !== RESERVED_SPY_ID) {
        set.requester_spy_id = RESERVED_SPY_ID;
      }
    } else if (addresseeID === targetUserID) {
      if (clean(friendship.addressee_spy_id) !== RESERVED_SPY_ID) {
        set.addressee_spy_id = RESERVED_SPY_ID;
      }
    } else {
      invalidRows += 1;
      continue;
    }
    if (!Object.keys(set).length) continue;
    const id = clean(friendship.id);
    const updatedDate = clean(friendship.updated_date);
    if (!id || !updatedDate) {
      invalidRows += 1;
      continue;
    }
    patches.push({ id, updated_date: updatedDate, set });
  }
  return { patches, invalidRows };
}

function counterpartUserIDs(targetUserID: string, friendships: Entity[]) {
  return [
    ...new Set(
      friendships.flatMap((friendship) => [
        clean(friendship.requester_id),
        clean(friendship.addressee_id),
      ]).filter((userID) => userID && userID !== targetUserID),
    ),
  ].sort();
}

const targetUserID = clean(
  Deno.env.get("SPYCLASH_RESERVED_SPY_ID_TARGET_USER_ID"),
);
if (!/^[A-Za-z0-9_-]{6,128}$/.test(targetUserID)) {
  throw new Error("A stable target User ID is required.");
}
const expectedCurrentSpyID = normalizeSpyID(
  Deno.env.get("SPYCLASH_RESERVED_SPY_ID_EXPECTED_CURRENT"),
);
if (!expectedCurrentSpyID) {
  throw new Error("The expected current SPY ID must use 000-000 format.");
}

const sourceSHA256 = requireDigest(
  Deno.env.get("SPYCLASH_RESERVED_SPY_ID_SOURCE_SHA256"),
  "SPYCLASH_RESERVED_SPY_ID_SOURCE_SHA256",
);
const lifecycleSourceSHA256 = requireDigest(
  Deno.env.get("SPYCLASH_RESERVED_SPY_ID_LIFECYCLE_SOURCE_SHA256"),
  "SPYCLASH_RESERVED_SPY_ID_LIFECYCLE_SOURCE_SHA256",
);
const billingLifecycleSourceSHA256 = requireDigest(
  Deno.env.get("SPYCLASH_RESERVED_SPY_ID_BILLING_LIFECYCLE_SOURCE_SHA256"),
  "SPYCLASH_RESERVED_SPY_ID_BILLING_LIFECYCLE_SOURCE_SHA256",
);
const policySourceSHA256 = requireDigest(
  Deno.env.get("SPYCLASH_RESERVED_SPY_ID_POLICY_SOURCE_SHA256"),
  "SPYCLASH_RESERVED_SPY_ID_POLICY_SOURCE_SHA256",
);
const profileSignalSourceSHA256 = requireDigest(
  Deno.env.get("SPYCLASH_RESERVED_SPY_ID_PROFILE_SIGNAL_SOURCE_SHA256"),
  "SPYCLASH_RESERVED_SPY_ID_PROFILE_SIGNAL_SOURCE_SHA256",
);

const lifecycleModuleURL = clean(
  Deno.env.get("SPYCLASH_RESERVED_SPY_ID_LIFECYCLE_URL"),
);
const profileSignalModuleURL = clean(
  Deno.env.get("SPYCLASH_RESERVED_SPY_ID_PROFILE_SIGNAL_URL"),
);
if (!lifecycleModuleURL.startsWith("file://")) {
  throw new Error("The wrapper-owned lifecycle module URL is invalid.");
}
if (!profileSignalModuleURL.startsWith("file://")) {
  throw new Error("The wrapper-owned profile signal module URL is invalid.");
}
const lifecycleModule = await import(lifecycleModuleURL);
const profileSignalModule = await import(profileSignalModuleURL);
if (typeof lifecycleModule.withCommunityWriteLeases !== "function") {
  throw new Error("The reviewed community lifecycle module is incomplete.");
}
if (typeof profileSignalModule.fanoutProfileUpdate !== "function") {
  throw new Error("The reviewed profile signal module is incomplete.");
}

if (APPLY) {
  if (
    Deno.env.get("SPYCLASH_RESERVED_SPY_ID_CONFIRM_ACTION") !== EXPECTED_ACTION
  ) {
    throw new Error("The exact reserved SPY ID action was not confirmed.");
  }
  if (
    Deno.env.get("SPYCLASH_RESERVED_SPY_ID_CONFIRM_APP_ID") !== EXPECTED_APP_ID
  ) {
    throw new Error("The reviewed SpyClash Base44 app was not confirmed.");
  }
  if (
    Deno.env.get("SPYCLASH_RESERVED_SPY_ID_CONFIRM_TARGET_USER_ID") !==
      targetUserID
  ) {
    throw new Error("The exact target User ID was not confirmed.");
  }
  if (
    Deno.env.get("SPYCLASH_RESERVED_SPY_ID_POLICY_DEPLOYED") !==
      "COMMUNITY_ACTION_RESERVED_067_067_V1"
  ) {
    throw new Error(
      "The reserved allocation policy deployment was not confirmed.",
    );
  }
}

const operator = await base44.auth.me();
if (clean(operator?.role).toLocaleLowerCase() !== "admin") {
  throw new Error("An authenticated Base44 admin is required.");
}
const operatorIdentity = clean(operator?.id)
  ? `id:${clean(operator.id)}`
  : `email:${clean(operator?.email).toLocaleLowerCase()}`;
if (operatorIdentity === "email:") {
  throw new Error("The authenticated Base44 admin has no stable identity.");
}
const operatorIdentitySHA256 = await sha256(operatorIdentity);
const targetIdentitySHA256 = await sha256(`id:${targetUserID}`);

async function buildPlan() {
  const state = await loadState(targetUserID);
  const currentSpyID = normalizeSpyID(state.target?.spy_id);
  const otherHolders = state.holders.filter((holder) =>
    clean(holder.id) !== targetUserID
  );
  const { patches, invalidRows } = friendshipPatches(
    targetUserID,
    state.friendships,
  );
  const missingTargetCAS = state.target && !clean(state.target.updated_date)
    ? 1
    : 0;
  const blockers = {
    target_missing: state.target ? 0 : 1,
    current_spy_id_mismatch:
      state.target && currentSpyID === expectedCurrentSpyID ? 0 : 1,
    reserved_spy_id_other_holders: otherHolders.length,
    invalid_friendship_rows: invalidRows,
    missing_target_cas: missingTargetCAS,
  };
  const blockerTotal = Object.values(blockers).reduce(
    (sum, value) => sum + value,
    0,
  );
  const envelope = {
    protocol: "spyclash-reserved-spy-id-assignment-v1",
    app_id: EXPECTED_APP_ID,
    source_sha256: sourceSHA256,
    lifecycle_source_sha256: lifecycleSourceSHA256,
    billing_lifecycle_source_sha256: billingLifecycleSourceSHA256,
    policy_source_sha256: policySourceSHA256,
    profile_signal_source_sha256: profileSignalSourceSHA256,
    operator_identity_sha256: operatorIdentitySHA256,
    target: {
      user_id: targetUserID,
      updated_date: clean(state.target?.updated_date),
      expected_current_spy_id: expectedCurrentSpyID,
      reserved_spy_id: RESERVED_SPY_ID,
    },
    friendship_patches: patches,
  };
  const planDigest = await sha256(stableJson(envelope));
  const friendshipProjectionSHA256 = await sha256(
    stableJson(patches.map((patch) => ({
      id: patch.id,
      updated_date: patch.updated_date,
      set: patch.set,
    }))),
  );
  return {
    state,
    patches,
    blockers,
    blockerTotal,
    envelope,
    planDigest,
    friendshipProjectionSHA256,
  };
}

function publicReport(
  plan: Awaited<ReturnType<typeof buildPlan>>,
  phase: string,
) {
  return {
    protocol: plan.envelope.protocol,
    app_id: EXPECTED_APP_ID,
    mode: APPLY ? "apply" : "dry-run",
    phase,
    source_sha256: sourceSHA256,
    lifecycle_source_sha256: lifecycleSourceSHA256,
    billing_lifecycle_source_sha256: billingLifecycleSourceSHA256,
    policy_source_sha256: policySourceSHA256,
    profile_signal_source_sha256: profileSignalSourceSHA256,
    operator_identity_sha256: operatorIdentitySHA256,
    target_identity_sha256: targetIdentitySHA256,
    expected_current_spy_id: expectedCurrentSpyID,
    reserved_spy_id: RESERVED_SPY_ID,
    plan_digest: plan.planDigest,
    friendship_projection_sha256: plan.friendshipProjectionSHA256,
    friendship_rows: plan.state.friendships.length,
    friendship_updates: plan.patches.length,
    blockers: plan.blockers,
    blocker_total: plan.blockerTotal,
  };
}

const initialPlan = await buildPlan();
if (initialPlan.blockerTotal > 0) {
  emit(publicReport(initialPlan, "blocked"));
  if (APPLY) {
    throw new Error(
      "Reserved SPY ID assignment is blocked. No records changed.",
    );
  }
} else if (!APPLY) {
  emit(publicReport(initialPlan, "planned"));
} else {
  const expectedPlanDigest = requireDigest(
    Deno.env.get("SPYCLASH_RESERVED_SPY_ID_EXPECTED_PLAN_DIGEST"),
    "SPYCLASH_RESERVED_SPY_ID_EXPECTED_PLAN_DIGEST",
  );
  if (expectedPlanDigest !== initialPlan.planDigest) {
    emit(publicReport(initialPlan, "digest-mismatch"));
    throw new Error("The live plan differs from the reviewed dry-run.");
  }

  const protectedUserIDs = [
    targetUserID,
    ...counterpartUserIDs(targetUserID, initialPlan.state.friendships),
  ];
  emit(publicReport(initialPlan, "pre-write"));
  await lifecycleModule.withCommunityWriteLeases({
    lifecycleStore: base44.entities.BillingIdentityLifecycle,
    userIDs: protectedUserIDs,
    action: async ({ persist }: {
      persist: <T>(writer: () => Promise<T>) => Promise<T>;
    }) => {
      const lockedPlan = await buildPlan();
      if (
        lockedPlan.blockerTotal > 0 ||
        lockedPlan.planDigest !== expectedPlanDigest
      ) {
        throw new Error("The assignment changed before the protected write.");
      }

      // Update denormalized relationship copies first. If a later write fails,
      // the target still owns its old SPY ID and a new dry-run can safely resume.
      for (const patch of lockedPlan.patches) {
        await persist(() =>
          base44.entities.Friendship.update(patch.id, patch.set)
        );
      }
      if (normalizeSpyID(lockedPlan.state.target?.spy_id) !== RESERVED_SPY_ID) {
        await persist(() =>
          base44.entities.User.update(targetUserID, {
            spy_id: RESERVED_SPY_ID,
          })
        );
      }

      const verified = await loadState(targetUserID);
      const verifiedHolders = verified.holders.filter((holder) =>
        clean(holder.id) === targetUserID
      );
      const inconsistentFriendships = friendshipPatches(
        targetUserID,
        verified.friendships,
      );
      if (
        normalizeSpyID(verified.target?.spy_id) !== RESERVED_SPY_ID ||
        verified.holders.length !== 1 || verifiedHolders.length !== 1 ||
        inconsistentFriendships.patches.length > 0 ||
        inconsistentFriendships.invalidRows > 0
      ) {
        throw new Error("Reserved SPY ID postflight verification failed.");
      }
    },
  });

  let profileFanout = "completed";
  try {
    await profileSignalModule.fanoutProfileUpdate({
      userStore: base44.entities.User,
      signalStore: base44.entities.CommunityProfileSignal,
      profileUserID: targetUserID,
    });
  } catch {
    profileFanout = "deferred";
  }
  emit({
    ...publicReport(initialPlan, "completed"),
    applied_friendship_updates: initialPlan.patches.length,
    profile_fanout: profileFanout,
    postflight_unique_owner: true,
    postflight_friendship_projection: true,
  });
}
