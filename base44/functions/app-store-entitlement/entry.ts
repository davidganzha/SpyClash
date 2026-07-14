import {
  AppStoreServerAPIClient,
  Environment,
  type JWSRenewalInfoDecodedPayload,
  type JWSTransactionDecodedPayload,
  SignedDataVerifier,
} from "npm:@apple/app-store-server-library@3.1.0";
import { createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import { Buffer } from "node:buffer";
import {
  type AppleEntitlementRecord,
  LIMITLESS_PRODUCT_ID,
  normalizeAppleEntitlement,
  publicAppleEntitlement,
  requiresCanonicalSubscriptionStatus,
  shouldApplyProviderEvent,
} from "./apple-entitlement.ts";
import {
  type EntitlementRecord,
  hasActiveMembership,
} from "./membership-guard.ts";
import {
  type AppleAccountBindingDecision,
  canContinueAppleAccountBinding,
  canonicalAppleAccountRecord,
  canRebindAppleEntitlementOwner,
  decideAppleAccountBinding,
  decideAppleNotificationOwner,
  isAppleAccountLeaseActive,
} from "./apple-account-binding.ts";
import {
  AppleAccountReservationError,
  reserveAppleAccountToken,
} from "./apple-account-reservation.ts";
import {
  AppleAccountLeaseGuardError,
  assertAppleAccountLease,
} from "./apple-account-lease-guard.ts";

const BUNDLE_ID = Deno.env.get("APPLE_IAP_BUNDLE_ID") || "com.spyclash.app";
const PRODUCT_ID = Deno.env.get("APPLE_IAP_PRODUCT_ID") ||
  LIMITLESS_PRODUCT_ID;
const MAX_REQUEST_BYTES = 256_000;
const ENTITY_PAGE_SIZE = 100;
const APPLE_ACCOUNT_LEASE_MILLISECONDS = 5 * 60 * 1_000;
const APPLE_ACCOUNT_LEASE_ATTEMPTS = 4;
const APPLE_ROOT_CERTIFICATE_URLS = [
  "https://www.apple.com/appleca/AppleIncRootCertificate.cer",
  "https://www.apple.com/certificateauthority/AppleRootCA-G2.cer",
  "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer",
];

type AppStoreAccountRecord = {
  id?: string;
  user_id?: string;
  app_account_token?: string;
  created_at?: string;
  last_used_at?: string;
  created_date?: string;
};

type AppleAccountLease = {
  accountID: string;
  ownerUserID: string;
  leaseUntil: string;
  accounts: AppStoreAccountRecord[];
};

class RequestError extends Error {
  status: number;

  constructor(message: string, status = 400) {
    super(message);
    this.name = "RequestError";
    this.status = status;
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error
    ? error.message
    : String(error || "Unknown error");
}

function canonicalUUID(value: unknown): string {
  const token = String(value || "").trim().toLowerCase();
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      .test(token)
  ) {
    throw new RequestError("Invalid Apple app account token.", 422);
  }
  return token;
}

function cleanRecord<T extends Record<string, unknown>>(record: T) {
  return Object.fromEntries(
    Object.entries(record).filter(([key, value]) =>
      key !== "id" && value !== undefined
    ),
  );
}

async function allMatchingRecords<T>(
  store: any,
  filter: Record<string, unknown>,
): Promise<T[]> {
  const records: T[] = [];
  let skip = 0;
  while (true) {
    const page: T[] = await store.filter(
      filter,
      "created_date",
      ENTITY_PAGE_SIZE,
      skip,
    );
    records.push(...page);
    if (page.length < ENTITY_PAGE_SIZE) return records;
    skip += page.length;
  }
}

async function parseJSONBody(req: Request): Promise<Record<string, unknown>> {
  const declaredLength = Number(req.headers.get("content-length") || 0);
  if (declaredLength > MAX_REQUEST_BYTES) {
    throw new RequestError("Request is too large.", 413);
  }
  const text = await req.text();
  if (text.length > MAX_REQUEST_BYTES) {
    throw new RequestError("Request is too large.", 413);
  }
  try {
    const parsed = JSON.parse(text || "{}");
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("not an object");
    }
    return parsed;
  } catch {
    throw new RequestError("Invalid JSON body.", 400);
  }
}

