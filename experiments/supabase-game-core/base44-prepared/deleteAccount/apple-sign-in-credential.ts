import {
  acquireBillingDeletionMarker,
  acquireBillingIssuanceMarker,
  acquireBillingWriterLease,
  assertBillingDeletionMarker,
  assertBillingWriterLease,
  type BillingIdentityLease,
  BillingIdentityLifecycleError,
  releaseBillingDeletionMarker,
  releaseBillingWriterLease,
} from "./billing-identity-lifecycle.ts";

const ENTITY_PAGE_SIZE = 100;
const TOKEN_VERSION = "spyclash-apple-refresh-token-v1";
const CREDENTIAL_KIND = "token";
const APPLE_REVOCATION_TIMEOUT_MILLISECONDS = 15_000;
const APPLE_REVOCATION_TOTAL_TIMEOUT_MILLISECONDS = 20_000;
const APPLE_REVOCATION_RETRY_DELAYS_MILLISECONDS = [250, 750] as const;
const encoder = new TextEncoder();
const decoder = new TextDecoder();

async function sleep(milliseconds: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, milliseconds));
}

export type AppleSignInCredentialState =
  | "pending"
  | "bound"
  | "revoking"
  | "revoked";

export type AppleSignInCredentialRecord = {
  id?: string;
  identity_key?: string;
  subject_key?: string;
  user_id?: string;
  credential_kind?: string;
  client_id?: string;
  state?: string;
  refresh_token_ciphertext?: string;
  refresh_token_iv?: string;
  created_at?: string;
  updated_at?: string;
  revoked_at?: string;
  manual_revocation_required?: boolean;
  binding_ticket_hash?: string;
  binding_ticket_expires_at?: string;
  revision?: string;
};

export type AppleSignInCredentialStore = {
  filter: (
    query: Record<string, unknown>,
    sort?: string,
    limit?: number,
    skip?: number,
  ) => Promise<AppleSignInCredentialRecord[]>;
  create: (
    data: Record<string, unknown>,
  ) => Promise<AppleSignInCredentialRecord>;
  updateMany: (
    query: Record<string, unknown>,
    update: { $set: Record<string, unknown> },
  ) => Promise<{ success?: boolean; updated?: number; has_more?: boolean }>;
  delete: (id: string) => Promise<{ success?: boolean }>;
};

export class AppleSignInCredentialError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "AppleSignInCredentialError";
  }
}

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function requireValue(
  value: unknown,
  label: string,
  maximumLength: number,
): string {
  const result = clean(value);
  if (!result || result.length > maximumLength) {
    throw new AppleSignInCredentialError(
      "apple_credential_invalid",
      500,
      `Apple credential ${label} is invalid.`,
    );
  }
  return result;
}

function normalizedEmail(value: unknown): string {
  const email = requireValue(value, "email", 320).toLowerCase();
  if (!email.includes("@")) {
    throw new AppleSignInCredentialError(
      "apple_credential_invalid",
      500,
      "Apple credential email is invalid.",
    );
  }
  return email;
}

function bytesToHex(bytes: ArrayBuffer | Uint8Array): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  return [...view].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function bytesToBase64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(
    /=+$/g,
    "",
  );
}

