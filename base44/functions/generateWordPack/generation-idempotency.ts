import {
  normalizeGeneratedWordPack,
  normalizeWordPackUserID,
  type PreparedWordPackCacheRequest,
  type WordPackEntityStore,
  type WordPackResult,
} from "./generation-cache.ts";

const REQUEST_KEY_DOMAIN = "spyclash:ai-word-pack-request:v1";
const REQUEST_FINGERPRINT_DOMAIN =
  "spyclash:ai-word-pack-request-fingerprint:v1";
const CONTROL_CHARACTERS = /[\u0000-\u001F\u007F-\u009F]/u;
const DAY_MILLISECONDS = 24 * 60 * 60 * 1_000;

export const DEFAULT_WORD_PACK_IDEMPOTENCY_TTL_MILLISECONDS = DAY_MILLISECONDS;

export class InvalidWordPackIdempotencyInputError extends Error {
  readonly status = 400 as const;
  readonly code = "invalid_word_pack_request_id" as const;

  constructor(message: string) {
    super(message);
    this.name = "InvalidWordPackIdempotencyInputError";
  }
}

export class WordPackIdempotencyConflictError extends Error {
  readonly status = 409 as const;
  readonly code = "word_pack_request_id_conflict" as const;
  readonly retryable = false as const;

  constructor() {
    super("This request_id was already used for different word-pack inputs.");
    this.name = "WordPackIdempotencyConflictError";
  }
}

export class WordPackIdempotencyUnavailableError extends Error {
  readonly status = 503 as const;
  readonly code = "word_pack_idempotency_unavailable" as const;
  readonly retryable = true as const;

  constructor() {
    super(
      "Request replay protection is temporarily unavailable. Try again shortly.",
    );
    this.name = "WordPackIdempotencyUnavailableError";
  }
}

export type PreparedWordPackIdempotency = {
  userID: string;
  requestID: string;
  /** One-way exact key scoped to user + request_id. */
  requestKey: string;
  /** Detects reuse of request_id with different normalized request inputs. */
  requestFingerprint: string;
};

export type WordPackRequestResultRecord = {
  id?: string;
  request_key?: string;
  user_id?: string;
  request_id?: string;
  request_fingerprint?: string;
  result_category?: string;
  result_words?: unknown[];
  exhausted?: boolean;
  cache_variant_key?: string;
  completed_at?: string;
  expires_at?: string;
  created_date?: string;
};

export type StoredWordPackRequestResult = WordPackResult & {
  requestKey: string;
  requestFingerprint: string;
  cacheVariantKey?: string;
  recordID?: string;
  completedAt: string;
  expiresAt: string;
};

function requireOpaqueIdentifier(
  value: unknown,
  field: string,
  maximumLength: number,
): string {
  const normalized = String(value ?? "").normalize("NFKC").trim();
  if (!normalized) {
    throw new InvalidWordPackIdempotencyInputError(`${field} is required.`);
  }
  if (CONTROL_CHARACTERS.test(normalized)) {
    throw new InvalidWordPackIdempotencyInputError(
      `${field} cannot contain control characters.`,
    );
  }
  if (normalized.length > maximumLength) {
    throw new InvalidWordPackIdempotencyInputError(
      `${field} must be at most ${maximumLength} characters.`,
    );
  }
  return normalized;
}

function framedMaterial(domain: string, values: readonly string[]): string {
  const encoder = new TextEncoder();
  return [domain, ...values].map((value) =>
    `${encoder.encode(value).byteLength}:${value}`
  ).join("|");
}

async function digestKey(
  prefix: string,
  domain: string,
  values: readonly string[],
): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(framedMaterial(domain, values)),
  );
  const encoded = btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/u, "");
  return `${prefix}_${encoded}`;
}

export async function prepareWordPackIdempotency(input: {
  userID: unknown;
  requestID: unknown;
  request: PreparedWordPackCacheRequest;
}): Promise<PreparedWordPackIdempotency> {
  const userID = normalizeWordPackUserID(input.userID);
  if (userID !== input.request.userID) {
    throw new InvalidWordPackIdempotencyInputError(
      "Idempotency user must match the prepared cache request user.",
    );
  }
  const requestID = requireOpaqueIdentifier(
    input.requestID,
    "request_id",
    128,
  );
  const [requestKey, requestFingerprint] = await Promise.all([
    digestKey("awr1", REQUEST_KEY_DOMAIN, [userID, requestID]),
    digestKey("awf1", REQUEST_FINGERPRINT_DOMAIN, [
      input.request.cacheKey,
      String(input.request.requestedCount),
      ...input.request.exclusionKeys,
    ]),
  ]);
  return {
    userID,
    requestID,
    requestKey,
    requestFingerprint,
  };
}

function timestamp(value: unknown): number | null {
  const parsed = Date.parse(String(value ?? ""));
  return Number.isFinite(parsed) ? parsed : null;
}

function validTTL(value: number): number {
  if (!Number.isFinite(value) || value <= 0) {
    throw new InvalidWordPackIdempotencyInputError(
      "Idempotency TTL must be a positive number of milliseconds.",
    );
  }
  return Math.trunc(value);
}

function recordOrder(
  left: WordPackRequestResultRecord,
  right: WordPackRequestResultRecord,
): number {
  for (const field of ["completed_at", "created_date"] as const) {
    const order = String(left[field] ?? "").localeCompare(
      String(right[field] ?? ""),
    );
    if (order !== 0) return order;
  }
  return String(left.id ?? "").localeCompare(String(right.id ?? ""));
}