function decodeJWSPayloadWithoutTrust(jws: string): Record<string, any> {
  const payload = jws.split(".")[1];
  if (!payload) throw new RequestError("Malformed Apple signed payload.", 400);
  const normalized = payload.replaceAll("-", "+").replaceAll("_", "/");
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
  try {
    return JSON.parse(Buffer.from(padded, "base64").toString("utf8"));
  } catch {
    throw new RequestError("Malformed Apple signed payload.", 400);
  }
}

function environmentFromUntrustedJWS(jws: string): Environment {
  const payload = decodeJWSPayloadWithoutTrust(jws);
  const raw = payload.environment || payload.data?.environment ||
    payload.summary?.environment || payload.appData?.environment;
  if (raw === Environment.SANDBOX) return Environment.SANDBOX;
  if (raw === Environment.PRODUCTION) return Environment.PRODUCTION;
  throw new RequestError("Unsupported Apple environment.", 422);
}

let appleRootCertificatesPromise: Promise<Buffer[]> | undefined;
const verifierPromises = new Map<Environment, Promise<SignedDataVerifier>>();
const apiClients = new Map<Environment, AppStoreServerAPIClient>();

function appleRootCertificates(): Promise<Buffer[]> {
  appleRootCertificatesPromise ??= Promise.all(
    APPLE_ROOT_CERTIFICATE_URLS.map(async (url) => {
      const response = await fetch(url);
      if (!response.ok) {
        throw new Error(
          `Unable to load Apple root certificate (${response.status}).`,
        );
      }
      return Buffer.from(await response.arrayBuffer());
    }),
  );
  return appleRootCertificatesPromise;
}

function productionAppAppleID(): number {
  const value = Number(Deno.env.get("APPLE_IAP_APPLE_ID"));
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new RequestError(
      "APPLE_IAP_APPLE_ID is required for production verification.",
      503,
    );
  }
  return value;
}

function verifierFor(environment: Environment): Promise<SignedDataVerifier> {
  let verifier = verifierPromises.get(environment);
  if (!verifier) {
    verifier = appleRootCertificates().then((certificates) =>
      new SignedDataVerifier(
        certificates,
        true,
        environment,
        BUNDLE_ID,
        environment === Environment.PRODUCTION
          ? productionAppAppleID()
          : undefined,
      )
    );
    verifierPromises.set(environment, verifier);
  }
  return verifier;
}

function decodeIAPPrivateKey(): string | null {
  const direct = Deno.env.get("APPLE_IAP_PRIVATE_KEY_P8");
  if (direct?.includes("BEGIN PRIVATE KEY")) return direct;
  const encoded = Deno.env.get("APPLE_IAP_PRIVATE_KEY_P8_B64");
  if (!encoded) return null;
  try {
    const key = Buffer.from(encoded.replaceAll(/\s/g, ""), "base64").toString(
      "utf8",
    );
    return key.includes("BEGIN PRIVATE KEY") ? key : null;
  } catch {
    return null;
  }
}

function appStoreAPIClient(environment: Environment): AppStoreServerAPIClient {
  const cached = apiClients.get(environment);
  if (cached) return cached;

  const signingKey = decodeIAPPrivateKey();
  const keyID = Deno.env.get("APPLE_IAP_KEY_ID");
  const issuerID = Deno.env.get("APPLE_IAP_ISSUER_ID");
  if (!signingKey || !keyID || !issuerID) {
    throw new RequestError(
      "App Store Server API credentials are not configured.",
      503,
    );
  }

  const client = new AppStoreServerAPIClient(
    signingKey,
    keyID,
    issuerID,
    BUNDLE_ID,
    environment,
  );
  apiClients.set(environment, client);
  return client;
}

async function verifiedTransaction(signedTransaction: string) {
  const environment = environmentFromUntrustedJWS(signedTransaction);
  const verifier = await verifierFor(environment);
  const transaction = await verifier.verifyAndDecodeTransaction(
    signedTransaction,
  );
  return { environment, verifier, transaction };
}