function base64URLToBytes(value: string): Uint8Array {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  const padding = "=".repeat((4 - normalized.length % 4) % 4);
  const binary = atob(normalized + padding);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function ownedBuffer(bytes: Uint8Array): ArrayBuffer {
  return Uint8Array.from(bytes).buffer;
}

async function sha256Hex(value: string): Promise<string> {
  return bytesToHex(
    await crypto.subtle.digest("SHA-256", encoder.encode(value)),
  );
}

function randomBase64URL(byteCount = 32): string {
  return bytesToBase64URL(crypto.getRandomValues(new Uint8Array(byteCount)));
}

function randomRevision(): string {
  return crypto.randomUUID();
}

function encryptionKeyBytes(value: string): Uint8Array {
  const secret = clean(value);
  if (/^[0-9a-fA-F]{64}$/.test(secret)) {
    return Uint8Array.from(
      secret.match(/.{2}/g) || [],
      (pair) => parseInt(pair, 16),
    );
  }
  try {
    const decoded = base64URLToBytes(secret);
    if (decoded.length === 32) return decoded;
  } catch {
    // Fall through to the fail-closed error below.
  }
  throw new AppleSignInCredentialError(
    "apple_credential_encryption_unavailable",
    503,
    "Apple credential encryption is unavailable.",
  );
}

async function importEncryptionKey(secret: string): Promise<CryptoKey> {
  const masterKey = await crypto.subtle.importKey(
    "raw",
    ownedBuffer(encryptionKeyBytes(secret)),
    "HKDF",
    false,
    ["deriveKey"],
  );
  return await crypto.subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: encoder.encode(TOKEN_VERSION),
      info: encoder.encode("apple-refresh-token-encryption"),
    },
    masterKey,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

async function importPseudonymKey(secretValue: string): Promise<CryptoKey> {
  const secret = encoder.encode(clean(secretValue));
  if (secret.length < 32) {
    throw new AppleSignInCredentialError(
      "apple_credential_pseudonym_unavailable",
      503,
      "Apple credential pseudonymization is unavailable.",
    );
  }
  return await crypto.subtle.importKey(
    "raw",
    ownedBuffer(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

function configuredPseudonymSecret(): string {
  return Deno.env.get("SPYCLASH_PSEUDONYM_KEY") || "";
}

function configuredEncryptionSecret(): string {
  // Reuse the provisioned master secret, but derive a separate Apple-token key
  // with HKDF. Versioned AES-GCM AAD then binds the exact credential context.
  return Deno.env.get("PUSH_TOKEN_ENCRYPTION_KEY") || "";
}

async function keyedDigest(
  namespace: string,
  value: string,
  pseudonymSecret = configuredPseudonymSecret(),
): Promise<string> {
  const key = await importPseudonymKey(pseudonymSecret);
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(`${TOKEN_VERSION}:${namespace}:${value}`),
  );
  return bytesToHex(signature);
}

export async function appleCredentialIdentityKey(
  emailValue: unknown,
  pseudonymSecret?: string,
): Promise<string> {
  return `apple-email:${await keyedDigest(
    "email",
    normalizedEmail(emailValue),
    pseudonymSecret,
  )}`;
}

async function appleCredentialSubjectKey(
  subjectValue: unknown,
  pseudonymSecret?: string,
): Promise<string> {
  return `apple-subject:${await keyedDigest(
    "subject",
    requireValue(subjectValue, "subject", 512),
    pseudonymSecret,
  )}`;
}

function credentialLifecycleIdentity(identityKey: string): string {
  return `${TOKEN_VERSION}:identity-lifecycle:${identityKey}`;
}

function tokenBinding(record: {
  identity_key?: unknown;
  subject_key?: unknown;
  client_id?: unknown;
}): string {
  return [
    TOKEN_VERSION,
    requireValue(record.identity_key, "identity key", 128),
    requireValue(record.subject_key, "subject key", 128),
    requireValue(record.client_id, "client id", 255),
  ].join(":");
}

async function encryptRefreshToken(
  tokenValue: unknown,
  binding: string,
  encryptionSecret = configuredEncryptionSecret(),
): Promise<{ ciphertext: string; iv: string }> {
  const token = requireValue(tokenValue, "refresh token", 20_000);
  const key = await importEncryptionKey(encryptionSecret);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: encoder.encode(binding) },
    key,
    encoder.encode(token),
  );
  return {
    ciphertext: bytesToBase64URL(new Uint8Array(encrypted)),
    iv: bytesToBase64URL(iv),
  };
}

async function decryptRefreshToken(
  record: AppleSignInCredentialRecord,
  encryptionSecret = configuredEncryptionSecret(),
): Promise<string> {
  const key = await importEncryptionKey(encryptionSecret);
  try {
    const decrypted = await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv: ownedBuffer(
          base64URLToBytes(
            requireValue(record.refresh_token_iv, "token iv", 128),
          ),
        ),
        additionalData: encoder.encode(tokenBinding(record)),
      },
      key,
      ownedBuffer(
        base64URLToBytes(
          requireValue(
            record.refresh_token_ciphertext,
            "token ciphertext",
            40_000,
          ),
        ),
      ),
    );
    return requireValue(decoder.decode(decrypted), "refresh token", 20_000);
  } catch (error) {
    if (error instanceof AppleSignInCredentialError) throw error;
    throw new AppleSignInCredentialError(
      "apple_credential_unavailable",
      503,
      "Stored Apple credentials could not be decrypted.",
    );
  }
}

async function allMatchingRecords(
  store: AppleSignInCredentialStore,
  filter: Record<string, unknown>,
): Promise<AppleSignInCredentialRecord[]> {
  const records: AppleSignInCredentialRecord[] = [];
  for (let skip = 0;; skip += ENTITY_PAGE_SIZE) {
    const page = await store.filter(
      filter,
      "created_date",
      ENTITY_PAGE_SIZE,
      skip,
    ) || [];
    records.push(...page);
    if (page.length < ENTITY_PAGE_SIZE) return records;
  }
}

function recordID(record: AppleSignInCredentialRecord): string {
  return requireValue(record.id, "record id", 512);
}

function recordRevision(record: AppleSignInCredentialRecord): string {
  return requireValue(record.revision, "revision", 512);
}

function recordState(
  record: AppleSignInCredentialRecord,
): AppleSignInCredentialState {
  const state = clean(record.state);
  if (
    state === "pending" || state === "bound" || state === "revoking" ||
    state === "revoked"
  ) return state;
  throw new AppleSignInCredentialError(
    "apple_credential_invalid",
    500,
    "Stored Apple credential state is invalid.",
  );
}

function assertTokenRecord(record: AppleSignInCredentialRecord): void {
  const kind = clean(record.credential_kind) || CREDENTIAL_KIND;
  if (kind !== CREDENTIAL_KIND) {
    throw new AppleSignInCredentialError(
      "apple_credential_invalid",
      500,
      "Stored Apple credential kind is invalid.",
    );
  }
}

async function exactRecord(
  store: AppleSignInCredentialStore,
  id: string,
): Promise<AppleSignInCredentialRecord | undefined> {
  const records = await allMatchingRecords(store, { id });
  if (records.length > 1) {
    throw new AppleSignInCredentialError(
      "apple_credential_ambiguous",
      503,
      "Apple credential persistence is ambiguous.",
    );
  }
  return records[0];
}