export function selectIdempotentWordPackResult(input: {
  records: WordPackRequestResultRecord[];
  identity: PreparedWordPackIdempotency;
  now?: Date;
}): StoredWordPackRequestResult | null {
  const nowTimestamp = (input.now ?? new Date()).getTime();
  if (!Number.isFinite(nowTimestamp)) {
    throw new InvalidWordPackIdempotencyInputError(
      "Idempotency lookup date is invalid.",
    );
  }

  const active = input.records.filter((record) => {
    if (record.request_key !== input.identity.requestKey) return false;
    const expiresAt = timestamp(record.expires_at);
    return expiresAt !== null && expiresAt > nowTimestamp;
  });

  if (
    active.some((record) =>
      record.user_id !== input.identity.userID ||
      record.request_id !== input.identity.requestID ||
      record.request_fingerprint !== input.identity.requestFingerprint
    )
  ) {
    throw new WordPackIdempotencyConflictError();
  }

  for (const record of [...active].sort(recordOrder)) {
    const completedAt = timestamp(record.completed_at);
    const expiresAt = timestamp(record.expires_at);
    if (completedAt === null || expiresAt === null) continue;
    let result: WordPackResult;
    try {
      result = normalizeGeneratedWordPack({
        category: record.result_category,
        words: record.result_words,
        exhausted: record.exhausted,
      });
    } catch {
      continue;
    }
    return {
      ...result,
      requestKey: input.identity.requestKey,
      requestFingerprint: input.identity.requestFingerprint,
      ...(record.cache_variant_key
        ? { cacheVariantKey: record.cache_variant_key }
        : {}),
      ...(record.id ? { recordID: record.id } : {}),
      completedAt: new Date(completedAt).toISOString(),
      expiresAt: new Date(expiresAt).toISOString(),
    };
  }
  return null;
}

export async function buildWordPackRequestResultRecord(input: {
  identity: PreparedWordPackIdempotency;
  result: {
    category: unknown;
    words: unknown;
    exhausted: unknown;
    cacheVariantKey?: unknown;
  };
  now?: Date;
  ttlMilliseconds?: number;
}): Promise<
  Required<
    Omit<
      WordPackRequestResultRecord,
      "id" | "created_date" | "cache_variant_key"
    >
  > & { cache_variant_key?: string }
> {
  const result = normalizeGeneratedWordPack(input.result);
  const completedAt = input.now ?? new Date();
  if (!Number.isFinite(completedAt.getTime())) {
    throw new InvalidWordPackIdempotencyInputError(
      "Idempotency completion date is invalid.",
    );
  }
  const ttl = validTTL(
    input.ttlMilliseconds ?? DEFAULT_WORD_PACK_IDEMPOTENCY_TTL_MILLISECONDS,
  );
  const expiresAt = new Date(completedAt.getTime() + ttl);
  if (!Number.isFinite(expiresAt.getTime())) {
    throw new InvalidWordPackIdempotencyInputError(
      "Idempotency expiry is invalid.",
    );
  }
  const cacheVariantKey = String(input.result.cacheVariantKey ?? "").trim();
  return {
    request_key: input.identity.requestKey,
    user_id: input.identity.userID,
    request_id: input.identity.requestID,
    request_fingerprint: input.identity.requestFingerprint,
    result_category: result.category,
    result_words: result.words,
    exhausted: result.exhausted,
    ...(cacheVariantKey ? { cache_variant_key: cacheVariantKey } : {}),
    completed_at: completedAt.toISOString(),
    expires_at: expiresAt.toISOString(),
  };
}

export async function lookupIdempotentWordPackResult(input: {
  store: Pick<WordPackEntityStore<WordPackRequestResultRecord>, "filter">;
  identity: PreparedWordPackIdempotency;
  now?: Date;
}): Promise<StoredWordPackRequestResult | null> {
  const records = await input.store.filter(
    { request_key: input.identity.requestKey },
    "-created_date",
    20,
    0,
  );
  return selectIdempotentWordPackResult({
    records,
    identity: input.identity,
    now: input.now,
  });
}

export async function persistIdempotentWordPackResult(input: {
  store: WordPackEntityStore<WordPackRequestResultRecord>;
  identity: PreparedWordPackIdempotency;
  result: {
    category: unknown;
    words: unknown;
    exhausted: unknown;
    cacheVariantKey?: unknown;
  };
  now?: Date;
  ttlMilliseconds?: number;
}): Promise<StoredWordPackRequestResult> {
  const existing = await lookupIdempotentWordPackResult(input);
  if (existing) return existing;

  const record = await buildWordPackRequestResultRecord(input);
  await input.store.create(record);

  // Re-read so simultaneous equivalent completions converge on the same
  // oldest canonical result. Base44 schemas do not expose a unique index.
  const canonical = await lookupIdempotentWordPackResult(input);
  if (!canonical) {
    throw new Error("Stored word-pack idempotency result could not be read.");
  }
  return canonical;
}

export async function pruneExpiredWordPackRequestResults(input: {
  store: WordPackEntityStore<WordPackRequestResultRecord>;
  userID: string;
  now?: Date;
  limit?: number;
}): Promise<number> {
  if (!input.store.delete) return 0;
  const nowTimestamp = (input.now ?? new Date()).getTime();
  if (!Number.isFinite(nowTimestamp)) {
    throw new InvalidWordPackIdempotencyInputError(
      "Idempotency prune date is invalid.",
    );
  }
  const limit = Math.max(1, Math.min(50, Math.trunc(input.limit ?? 10)));
  const records = await input.store.filter(
    { user_id: normalizeWordPackUserID(input.userID) },
    "expires_at",
    limit,
    0,
  );
  const expiredIDs = records.flatMap((record) => {
    const expiresAt = timestamp(record.expires_at);
    return expiresAt !== null && expiresAt <= nowTimestamp && record.id
      ? [record.id]
      : [];
  });
  await Promise.all(expiredIDs.map((id) => input.store.delete!(id)));
  return expiredIDs.length;
}