async function canonicalSubscriptionStatus(
  transaction: JWSTransactionDecodedPayload,
  environment: Environment,
  verifier: SignedDataVerifier,
) {
  const client = appStoreAPIClient(environment);
  if (!transaction.transactionId) {
    throw new RequestError("Apple transaction ID is missing.", 422);
  }

  try {
    const response = await client.getAllSubscriptionStatuses(
      transaction.transactionId,
    );
    const candidates = (response.data || []).flatMap((group) =>
      group.lastTransactions || []
    );
    const candidate = candidates.find((item) =>
      item.originalTransactionId === transaction.originalTransactionId
    );
    if (!candidate?.signedTransactionInfo) {
      throw new RequestError(
        "App Store did not return a current matching subscription.",
        409,
      );
    }

    const currentTransaction = await verifier.verifyAndDecodeTransaction(
      candidate.signedTransactionInfo,
    );
    const renewal = candidate.signedRenewalInfo
      ? await verifier.verifyAndDecodeRenewalInfo(candidate.signedRenewalInfo)
      : undefined;
    if (
      currentTransaction.originalTransactionId !==
        transaction.originalTransactionId ||
      currentTransaction.productId !== PRODUCT_ID
    ) {
      throw new RequestError(
        "App Store status response did not match the submitted subscription.",
        409,
      );
    }
    const status = Number(candidate.status);
    if (!Number.isInteger(status) || status < 1 || status > 5) {
      throw new RequestError(
        "App Store returned an unsupported subscription status.",
        503,
      );
    }
    return {
      transaction: currentTransaction,
      renewal,
      status,
      checkedAtMilliseconds: Date.now(),
    };
  } catch (error) {
    console.error(
      "App Store Server API reconciliation failed:",
      errorMessage(error),
    );
    if (error instanceof RequestError) throw error;
    throw new RequestError(
      "App Store Server API reconciliation is temporarily unavailable.",
      503,
    );
  }
}

async function requireUser(base44: any) {
  try {
    const user = await base44.auth.me();
    if (typeof user?.id !== "string" || !user.id) {
      throw new Error("missing user");
    }
    return user as { id: string; email?: string };
  } catch {
    throw new RequestError("Authentication required.", 401);
  }
}

async function accountsForToken(store: any, rawToken: unknown) {
  const token = canonicalUUID(rawToken);
  return await allMatchingRecords<AppStoreAccountRecord>(
    store,
    { app_account_token: token },
  );
}

function requireUsableBinding(
  accounts: readonly AppStoreAccountRecord[],
  userID: string,
): AppleAccountBindingDecision {
  const decision = decideAppleAccountBinding(
    accounts.map((account) => account.user_id),
    userID,
  );
  if (decision.kind === "missing" || decision.kind === "conflict") {
    throw new RequestError(
      "This App Store purchase is not reserved for the signed-in SpyClash account.",
      409,
    );
  }
  return decision;
}

async function acquireAppleAccountLease(
  store: any,
  appAccountToken: string,
): Promise<AppleAccountLease> {
  for (let attempt = 0; attempt < APPLE_ACCOUNT_LEASE_ATTEMPTS; attempt += 1) {
    const accounts = await accountsForToken(store, appAccountToken);
    const canonical = canonicalAppleAccountRecord(accounts);
    const accountID = String(canonical?.id || "");
    const ownerUserID = String(canonical?.user_id || "").trim();
    const observedLastUsedAt = String(canonical?.last_used_at || "");
    if (!accountID || !ownerUserID || !observedLastUsedAt) {
      throw new RequestError(
        "Apple account binding is not available yet.",
        503,
      );
    }
    if (isAppleAccountLeaseActive(observedLastUsedAt)) {
      throw new RequestError(
        "Apple account binding is being updated. Retry shortly.",
        503,
      );
    }

    const leaseUntil = new Date(
      Date.now() + APPLE_ACCOUNT_LEASE_MILLISECONDS,
    ).toISOString();
    const result = await store.updateMany(
      {
        id: accountID,
        user_id: ownerUserID,
        last_used_at: observedLastUsedAt,
      },
      { $set: { last_used_at: leaseUntil } },
    );
    if (Number(result?.updated) === 1) {
      return {
        accountID,
        ownerUserID,
        leaseUntil,
        accounts: accounts.map((account) =>
          account.id === accountID
            ? { ...account, last_used_at: leaseUntil }
            : account
        ),
      };
    }
  }
  throw new RequestError(
    "Apple account binding changed concurrently. Retry shortly.",
    503,
  );
}

async function releaseAppleAccountLease(
  store: any,
  lease: AppleAccountLease,
): Promise<boolean> {
  const result = await store.updateMany(
    {
      id: lease.accountID,
      user_id: lease.ownerUserID,
      last_used_at: lease.leaseUntil,
    },
    { $set: { last_used_at: new Date().toISOString() } },
  );
  return Number(result?.updated) === 1;
}