function patchMatches(
  record: AppleSignInCredentialRecord | undefined,
  patch: Record<string, unknown>,
): boolean {
  if (!record) return false;
  const values = record as Record<string, unknown>;
  return Object.entries(patch).every(([key, value]) => values[key] === value);
}

async function updateCredentialCAS(
  store: AppleSignInCredentialStore,
  record: AppleSignInCredentialRecord,
  patch: Record<string, unknown>,
  revisionFactory: () => string = randomRevision,
): Promise<AppleSignInCredentialRecord> {
  const id = recordID(record);
  const previousRevision = recordRevision(record);
  const nextRevision = requireValue(
    revisionFactory(),
    "next revision",
    512,
  );
  const candidate = { ...patch, revision: nextRevision };
  let result: { success?: boolean; updated?: number; has_more?: boolean };
  try {
    result = await store.updateMany(
      { id, revision: previousRevision },
      { $set: candidate },
    );
  } catch {
    try {
      const current = await exactRecord(store, id);
      if (patchMatches(current, candidate)) return current!;
    } catch {
      // Unknown persistence remains fail-closed below.
    }
    throw new AppleSignInCredentialError(
      "apple_credential_ambiguous",
      503,
      "Apple credential update could not be reconciled.",
    );
  }
  if (
    result?.success !== true || Number(result?.updated) !== 1 ||
    result?.has_more !== false
  ) {
    const current = await exactRecord(store, id);
    if (patchMatches(current, candidate)) return current!;
    const currentState = current ? recordState(current) : undefined;
    throw new AppleSignInCredentialError(
      currentState === "revoking" || currentState === "revoked"
        ? "apple_credential_deletion_in_progress"
        : "apple_credential_contention",
      503,
      "Apple credential changed concurrently.",
    );
  }
  return { ...record, ...candidate };
}

async function createCredentialReconciled(
  store: AppleSignInCredentialStore,
  data: Record<string, unknown>,
): Promise<AppleSignInCredentialRecord> {
  try {
    return await store.create(data);
  } catch {
    const created = await allMatchingRecords(store, {
      identity_key: data.identity_key,
      subject_key: data.subject_key,
      client_id: data.client_id,
      revision: data.revision,
    });
    if (created.length === 1) return created[0];
    throw new AppleSignInCredentialError(
      "apple_credential_ambiguous",
      503,
      "Apple credential creation could not be reconciled.",
    );
  }
}

function lifecycleError(error: unknown): never {
  if (error instanceof AppleSignInCredentialError) throw error;
  if (error instanceof BillingIdentityLifecycleError) {
    throw new AppleSignInCredentialError(
      error.code === "deletion_in_progress"
        ? "apple_credential_deletion_in_progress"
        : "apple_credential_lifecycle_unavailable",
      503,
      error.code === "deletion_in_progress"
        ? "Apple credential deletion is in progress."
        : "Apple credential lifecycle is temporarily unavailable.",
    );
  }
  throw error;
}

async function withWriterLease<T>(input: {
  lifecycleStore: any;
  subject: string;
  nowFactory: () => Date;
  operation: (lease: BillingIdentityLease) => Promise<T>;
}): Promise<T> {
  let lease: BillingIdentityLease;
  try {
    lease = await acquireBillingWriterLease(
      input.lifecycleStore,
      input.subject,
      input.nowFactory,
    );
  } catch (error) {
    lifecycleError(error);
  }
  try {
    const result = await input.operation(lease!);
    await releaseBillingWriterLease(
      input.lifecycleStore,
      lease!,
      input.nowFactory(),
    );
    return result;
  } catch (error) {
    try {
      await releaseBillingWriterLease(
        input.lifecycleStore,
        lease!,
        input.nowFactory(),
      );
    } catch {
      // Preserve the original failure. The bounded exact lease remains safe.
    }
    lifecycleError(error);
  }
}

export type AppleCredentialIdentityWriter = {
  identityKey: string;
  lease: BillingIdentityLease;
};

export async function withAppleCredentialIdentityWriter<T>(input: {
  lifecycleStore: any;
  email: unknown;
  now?: () => Date;
  pseudonymSecret?: string;
  operation: (writer: AppleCredentialIdentityWriter) => Promise<T>;
}): Promise<T> {
  const identityKey = await appleCredentialIdentityKey(
    input.email,
    input.pseudonymSecret,
  );
  const nowFactory = input.now || (() => new Date());
  const writer = (
    lease: BillingIdentityLease,
  ): AppleCredentialIdentityWriter => ({ identityKey, lease });
  return await withWriterLease({
    lifecycleStore: input.lifecycleStore,
    subject: credentialLifecycleIdentity(identityKey),
    nowFactory,
    operation: async (lease) => await input.operation(writer(lease)),
  });
}

export type AppleCredentialIssuanceBoundary = {
  identityKey: string;
  marker: BillingIdentityLease;
};