async function bestEffortReleaseAppleAccountLease(
  store: any,
  lease: AppleAccountLease,
) {
  try {
    await releaseAppleAccountLease(store, lease);
  } catch (error) {
    console.error("Apple account lease release failed:", errorMessage(error));
  }
}

async function matchingAppleEntitlements(
  store: any,
  appAccountToken: string,
  originalTransactionID: string,
): Promise<AppleEntitlementRecord[]> {
  const [sameToken, sameOriginal] = await Promise.all([
    allMatchingRecords<AppleEntitlementRecord>(store, {
      provider: "apple",
      app_account_token: appAccountToken,
    }),
    allMatchingRecords<AppleEntitlementRecord>(store, {
      provider: "apple",
      original_transaction_id: originalTransactionID,
    }),
  ]);

  const unique = new Map<string, AppleEntitlementRecord>();
  for (const record of [...sameToken, ...sameOriginal]) {
    const identity = String(
      record.id ||
        `${record.source_key}:${record.transaction_id}:${record.user_id}`,
    );
    unique.set(identity, record);
  }
  return [...unique.values()];
}

async function prepareAppleAccountBindingAfterVerification(input: {
  accountStore: any;
  entitlementStore: any;
  appAccountToken: string;
  originalTransactionID: string;
  authenticatedUserID: string;
  authenticatedUserEmail?: string;
  initialDecision: AppleAccountBindingDecision;
  lease: AppleAccountLease;
}): Promise<string | null> {
  // The lease is acquired only after Apple's canonical API response. Every
  // entitlement writer for this token uses the same deterministic CAS row.
  const accounts = input.lease.accounts;
  const decision = requireUsableBinding(accounts, input.authenticatedUserID);
  if (!canContinueAppleAccountBinding(input.initialDecision, decision)) {
    throw new RequestError(
      "This App Store purchase is not reserved for the signed-in SpyClash account.",
      409,
    );
  }
  if (input.initialDecision.kind === "same_owner") return null;
  if (input.initialDecision.kind !== "rebind_deleted") {
    throw new RequestError(
      "This App Store purchase is not reserved for the signed-in SpyClash account.",
      409,
    );
  }
  if (decision.kind === "same_owner") {
    // A concurrent/idempotent retry already finished the migration.
    return null;
  }
  const tombstoneUserID = input.initialDecision.tombstoneUserID;
  if (
    decision.kind !== "rebind_deleted" ||
    decision.tombstoneUserID !== tombstoneUserID
  ) {
    throw new RequestError(
      "This App Store subscription belongs to another SpyClash account.",
      409,
    );
  }
  const userEmail = String(input.authenticatedUserEmail || "").trim();
  if (!userEmail) {
    throw new RequestError(
      "The signed-in SpyClash account must have an email address before restoring purchases.",
      409,
    );
  }

  const entitlements = await matchingAppleEntitlements(
    input.entitlementStore,
    input.appAccountToken,
    input.originalTransactionID,
  );
  for (const record of entitlements) {
    if (
      !canRebindAppleEntitlementOwner(
        record.user_id,
        input.authenticatedUserID,
        tombstoneUserID,
      )
    ) {
      throw new RequestError(
        "This App Store subscription belongs to another SpyClash account.",
        409,
      );
    }
  }

  // Entitlement rows move first. If a write fails, AppStoreAccount remains a
  // tombstone and the exact same verified restore can safely resume later.
  for (const record of entitlements) {
    if (
      record.user_id === input.authenticatedUserID &&
      record.user_email === userEmail
    ) {
      continue;
    }
    if (!record.id) {
      throw new Error("Apple entitlement record is missing its entity id.");
    }
    await assertAppleAccountLease(input.accountStore, input.lease);
    await input.entitlementStore.update(record.id, {
      user_id: input.authenticatedUserID,
      user_email: userEmail,
    });
  }

  const migratedEntitlements = await matchingAppleEntitlements(
    input.entitlementStore,
    input.appAccountToken,
    input.originalTransactionID,
  );
  if (
    migratedEntitlements.some((record) =>
      record.user_id !== input.authenticatedUserID ||
      record.user_email !== userEmail
    )
  ) {
    throw new RequestError(
      "This App Store subscription belongs to another SpyClash account.",
      409,
    );
  }

  return tombstoneUserID;
}