export async function withAppleCredentialIssuanceBoundary<T>(input: {
  lifecycleStore: any;
  email: unknown;
  now?: () => Date;
  pseudonymSecret?: string;
  operation: (boundary: AppleCredentialIssuanceBoundary) => Promise<T>;
  onOperationError: (
    error: unknown,
    boundary: AppleCredentialIssuanceBoundary,
  ) => Promise<"release" | "retain">;
}): Promise<T> {
  const identityKey = await appleCredentialIdentityKey(
    input.email,
    input.pseudonymSecret,
  );
  const nowFactory = input.now || (() => new Date());
  let marker: BillingIdentityLease;
  try {
    marker = await acquireBillingIssuanceMarker(
      input.lifecycleStore,
      credentialLifecycleIdentity(identityKey),
      nowFactory,
    );
  } catch (error) {
    lifecycleError(error);
  }
  const boundary = { identityKey, marker: marker! };

  let result: T;
  try {
    result = await input.operation(boundary);
  } catch (error) {
    let disposition: "release" | "retain" = "retain";
    try {
      disposition = await input.onOperationError(error, boundary);
    } catch {
      // Unknown compensation retains the deletion-state issuance boundary.
    }
    if (disposition === "release") {
      try {
        await releaseBillingDeletionMarker(
          input.lifecycleStore,
          marker!,
          nowFactory(),
        );
      } catch (releaseError) {
        lifecycleError(releaseError);
      }
    }
    lifecycleError(error);
  }

  try {
    await releaseBillingDeletionMarker(
      input.lifecycleStore,
      marker!,
      nowFactory(),
    );
  } catch (releaseError) {
    lifecycleError(releaseError);
  }
  return result!;
}

export async function persistPendingAppleSignInCredential(input: {
  store: AppleSignInCredentialStore;
  lifecycleStore: any;
  email: unknown;
  subject: unknown;
  clientID: unknown;
  refreshToken: unknown;
  now?: () => Date;
  pseudonymSecret?: string;
  encryptionSecret?: string;
  randomTicket?: () => string;
  revisionFactory?: () => string;
  identityWriter?: AppleCredentialIdentityWriter;
  issuanceBoundary?: AppleCredentialIssuanceBoundary;
}): Promise<{ bindingTicket: string; recordIDs: string[] }> {
  const identityKey = await appleCredentialIdentityKey(
    input.email,
    input.pseudonymSecret,
  );
  const subjectKey = await appleCredentialSubjectKey(
    input.subject,
    input.pseudonymSecret,
  );
  const clientID = requireValue(input.clientID, "client id", 255);
  const binding = tokenBinding({
    identity_key: identityKey,
    subject_key: subjectKey,
    client_id: clientID,
  });
  const encrypted = await encryptRefreshToken(
    input.refreshToken,
    binding,
    input.encryptionSecret,
  );
  const nowFactory = input.now || (() => new Date());
  const nowDate = nowFactory();
  const now = nowDate.toISOString();
  const bindingTicket = requireValue(
    (input.randomTicket || randomBase64URL)(),
    "binding ticket",
    512,
  );
  const bindingTicketHash = await sha256Hex(
    `${TOKEN_VERSION}:binding-ticket:${bindingTicket}`,
  );
  const bindingTicketExpiresAt = new Date(
    nowDate.getTime() + 5 * 60 * 1_000,
  ).toISOString();
  const revisionFactory = input.revisionFactory || randomRevision;

  const persistWithLease = async (
    lease: BillingIdentityLease,
    kind: "writer" | "issuance",
  ) => {
    const assertLease = async () => {
      if (kind === "issuance") {
        await assertBillingDeletionMarker(
          input.lifecycleStore,
          lease,
          nowFactory(),
        );
      } else {
        await assertBillingWriterLease(
          input.lifecycleStore,
          lease,
          nowFactory(),
        );
      }
    };
    await assertLease();
    const identityRecords = await allMatchingRecords(input.store, {
      identity_key: identityKey,
    });
    for (const record of identityRecords) {
      assertTokenRecord(record);
      const state = recordState(record);
      if (state === "revoking" || state === "revoked") {
        throw new AppleSignInCredentialError(
          "apple_credential_deletion_in_progress",
          503,
          "Apple credential deletion is in progress.",
        );
      }
    }
    const matching = identityRecords.filter((record) =>
      clean(record.subject_key) === subjectKey &&
      clean(record.client_id) === clientID
    );

    if (!matching.length) {
      await assertLease();
      const created = await createCredentialReconciled(input.store, {
        identity_key: identityKey,
        subject_key: subjectKey,
        credential_kind: CREDENTIAL_KIND,
        client_id: clientID,
        state: "pending",
        refresh_token_ciphertext: encrypted.ciphertext,
        refresh_token_iv: encrypted.iv,
        binding_ticket_hash: bindingTicketHash,
        binding_ticket_expires_at: bindingTicketExpiresAt,
        manual_revocation_required: false,
        created_at: now,
        updated_at: now,
        revision: requireValue(
          revisionFactory(),
          "initial revision",
          512,
        ),
      });
      return { bindingTicket, recordIDs: [recordID(created)] };
    }

    const recordIDs: string[] = [];
    for (const record of matching) {
      await assertLease();
      const updated = await updateCredentialCAS(
        input.store,
        record,
        {
          refresh_token_ciphertext: encrypted.ciphertext,
          refresh_token_iv: encrypted.iv,
          binding_ticket_hash: bindingTicketHash,
          binding_ticket_expires_at: bindingTicketExpiresAt,
          manual_revocation_required: false,
          updated_at: now,
        },
        revisionFactory,
      );
      recordIDs.push(recordID(updated));
    }
    return { bindingTicket, recordIDs };
  };

  if (input.identityWriter && input.issuanceBoundary) {
    throw new AppleSignInCredentialError(
      "apple_credential_invalid",
      500,
      "Apple credential received conflicting identity boundaries.",
    );
  }
  if (input.identityWriter) {
    if (input.identityWriter.identityKey !== identityKey) {
      throw new AppleSignInCredentialError(
        "apple_credential_identity_mismatch",
        409,
        "Apple credential writer does not match the verified identity.",
      );
    }
    return await persistWithLease(input.identityWriter.lease, "writer");
  }
  if (input.issuanceBoundary) {
    if (input.issuanceBoundary.identityKey !== identityKey) {
      throw new AppleSignInCredentialError(
        "apple_credential_identity_mismatch",
        409,
        "Apple credential issuance does not match the verified identity.",
      );
    }
    return await persistWithLease(
      input.issuanceBoundary.marker,
      "issuance",
    );
  }

  return await withWriterLease({
    lifecycleStore: input.lifecycleStore,
    subject: credentialLifecycleIdentity(identityKey),
    nowFactory,
    operation: async (lease) => await persistWithLease(lease, "writer"),
  });
}