async function finalizeDeletedAppleAccountRebind(input: {
  accountStore: any;
  entitlementStore: any;
  appAccountToken: string;
  originalTransactionID: string;
  authenticatedUserID: string;
  authenticatedUserEmail: string;
  tombstoneUserID: string;
  lease: AppleAccountLease;
}) {
  // AppStoreAccount is the commit marker and is deliberately written after
  // every entitlement row, including the new canonical status, is durable.
  const accounts = await accountsForToken(
    input.accountStore,
    input.appAccountToken,
  );
  const decision = requireUsableBinding(accounts, input.authenticatedUserID);
  const expected: AppleAccountBindingDecision = {
    kind: "rebind_deleted",
    tombstoneUserID: input.tombstoneUserID,
  };
  if (!canContinueAppleAccountBinding(expected, decision)) {
    throw new RequestError(
      "This App Store subscription belongs to another SpyClash account.",
      409,
    );
  }

  const finalEntitlements = await matchingAppleEntitlements(
    input.entitlementStore,
    input.appAccountToken,
    input.originalTransactionID,
  );
  if (
    finalEntitlements.length === 0 ||
    finalEntitlements.some((record) =>
      record.user_id !== input.authenticatedUserID ||
      record.user_email !== input.authenticatedUserEmail
    )
  ) {
    throw new RequestError(
      "Apple entitlement ownership changed concurrently. Retry shortly.",
      503,
    );
  }

  const leaseAccount = canonicalAppleAccountRecord(accounts);
  if (
    leaseAccount?.id !== input.lease.accountID ||
    leaseAccount.user_id !== input.lease.ownerUserID ||
    leaseAccount.last_used_at !== input.lease.leaseUntil
  ) {
    throw new RequestError(
      "Apple account binding changed concurrently. Retry shortly.",
      503,
    );
  }

  const now = new Date().toISOString();
  for (const account of accounts) {
    if (
      account.id === input.lease.accountID ||
      account.user_id === input.authenticatedUserID
    ) {
      continue;
    }
    if (!account.id || account.user_id !== input.tombstoneUserID) {
      throw new RequestError(
        "This App Store subscription belongs to another SpyClash account.",
        409,
      );
    }
    await assertAppleAccountLease(input.accountStore, input.lease);
    const result = await input.accountStore.updateMany(
      { id: account.id, user_id: input.tombstoneUserID },
      {
        $set: {
          user_id: input.authenticatedUserID,
          last_used_at: now,
        },
      },
    );
    if (Number(result?.updated) !== 1) {
      throw new RequestError(
        "This App Store subscription belongs to another SpyClash account.",
        409,
      );
    }
  }

  const commitPatch = input.lease.ownerUserID === input.authenticatedUserID
    ? { last_used_at: now }
    : {
      user_id: input.authenticatedUserID,
      last_used_at: now,
    };
  await assertAppleAccountLease(input.accountStore, input.lease);
  const commit = await input.accountStore.updateMany(
    {
      id: input.lease.accountID,
      user_id: input.lease.ownerUserID,
      last_used_at: input.lease.leaseUntil,
    },
    { $set: commitPatch },
  );
  if (Number(commit?.updated) !== 1) {
    throw new RequestError(
      "Apple account binding changed concurrently. Retry shortly.",
      503,
    );
  }

  const persistedAccounts = await accountsForToken(
    input.accountStore,
    input.appAccountToken,
  );
  if (
    persistedAccounts.length === 0 ||
    persistedAccounts.some((account) =>
      account.user_id !== input.authenticatedUserID
    )
  ) {
    throw new Error("Apple account ownership migration did not converge.");
  }
}

async function reserveAccountToken(store: any, userID: string) {
  try {
    return await reserveAppleAccountToken(store, userID);
  } catch (error) {
    if (error instanceof AppleAccountReservationError) {
      throw new RequestError(error.message, error.status);
    }
    throw error;
  }
}

async function upsertAppleEntitlement(
  store: any,
  incoming: AppleEntitlementRecord,
  beforePersist: () => Promise<void>,
) {
  const [sameOriginal, sameToken] = await Promise.all([
    store.filter(
      {
        provider: "apple",
        original_transaction_id: incoming.original_transaction_id,
      },
      "-provider_event_at",
      20,
      0,
    ),
    store.filter(
      { provider: "apple", app_account_token: incoming.app_account_token },
      "-provider_event_at",
      20,
      0,
    ),
  ]) as [AppleEntitlementRecord[], AppleEntitlementRecord[]];

  const conflicts = [...sameOriginal, ...sameToken].filter((record) =>
    record.user_id && record.user_id !== incoming.user_id
  );
  if (conflicts.length) {
    throw new RequestError(
      "This App Store subscription belongs to another SpyClash account.",
      409,
    );
  }

  const current = sameOriginal.find((record) =>
    record.user_id === incoming.user_id
  );
  if (current?.id) {
    if (shouldApplyProviderEvent(current, incoming)) {
      await beforePersist();
      await store.update(current.id, cleanRecord(incoming));
    }
    return await collapseAppleEntitlementDuplicates(
      store,
      incoming,
      current,
      beforePersist,
    );
  }

  await beforePersist();
  await store.create(cleanRecord(incoming));
  return await collapseAppleEntitlementDuplicates(
    store,
    incoming,
    incoming,
    beforePersist,
  );
}

function appleRecordFreshness(record: AppleEntitlementRecord): number {
  for (const value of [record.provider_event_at, record.last_verified_at]) {
    const timestamp = Date.parse(value || "");
    if (Number.isFinite(timestamp)) return timestamp;
  }
  return Number.NEGATIVE_INFINITY;
}

async function collapseAppleEntitlementDuplicates(
  store: any,
  incoming: AppleEntitlementRecord,
  fallback: AppleEntitlementRecord,
  beforePersist: () => Promise<void>,
) {
  const records: AppleEntitlementRecord[] = await store.filter(
    {
      provider: "apple",
      original_transaction_id: incoming.original_transaction_id,
    },
    "-provider_event_at",
    20,
    0,
  );
  const owned = records.filter((record) => record.user_id === incoming.user_id);
  if (!owned.length) return fallback;

  const winner = owned.reduce((current, candidate) => {
    const candidateFreshness = appleRecordFreshness(candidate);
    const currentFreshness = appleRecordFreshness(current);
    if (candidateFreshness !== currentFreshness) {
      return candidateFreshness > currentFreshness ? candidate : current;
    }
    // Deterministic tie-breaking makes concurrent cleanup calls retain the
    // same row instead of deleting each other's winner.
    return String(candidate.id || "") < String(current.id || "")
      ? candidate
      : current;
  });

  for (const duplicate of owned) {
    if (!duplicate.id || duplicate.id === winner.id) continue;
    try {
      await beforePersist();
      await store.delete(duplicate.id);
    } catch (error) {
      console.error(
        "Duplicate Apple entitlement cleanup failed:",
        errorMessage(error),
      );
    }
  }
  return winner;
}

function assertAllowedAppleTransaction(
  transaction: JWSTransactionDecodedPayload,
) {
  if (transaction.bundleId !== BUNDLE_ID) {
    throw new RequestError(
      "Apple transaction bundle does not match SpyClash.",
      422,
    );
  }
  if (transaction.productId !== PRODUCT_ID) {
    throw new RequestError(
      "Apple transaction product is not a LIMITLESS subscription.",
      422,
    );
  }
  if (
    transaction.type &&
    transaction.type !== "Auto-Renewable Subscription"
  ) {
    throw new RequestError(
      "Apple transaction is not an auto-renewable subscription.",
      422,
    );
  }
}

async function handlePrepare(base44: any) {
  const user = await requireUser(base44);
  const adminGrants = await base44.asServiceRole.entities.MembershipGrant
    .filter(
      { user_id: user.id },
      "-created_date",
      100,
      0,
    );
  if (hasActiveAdminGrant(adminGrants)) {
    throw new RequestError(
      "LIMITLESS is already active on this SpyClash account.",
      409,
    );
  }
  const stored: EntitlementRecord[] = await base44.asServiceRole.entities
    .Entitlement.filter(
      { user_id: user.id },
      "-last_verified_at",
      100,
      0,
    );
  if (hasActiveMembership(stored)) {
    throw new RequestError(
      "LIMITLESS is already active on this SpyClash account.",
      409,
    );
  }
  const token = await reserveAccountToken(
    base44.asServiceRole.entities.AppStoreAccount,
    user.id,
  );
  return Response.json({
    product_id: PRODUCT_ID,
    app_account_token: token,
  });
}