export async function assertTrackedAppleSignInCredential(input: {
  store: AppleSignInCredentialStore;
  lifecycleStore: any;
  email: unknown;
  subject: unknown;
  clientID: unknown;
  identityWriter: AppleCredentialIdentityWriter;
  now?: () => Date;
  pseudonymSecret?: string;
}): Promise<void> {
  const identityKey = await appleCredentialIdentityKey(
    input.email,
    input.pseudonymSecret,
  );
  if (input.identityWriter.identityKey !== identityKey) {
    throw new AppleSignInCredentialError(
      "apple_credential_identity_mismatch",
      401,
      "Apple credential guard does not match the authenticated identity.",
    );
  }
  const subjectKey = await appleCredentialSubjectKey(
    input.subject,
    input.pseudonymSecret,
  );
  const clientID = requireValue(input.clientID, "client id", 255);
  const nowFactory = input.now || (() => new Date());
  await assertBillingWriterLease(
    input.lifecycleStore,
    input.identityWriter.lease,
    nowFactory(),
  );
  const records = await allMatchingRecords(input.store, {
    identity_key: identityKey,
  });
  const tracked = records.filter((record) => {
    assertTokenRecord(record);
    const state = recordState(record);
    return clean(record.subject_key) === subjectKey &&
      clean(record.client_id) === clientID &&
      (state === "pending" || state === "bound") &&
      Boolean(clean(record.refresh_token_ciphertext)) &&
      Boolean(clean(record.refresh_token_iv));
  });
  if (!tracked.length) {
    throw new AppleSignInCredentialError(
      "apple_credential_untracked",
      401,
      "Apple credential is no longer active for this identity.",
    );
  }
}

async function validatedBindingRecords(input: {
  store: AppleSignInCredentialStore;
  identityKey: string;
  bindingTicketHash: string;
  now: Date;
  expectedOwner?: string;
  requireUnowned?: boolean;
}): Promise<AppleSignInCredentialRecord[]> {
  const records = await allMatchingRecords(input.store, {
    binding_ticket_hash: input.bindingTicketHash,
  });
  if (!records.length) {
    throw new AppleSignInCredentialError(
      "apple_credential_binding_invalid",
      401,
      "Apple credential binding is invalid or expired.",
    );
  }
  for (const record of records) {
    assertTokenRecord(record);
    if (clean(record.identity_key) !== input.identityKey) {
      throw new AppleSignInCredentialError(
        "apple_credential_binding_invalid",
        401,
        "Apple credential binding does not match the authenticated identity.",
      );
    }
    const state = recordState(record);
    const existingOwner = clean(record.user_id);
    if (state === "revoking" || state === "revoked") {
      throw new AppleSignInCredentialError(
        "apple_credential_deletion_in_progress",
        503,
        "Apple credential deletion is in progress.",
      );
    }
    if (input.requireUnowned && (existingOwner || state !== "pending")) {
      throw new AppleSignInCredentialError(
        "apple_credential_owner_conflict",
        409,
        "Apple credentials are already bound to an account.",
      );
    }
    if (
      input.expectedOwner && existingOwner &&
      existingOwner !== input.expectedOwner
    ) {
      throw new AppleSignInCredentialError(
        "apple_credential_owner_conflict",
        409,
        "Apple credentials are already bound to another account.",
      );
    }
    const alreadyBoundToExpectedOwner = Boolean(input.expectedOwner) &&
      state === "bound" && existingOwner === input.expectedOwner;
    const expiresAt = Date.parse(clean(record.binding_ticket_expires_at));
    if (
      !alreadyBoundToExpectedOwner &&
      (!Number.isFinite(expiresAt) || expiresAt <= input.now.getTime())
    ) {
      throw new AppleSignInCredentialError(
        "apple_credential_binding_invalid",
        401,
        "Apple credential binding is invalid or expired.",
      );
    }
  }
  return records;
}

export async function withPendingAppleCredentialBindingIdentityWriter<T>(
  input: {
    store: AppleSignInCredentialStore;
    lifecycleStore: any;
    email: unknown;
    bindingTicket: unknown;
    now?: () => Date;
    pseudonymSecret?: string;
    operation: (writer: AppleCredentialIdentityWriter) => Promise<T>;
  },
): Promise<T> {
  const identityKey = await appleCredentialIdentityKey(
    input.email,
    input.pseudonymSecret,
  );
  const bindingTicket = requireValue(
    input.bindingTicket,
    "binding ticket",
    512,
  );
  const bindingTicketHash = await sha256Hex(
    `${TOKEN_VERSION}:binding-ticket:${bindingTicket}`,
  );
  const nowFactory = input.now || (() => new Date());
  return await withAppleCredentialIdentityWriter({
    lifecycleStore: input.lifecycleStore,
    email: input.email,
    now: nowFactory,
    pseudonymSecret: input.pseudonymSecret,
    operation: async (identityWriter) => {
      await assertBillingWriterLease(
        input.lifecycleStore,
        identityWriter.lease,
        nowFactory(),
      );
      await validatedBindingRecords({
        store: input.store,
        identityKey,
        bindingTicketHash,
        now: nowFactory(),
        requireUnowned: true,
      });
      return await input.operation(identityWriter);
    },
  });
}

export async function bindPendingAppleSignInCredentials(input: {
  store: AppleSignInCredentialStore;
  lifecycleStore: any;
  email: unknown;
  userID: unknown;
  bindingTicket: unknown;
  now?: () => Date;
  pseudonymSecret?: string;
  revisionFactory?: () => string;
  identityWriter?: AppleCredentialIdentityWriter;
}): Promise<{ bound: number }> {
  const identityKey = await appleCredentialIdentityKey(
    input.email,
    input.pseudonymSecret,
  );
  const userID = requireValue(input.userID, "user id", 512);
  const bindingTicket = requireValue(
    input.bindingTicket,
    "binding ticket",
    512,
  );
  const bindingTicketHash = await sha256Hex(
    `${TOKEN_VERSION}:binding-ticket:${bindingTicket}`,
  );
  const nowFactory = input.now || (() => new Date());
  const revisionFactory = input.revisionFactory || randomRevision;

  if (
    input.identityWriter?.identityKey !== undefined &&
    input.identityWriter.identityKey !== identityKey
  ) {
    throw new AppleSignInCredentialError(
      "apple_credential_identity_mismatch",
      409,
      "Apple credential writer does not match the authenticated identity.",
    );
  }

  const bindWithLeases = async (
    userLease: BillingIdentityLease,
    identityWriter: AppleCredentialIdentityWriter,
  ) => {
    await assertBillingWriterLease(
      input.lifecycleStore,
      userLease,
      nowFactory(),
    );
    await assertBillingWriterLease(
      input.lifecycleStore,
      identityWriter.lease,
      nowFactory(),
    );
    const records = await validatedBindingRecords({
      store: input.store,
      identityKey,
      bindingTicketHash,
      now: nowFactory(),
      expectedOwner: userID,
    });

    let bound = 0;
    for (const record of records) {
      const wasAlreadyBound = recordState(record) === "bound" &&
        clean(record.user_id) === userID;
      await assertBillingWriterLease(
        input.lifecycleStore,
        userLease,
        nowFactory(),
      );
      await assertBillingWriterLease(
        input.lifecycleStore,
        identityWriter.lease,
        nowFactory(),
      );
      await updateCredentialCAS(
        input.store,
        record,
        {
          user_id: userID,
          state: "bound",
          updated_at: nowFactory().toISOString(),
        },
        revisionFactory,
      );
      if (!wasAlreadyBound) bound += 1;
    }
    return { bound };
  };

  return await withWriterLease({
    lifecycleStore: input.lifecycleStore,
    subject: userID,
    nowFactory,
    operation: async (userLease) => {
      if (input.identityWriter) {
        return await bindWithLeases(userLease, input.identityWriter);
      }
      // Deletion takes the user marker before the Apple-identity marker. Bind
      // uses the same lock order so a ticket cannot cross either boundary.
      return await withAppleCredentialIdentityWriter({
        lifecycleStore: input.lifecycleStore,
        email: input.email,
        now: nowFactory,
        pseudonymSecret: input.pseudonymSecret,
        operation: async (identityWriter) =>
          await bindWithLeases(userLease, identityWriter),
      });
    },
  });
}

function isRetryableAppleStatus(status: number): boolean {
  return status === 408 || status === 425 || status === 429 || status >= 500;
}

async function terminalCredentialUpdate(input: {
  store: AppleSignInCredentialStore;
  lifecycleStore: any;
  lifecycleLease: BillingIdentityLease;
  record: AppleSignInCredentialRecord;
  userID: string;
  manual: boolean;
  nowFactory: () => Date;
  revisionFactory: () => string;
}): Promise<AppleSignInCredentialRecord> {
  await assertBillingDeletionMarker(
    input.lifecycleStore,
    input.lifecycleLease,
    input.nowFactory(),
  );
  const revokedAt = input.nowFactory().toISOString();
  return await updateCredentialCAS(
    input.store,
    input.record,
    {
      user_id: input.userID,
      state: "revoked",
      refresh_token_ciphertext: "",
      refresh_token_iv: "",
      binding_ticket_hash: "",
      binding_ticket_expires_at: "",
      manual_revocation_required: input.manual,
      revoked_at: revokedAt,
      updated_at: revokedAt,
    },
    input.revisionFactory,
  );
}