function hasActiveAdminGrant(records: any[], now = new Date()): boolean {
  return records.some((record) => {
    if (record?.active !== true) return false;
    const rawExpiry = typeof record?.expires_at === "string"
      ? record.expires_at.trim()
      : "";
    if (!rawExpiry) return true;
    const expiry = Date.parse(rawExpiry);
    return Number.isFinite(expiry) && expiry > now.getTime();
  });
}

async function handleAuthenticatedSync(
  base44: any,
  body: Record<string, unknown>,
) {
  const user = await requireUser(base44);
  const signedTransaction = String(body.signed_transaction || "");
  if (!signedTransaction) {
    throw new RequestError("signed_transaction is required.", 400);
  }

  const verified = await verifiedTransaction(signedTransaction);
  assertAllowedAppleTransaction(verified.transaction);
  const transactionToken = canonicalUUID(verified.transaction.appAccountToken);
  const accountStore = base44.asServiceRole.entities.AppStoreAccount;
  const accounts = await accountsForToken(accountStore, transactionToken);
  const initialBinding = requireUsableBinding(accounts, user.id);

  const canonical = await canonicalSubscriptionStatus(
    verified.transaction,
    verified.environment,
    verified.verifier,
  );
  assertAllowedAppleTransaction(canonical.transaction);
  const canonicalToken = canonical.transaction.appAccountToken ||
    canonical.renewal?.appAccountToken || transactionToken;
  if (canonicalUUID(canonicalToken) !== transactionToken) {
    throw new RequestError(
      "Apple subscription account token changed unexpectedly.",
      409,
    );
  }

  const entitlement = normalizeAppleEntitlement({
    userID: user.id,
    userEmail: user.email,
    transaction: canonical.transaction,
    renewal: canonical.renewal,
    appleStatus: canonical.status,
    eventAtMilliseconds: canonical.checkedAtMilliseconds,
  });
  const lease = await acquireAppleAccountLease(accountStore, transactionToken);
  let leaseHeld = true;
  try {
    const tombstoneUserID = await prepareAppleAccountBindingAfterVerification({
      accountStore,
      entitlementStore: base44.asServiceRole.entities.Entitlement,
      appAccountToken: transactionToken,
      originalTransactionID: entitlement.original_transaction_id,
      authenticatedUserID: user.id,
      authenticatedUserEmail: user.email,
      initialDecision: initialBinding,
      lease,
    });

    const persisted = await upsertAppleEntitlement(
      base44.asServiceRole.entities.Entitlement,
      entitlement,
      () => assertAppleAccountLease(accountStore, lease),
    );
    if (tombstoneUserID) {
      await finalizeDeletedAppleAccountRebind({
        accountStore,
        entitlementStore: base44.asServiceRole.entities.Entitlement,
        appAccountToken: transactionToken,
        originalTransactionID: entitlement.original_transaction_id,
        authenticatedUserID: user.id,
        authenticatedUserEmail: String(user.email || "").trim(),
        tombstoneUserID,
        lease,
      });
      leaseHeld = false;
    } else {
      const released = await releaseAppleAccountLease(accountStore, lease);
      if (!released) {
        throw new RequestError(
          "Apple account binding changed concurrently. Retry shortly.",
          503,
        );
      }
      leaseHeld = false;
    }

    return Response.json({
      success: true,
      server_status_verified: true,
      entitlement: publicAppleEntitlement(persisted),
    });
  } finally {
    if (leaseHeld) {
      await bestEffortReleaseAppleAccountLease(accountStore, lease);
    }
  }
}

async function handleNotification(base44: any, signedPayload: string) {
  const environment = environmentFromUntrustedJWS(signedPayload);
  const verifier = await verifierFor(environment);
  const notification = await verifier.verifyAndDecodeNotification(
    signedPayload,
  );

  if (notification.notificationType === "TEST") {
    return Response.json({ success: true, test: true });
  }

  const signedTransaction = notification.data?.signedTransactionInfo;
  if (!signedTransaction) {
    // Summary/app-data notifications do not change LIMITLESS subscription state.
    return Response.json({ success: true, ignored: true });
  }
  const transaction = await verifier.verifyAndDecodeTransaction(
    signedTransaction,
  );
  if (transaction.bundleId !== BUNDLE_ID) {
    throw new RequestError(
      "Apple transaction bundle does not match SpyClash.",
      422,
    );
  }
  if (
    transaction.productId !== PRODUCT_ID ||
    (transaction.type && transaction.type !== "Auto-Renewable Subscription")
  ) {
    // App Store Server Notifications are configured per app, not per product.
    // A future consumable or another subscription must not trigger retries.
    return Response.json({ success: true, ignored: true });
  }
  let renewal: JWSRenewalInfoDecodedPayload | undefined =
    notification.data?.signedRenewalInfo
      ? await verifier.verifyAndDecodeRenewalInfo(
        notification.data.signedRenewalInfo,
      )
      : undefined;

  const notificationToken = canonicalUUID(
    transaction.appAccountToken || renewal?.appAccountToken,
  );

  let canonicalTransaction = transaction;
  let canonicalStatus = Number(notification.data?.status) || undefined;
  let eventAtMilliseconds = notification.signedDate;
  if (requiresCanonicalSubscriptionStatus(notification.notificationType)) {
    const canonical = await canonicalSubscriptionStatus(
      transaction,
      environment,
      verifier,
    );
    assertAllowedAppleTransaction(canonical.transaction);
    const canonicalToken = canonicalUUID(
      canonical.transaction.appAccountToken ||
        canonical.renewal?.appAccountToken ||
        notificationToken,
    );
    if (canonicalToken !== notificationToken) {
      throw new RequestError(
        "Apple subscription account token changed unexpectedly.",
        409,
      );
    }
    canonicalTransaction = canonical.transaction;
    renewal = canonical.renewal;
    canonicalStatus = canonical.status;
    // This row represents a fresh server-side reconciliation, not merely the
    // earlier notification snapshot. Using the check time ensures a stale
    // revoked row from a racing device sync cannot suppress reinstatement.
    eventAtMilliseconds = canonical.checkedAtMilliseconds;
  }

  const accountStore = base44.asServiceRole.entities.AppStoreAccount;
  const lease = await acquireAppleAccountLease(accountStore, notificationToken);
  let leaseHeld = true;
  try {
    const owner = decideAppleNotificationOwner(
      lease.accounts.map((account) => account.user_id),
    );
    if (owner.kind !== "single_owner") {
      // Apple retries non-2xx notifications. A partially migrated or newly
      // created binding must converge before a provider event chooses an owner.
      throw new RequestError(
        "Apple account binding is not available yet.",
        503,
      );
    }

    const entitlement = normalizeAppleEntitlement({
      userID: owner.userID,
      transaction: canonicalTransaction,
      renewal,
      appleStatus: canonicalStatus,
      notificationType: notification.notificationType,
      notificationUUID: notification.notificationUUID,
      eventAtMilliseconds,
    });
    const persisted = await upsertAppleEntitlement(
      base44.asServiceRole.entities.Entitlement,
      entitlement,
      () => assertAppleAccountLease(accountStore, lease),
    );
    const released = await releaseAppleAccountLease(accountStore, lease);
    if (!released) {
      throw new RequestError(
        "Apple account binding changed concurrently. Retry shortly.",
        503,
      );
    }
    leaseHeld = false;

    return Response.json({
      success: true,
      entitlement: publicAppleEntitlement(persisted),
    });
  } finally {
    if (leaseHeld) {
      await bestEffortReleaseAppleAccountLease(accountStore, lease);
    }
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return Response.json({ error: "Method not allowed." }, { status: 405 });
  }

  try {
    const body = await parseJSONBody(req);
    const base44 = createClientFromRequest(req);
    const signedPayload = typeof body.signedPayload === "string"
      ? body.signedPayload
      : null;
    if (signedPayload) {
      return await handleNotification(base44, signedPayload);
    }

    switch (body.action) {
      case "prepare":
        return await handlePrepare(base44);
      case "sync_transaction":
        return await handleAuthenticatedSync(base44, body);
      default:
        throw new RequestError(
          "Unsupported App Store entitlement action.",
          400,
        );
    }
  } catch (error) {
    const status = error instanceof RequestError
      ? error.status
      : error instanceof AppleAccountLeaseGuardError
      ? 503
      : 500;
    const message = status >= 500
      ? "Unable to verify App Store entitlement."
      : errorMessage(error);
    console.error("app-store-entitlement failed:", errorMessage(error));
    return Response.json({ error: message }, { status });
  }
});