async function deletionIdentityKey(input: {
  email: unknown;
  pseudonymSecret?: string;
}): Promise<{ identityKey: string; pseudonymUnavailable: boolean }> {
  try {
    return {
      identityKey: await appleCredentialIdentityKey(
        input.email,
        input.pseudonymSecret,
      ),
      pseudonymUnavailable: false,
    };
  } catch (error) {
    if (
      !(error instanceof AppleSignInCredentialError) ||
      error.code !== "apple_credential_pseudonym_unavailable"
    ) throw error;
    // Broker persistence also fails while this key is unavailable. Use a
    // temporary one-way lifecycle subject so account deletion can still honor
    // Apple's requirement instead of trapping the authenticated user.
    return {
      identityKey: `apple-email-unavailable:${await sha256Hex(
        normalizedEmail(input.email),
      )}`,
      pseudonymUnavailable: true,
    };
  }
}

export async function revokeAppleSignInCredentials(input: {
  store: AppleSignInCredentialStore;
  lifecycleStore: any;
  email: unknown;
  userID: unknown;
  createClientSecret: (clientID: string) => Promise<string>;
  fetcher?: typeof fetch;
  beforeRevokeRequest?: () => void;
  sleepBeforeRetry?: (milliseconds: number) => Promise<void>;
  now?: () => Date;
  pseudonymSecret?: string;
  encryptionSecret?: string;
  revisionFactory?: () => string;
  onDeletionMarkerAcquired?: (marker: BillingIdentityLease) => void;
}): Promise<{
  identityDeletionMarker: BillingIdentityLease;
  manualRevocationRequired: boolean;
  recordIDs: string[];
  revoked: number;
}> {
  const userID = requireValue(input.userID, "user id", 512);
  const nowFactory = input.now || (() => new Date());
  const revisionFactory = input.revisionFactory || randomRevision;
  const sleepBeforeRetry = input.sleepBeforeRetry || sleep;
  const identity = await deletionIdentityKey(input);
  let identityDeletionMarker: BillingIdentityLease;
  try {
    identityDeletionMarker = await acquireBillingDeletionMarker(
      input.lifecycleStore,
      credentialLifecycleIdentity(identity.identityKey),
      nowFactory,
    );
  } catch (error) {
    lifecycleError(error);
  }
  input.onDeletionMarkerAcquired?.(identityDeletionMarker!);

  try {
    await assertBillingDeletionMarker(
      input.lifecycleStore,
      identityDeletionMarker!,
      nowFactory(),
    );
    const owned = await allMatchingRecords(input.store, { user_id: userID });
    const identityRecords = identity.pseudonymUnavailable
      ? []
      : await allMatchingRecords(input.store, {
        identity_key: identity.identityKey,
      });
    // A verified email can back separate Base44 identities. Include this
    // account's bound credentials plus unclaimed Apple credentials, but never
    // another account's bound token merely because its email key matches.
    const records = [
      ...owned,
      ...identityRecords.filter((record) => {
        const owner = clean(record.user_id);
        return !owner || owner === userID;
      }),
    ].reduce((unique, record) => {
      assertTokenRecord(record);
      unique.set(recordID(record), record);
      return unique;
    }, new Map<string, AppleSignInCredentialRecord>());

    const fetcher = input.fetcher || fetch;
    const recordIDs: string[] = [];
    let manualRevocationRequired = identity.pseudonymUnavailable;
    let revoked = 0;
    // A retained revoking record proves this account deletion already spent a
    // fail-closed lease window. Every remaining credential still follows the
    // bounded Apple retry path, but one fresh record must not open another lease.
    const resumedDeletionCycle = [...records.values()].some((record) =>
      recordState(record) === "revoking"
    );
    const revocationDeadline = Date.now() +
      APPLE_REVOCATION_TOTAL_TIMEOUT_MILLISECONDS;

    for (const initialRecord of records.values()) {
      const id = recordID(initialRecord);
      recordIDs.push(id);
      let record = initialRecord;
      const state = recordState(record);
      if (state === "revoked") {
        manualRevocationRequired ||= record.manual_revocation_required === true;
        continue;
      }

      if (state !== "revoking") {
        await assertBillingDeletionMarker(
          input.lifecycleStore,
          identityDeletionMarker!,
          nowFactory(),
        );
        record = await updateCredentialCAS(
          input.store,
          record,
          {
            user_id: userID,
            state: "revoking",
            updated_at: nowFactory().toISOString(),
          },
          revisionFactory,
        );
      }

      let token: string;
      let clientID: string;
      try {
        clientID = requireValue(record.client_id, "client id", 255);
        token = await decryptRefreshToken(record, input.encryptionSecret);
      } catch {
        record = await terminalCredentialUpdate({
          store: input.store,
          lifecycleStore: input.lifecycleStore,
          lifecycleLease: identityDeletionMarker!,
          record,
          userID,
          manual: true,
          nowFactory,
          revisionFactory,
        });
        manualRevocationRequired = true;
        continue;
      }

      let clientSecret: string;
      try {
        clientSecret = requireValue(
          await input.createClientSecret(clientID),
          "client secret",
          20_000,
        );
      } catch (error) {
        if (error instanceof AppleSignInCredentialError) {
          record = await terminalCredentialUpdate({
            store: input.store,
            lifecycleStore: input.lifecycleStore,
            lifecycleLease: identityDeletionMarker!,
            record,
            userID,
            manual: true,
            nowFactory,
            revisionFactory,
          });
          manualRevocationRequired = true;
          continue;
        }
        if (resumedDeletionCycle) {
          console.warn(
            "Apple revocation signer remained unavailable after a resumed deletion cycle; manual revocation required.",
          );
          record = await terminalCredentialUpdate({
            store: input.store,
            lifecycleStore: input.lifecycleStore,
            lifecycleLease: identityDeletionMarker!,
            record,
            userID,
            manual: true,
            nowFactory,
            revisionFactory,
          });
          manualRevocationRequired = true;
          continue;
        }
        throw new AppleSignInCredentialError(
          "apple_revocation_unavailable",
          503,
          "Apple revocation credentials are temporarily unavailable.",
        );
      }

      const body = new URLSearchParams({
        client_id: clientID,
        client_secret: clientSecret,
        token,
        token_type_hint: "refresh_token",
      });
      // Retry only while this invocation still owns the exact deletion
      // boundary. A lost response may mean Apple already revoked the token,
      // so cross-invocation retries remain blocked by the retained lease.
      let response: Response | undefined;
      let requestAttempted = false;
      for (
        let attempt = 0;
        attempt <= APPLE_REVOCATION_RETRY_DELAYS_MILLISECONDS.length;
        attempt += 1
      ) {
        const remainingMilliseconds = revocationDeadline - Date.now();
        if (remainingMilliseconds <= 0) break;
        if (!requestAttempted) input.beforeRevokeRequest?.();
        requestAttempted = true;
        try {
          response = await fetcher("https://appleid.apple.com/auth/revoke", {
            method: "POST",
            headers: {
              Accept: "application/json",
              "Content-Type": "application/x-www-form-urlencoded",
            },
            body,
            redirect: "error",
            signal: AbortSignal.timeout(
              Math.min(
                APPLE_REVOCATION_TIMEOUT_MILLISECONDS,
                remainingMilliseconds,
              ),
            ),
          });
        } catch {
          response = undefined;
        }

        if (
          response &&
          (response.ok || !isRetryableAppleStatus(response.status))
        ) break;

        const retryDelay = APPLE_REVOCATION_RETRY_DELAYS_MILLISECONDS[attempt];
        if (
          retryDelay === undefined ||
          Date.now() + retryDelay >= revocationDeadline
        ) {
          break;
        }
        await sleepBeforeRetry(retryDelay);
      }
      if (
        !response ||
        (!response.ok && isRetryableAppleStatus(response.status))
      ) {
        if (resumedDeletionCycle && requestAttempted) {
          console.warn(
            "Apple token revocation remained unavailable after a resumed deletion cycle; manual revocation required.",
          );
          record = await terminalCredentialUpdate({
            store: input.store,
            lifecycleStore: input.lifecycleStore,
            lifecycleLease: identityDeletionMarker!,
            record,
            userID,
            manual: true,
            nowFactory,
            revisionFactory,
          });
          manualRevocationRequired = true;
          continue;
        }
        throw new AppleSignInCredentialError(
          "apple_revocation_unavailable",
          503,
          "Apple token revocation is temporarily unavailable.",
        );
      }
      const manual = !response.ok;
      record = await terminalCredentialUpdate({
        store: input.store,
        lifecycleStore: input.lifecycleStore,
        lifecycleLease: identityDeletionMarker!,
        record,
        userID,
        manual,
        nowFactory,
        revisionFactory,
      });
      manualRevocationRequired ||= manual;
      if (!manual) revoked += 1;
    }

    if (!records.size) manualRevocationRequired = true;
    return {
      identityDeletionMarker: identityDeletionMarker!,
      manualRevocationRequired,
      recordIDs,
      revoked,
    };
  } catch (error) {
    // Never reopen the identity writer boundary after a partial revocation.
    // A later deletion retry can resume this exact deleting lifecycle after
    // its bounded lease expires.
    lifecycleError(error);
  }
}

export async function deleteAppleSignInCredentialRecords(
  store: AppleSignInCredentialStore,
  recordIDs: readonly string[],
): Promise<void> {
  for (const idValue of new Set(recordIDs)) {
    const id = clean(idValue);
    if (!id) continue;
    try {
      const result = await store.delete(id);
      if (result?.success !== true) {
        throw new Error("Apple credential delete was not confirmed.");
      }
    } catch {
      try {
        if (!(await exactRecord(store, id))) continue;
      } catch (error) {
        if (error instanceof AppleSignInCredentialError) throw error;
        throw new AppleSignInCredentialError(
          "apple_credential_cleanup_ambiguous",
          503,
          "Apple credential cleanup could not be reconciled.",
        );
      }
      throw new AppleSignInCredentialError(
        "apple_credential_cleanup_failed",
        503,
        "Apple credential cleanup is incomplete.",
      );
    }
  }
}
