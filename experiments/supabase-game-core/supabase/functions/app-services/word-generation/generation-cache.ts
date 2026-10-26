const CACHE_KEY_DOMAIN = "spyclash:ai-word-pack-cache:v1";
const THEME_KEY_DOMAIN = "spyclash:ai-word-pack-theme:v1";
const VARIANT_KEY_DOMAIN = "spyclash:ai-word-pack-variant:v1";
const EXCLUSION_KEY_DOMAIN = "spyclash:ai-word-pack-exclusions:v1";
const CONTROL_OR_FORMAT_CHARACTERS =
  /[\u0000-\u001F\u007F-\u009F\u200B-\u200D\u2060\uFEFF]/gu;
const CONTROL_OR_FORMAT_CHARACTER =
  /[\u0000-\u001F\u007F-\u009F\u200B-\u200D\u2060\uFEFF]/u;
const EDGE_SEPARATORS = /^[\s,;.\-–—"'`]+|[\s,;.\-–—"'`]+$/gu;

const DAY_MILLISECONDS = 24 * 60 * 60 * 1_000;

export const DEFAULT_WORD_PACK_CACHE_TTL_MILLISECONDS = 7 * DAY_MILLISECONDS;
export const MAX_WORD_PACK_CACHE_VARIANTS_PER_KEY = 50;

export class InvalidWordPackCacheInputError extends Error {
  readonly status = 400 as const;
  readonly code = "invalid_word_pack_cache_input" as const;

  constructor(message: string) {
    super(message);
    this.name = "InvalidWordPackCacheInputError";
  }
}

export type WordPackEntityStore<RecordValue extends Record<string, unknown>> = {
  filter: (
    filter: Record<string, unknown>,
    sort?: string,
    limit?: number,
    skip?: number,
  ) => Promise<RecordValue[]>;
  create: (value: Record<string, unknown>) => Promise<RecordValue>;
  delete?: (id: string) => Promise<unknown>;
};

export type PreparedWordPackCacheRequest = {
  /** Authenticated account scope. Never accept this value from the request body. */
  userID: string;
  /** Sensitive normalized input. Keep this out of logs and telemetry. */
  normalizedTheme: string;
  /** One-way identifier safe to use instead of the theme in telemetry. */
  themeKey: string;
  languageKey: string;
  promptVersion: string;
  /** Exact-match group key; count and exclusions deliberately do not fragment it. */
  cacheKey: string;
  requestedCount: number;
  /** One-way exact identifier for exhaustion semantics; never log raw exclusions. */
  exclusionKey: string;
  exclusionKeys: string[];
};

export type WordPackCacheVariantRecord = {
  id?: string;
  user_id?: string;
  cache_key?: string;
  theme_key?: string;
  language_key?: string;
  prompt_version?: string;
  exclusion_key?: string;
  variant_key?: string;
  category?: string;
  words?: unknown[];
  exhausted?: boolean;
  word_count?: number;
  generated_at?: string;
  expires_at?: string;
  created_date?: string;
};

export type WordPackResult = {
  category: string;
  words: string[];
  /** True when the provider could not safely produce additional real words. */
  exhausted: boolean;
};

export type WordPackCacheHit = WordPackResult & {
  variantKey: string;
  recordID?: string;
  expiresAt: string;
};

function normalizedSingleLine(value: unknown): string {
  return String(value ?? "").normalize("NFKC")
    .replace(CONTROL_OR_FORMAT_CHARACTERS, " ")
    .replace(/\s+/gu, " ")
    .trim();
}

function requireBoundedText(
  value: unknown,
  field: string,
  maximumLength: number,
): string {
  const normalized = normalizedSingleLine(value);
  if (!normalized) {
    throw new InvalidWordPackCacheInputError(`${field} is required.`);
  }
  if (normalized.length > maximumLength) {
    throw new InvalidWordPackCacheInputError(
      `${field} must be at most ${maximumLength} characters.`,
    );
  }
  return normalized;
}

/**
 * Exact cache normalization only: compatibility form, edge separators,
 * whitespace and case. It intentionally does not perform fuzzy/semantic
 * matching, so neighboring themes cannot share generated content.
 */
export function normalizeWordPackTheme(value: unknown): string {
  return requireBoundedText(value, "Theme", 80)
    .replace(EDGE_SEPARATORS, "")
    .replace(/\s+/gu, " ")
    .trim()
    .toLowerCase()
    .normalize("NFKC");
}

export function normalizeWordPackUserID(value: unknown): string {
  if (CONTROL_OR_FORMAT_CHARACTER.test(String(value ?? ""))) {
    throw new InvalidWordPackCacheInputError(
      "User ID cannot contain control or format characters.",
    );
  }
  const userID = requireBoundedText(value, "User ID", 256);
  return userID;
}

export function normalizeWordPackLanguage(value: unknown): string {
  const raw = requireBoundedText(value, "Language", 35).replaceAll("_", "-");
  try {
    const [canonical] = Intl.getCanonicalLocales(raw);
    if (!canonical) throw new Error("missing canonical language");
    return canonical.toLowerCase();
  } catch {
    throw new InvalidWordPackCacheInputError(
      "Language must be a valid BCP 47 language tag.",
    );
  }
}

export function normalizeWordPackPromptVersion(value: unknown): string {
  const version = requireBoundedText(value, "Prompt version", 64).toLowerCase();
  if (!/^[a-z0-9][a-z0-9._-]*$/.test(version)) {
    throw new InvalidWordPackCacheInputError(
      "Prompt version must contain only letters, numbers, dots, underscores, or hyphens.",
    );
  }
  return version;
}

export function normalizeWordPackRequestedCount(value: unknown): number {
  const count = Number(value);
  if (!Number.isInteger(count) || count < 5 || count > 100) {
    throw new InvalidWordPackCacheInputError(
      "Requested count must be an integer from 5 through 100.",
    );
  }
  return count;
}

function normalizedWord(value: unknown): string {
  return normalizedSingleLine(value).replace(EDGE_SEPARATORS, "")
    .replace(/\s+/gu, " ").trim();
}

export function wordPackComparisonKey(value: unknown): string {
  return normalizedWord(value).toLowerCase().normalize("NFKC");
}

export function normalizeWordPackExclusions(values: unknown): string[] {
  if (!Array.isArray(values)) return [];
  const keys = new Set<string>();
  for (const value of values.slice(0, 200)) {
    const key = wordPackComparisonKey(value);
    if (key) keys.add(key);
  }
  return [...keys].sort();
}

export function normalizeGeneratedWordPack(result: {
  category: unknown;
  words: unknown;
  exhausted: unknown;
}): WordPackResult {
  const category = requireBoundedText(result.category, "Category", 120);
  const values = Array.isArray(result.words) ? result.words : [];
  const seen = new Set<string>();
  const words: string[] = [];
  for (const value of values) {
    const word = normalizedWord(value);
    const key = wordPackComparisonKey(word);
    if (!word || word.length > 120 || !key || seen.has(key)) continue;
    seen.add(key);
    words.push(word);
  }
  if (words.length < 2) {
    throw new InvalidWordPackCacheInputError(
      "A cached word pack must contain at least two unique words.",
    );
  }
  if (typeof result.exhausted !== "boolean") {
    throw new InvalidWordPackCacheInputError(
      "A cached word pack must declare whether generation is exhausted.",
    );
  }
  return { category, words, exhausted: result.exhausted };
}

function framedMaterial(domain: string, values: readonly string[]): string {
  const encoder = new TextEncoder();
  return [domain, ...values].map((value) => {
    const byteLength = encoder.encode(value).byteLength;
    return `${byteLength}:${value}`;
  }).join("|");
}

async function sha256Base64URL(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/u, "");
}

async function namespacedKey(
  prefix: string,
  domain: string,
  values: readonly string[],
): Promise<string> {
  return `${prefix}_${await sha256Base64URL(framedMaterial(domain, values))}`;
}

export async function prepareWordPackCacheRequest(input: {
  userID: unknown;
  theme: unknown;
  language: unknown;
  promptVersion: unknown;
  requestedCount: unknown;
  exclusions?: unknown;
}): Promise<PreparedWordPackCacheRequest> {
  const userID = normalizeWordPackUserID(input.userID);
  const normalizedTheme = normalizeWordPackTheme(input.theme);
  if (!normalizedTheme) {
    throw new InvalidWordPackCacheInputError("Theme is required.");
  }
  const languageKey = normalizeWordPackLanguage(input.language);
  const promptVersion = normalizeWordPackPromptVersion(input.promptVersion);
  const requestedCount = normalizeWordPackRequestedCount(input.requestedCount);
  const exclusionKeys = normalizeWordPackExclusions(input.exclusions);
  const [themeKey, cacheKey, exclusionKey] = await Promise.all([
    namespacedKey("awt1", THEME_KEY_DOMAIN, [userID, normalizedTheme]),
    namespacedKey("awc1", CACHE_KEY_DOMAIN, [
      userID,
      normalizedTheme,
      languageKey,
      promptVersion,
    ]),
    namespacedKey("awe1", EXCLUSION_KEY_DOMAIN, [
      userID,
      normalizedTheme,
      ...exclusionKeys,
    ]),
  ]);
  return {
    userID,
    normalizedTheme,
    themeKey,
    languageKey,
    promptVersion,
    cacheKey,
    requestedCount,
    exclusionKey,
    exclusionKeys,
  };
}

function requirePositiveTTL(value: number): number {
  if (!Number.isFinite(value) || value <= 0) {
    throw new InvalidWordPackCacheInputError(
      "Cache TTL must be a positive number of milliseconds.",
    );
  }
  return Math.trunc(value);
}

function validDate(value: unknown): number | null {
  const timestamp = Date.parse(String(value ?? ""));
  return Number.isFinite(timestamp) ? timestamp : null;
}

function exactCacheRecord(
  record: WordPackCacheVariantRecord,
  request: PreparedWordPackCacheRequest,
): boolean {
  return record.user_id === request.userID &&
    record.cache_key === request.cacheKey &&
    record.theme_key === request.themeKey &&
    record.language_key === request.languageKey &&
    record.prompt_version === request.promptVersion;
}

export async function buildWordPackCacheVariantRecord(input: {
  request: PreparedWordPackCacheRequest;
  result: { category: unknown; words: unknown; exhausted: unknown };
  now?: Date;
  ttlMilliseconds?: number;
}): Promise<
  Required<
    Omit<WordPackCacheVariantRecord, "id" | "created_date">
  >
> {
  const result = normalizeGeneratedWordPack(input.result);
  const generatedAt = input.now ?? new Date();
  if (!Number.isFinite(generatedAt.getTime())) {
    throw new InvalidWordPackCacheInputError("Generation date is invalid.");
  }
  const ttl = requirePositiveTTL(
    input.ttlMilliseconds ?? DEFAULT_WORD_PACK_CACHE_TTL_MILLISECONDS,
  );
  const expiresAt = new Date(generatedAt.getTime() + ttl);
  if (!Number.isFinite(expiresAt.getTime())) {
    throw new InvalidWordPackCacheInputError("Cache expiry is invalid.");
  }
  const variantKey = await namespacedKey("awv1", VARIANT_KEY_DOMAIN, [
    input.request.cacheKey,
    input.request.exclusionKey,
    result.category,
    String(result.exhausted),
    ...result.words,
  ]);
  return {
    user_id: input.request.userID,
    cache_key: input.request.cacheKey,
    theme_key: input.request.themeKey,
    language_key: input.request.languageKey,
    prompt_version: input.request.promptVersion,
    exclusion_key: input.request.exclusionKey,
    variant_key: variantKey,
    category: result.category,
    words: result.words,
    exhausted: result.exhausted,
    word_count: result.words.length,
    generated_at: generatedAt.toISOString(),
    expires_at: expiresAt.toISOString(),
  };
}

async function stableVariantIndex(
  seed: string,
  count: number,
): Promise<number> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`spyclash:ai-word-pack-selection:v1:${seed}`),
  );
  const view = new DataView(digest);
  return view.getUint32(0, false) % count;
}

export async function selectWordPackCacheHit(input: {
  records: WordPackCacheVariantRecord[];
  request: PreparedWordPackCacheRequest;
  now?: Date;
  selectionSeed?: string;
}): Promise<WordPackCacheHit | null> {
  const now = input.now ?? new Date();
  const nowTimestamp = now.getTime();
  if (!Number.isFinite(nowTimestamp)) {
    throw new InvalidWordPackCacheInputError("Cache lookup date is invalid.");
  }
  const excluded = new Set(input.request.exclusionKeys);
  const candidates = new Map<string, WordPackCacheHit>();

  for (const record of input.records) {
    if (!exactCacheRecord(record, input.request)) continue;
    const expiresAt = validDate(record.expires_at);
    if (expiresAt === null || expiresAt <= nowTimestamp) continue;
    const variantKey = String(record.variant_key ?? "");
    if (!variantKey) continue;
    let normalized: WordPackResult;
    try {
      normalized = normalizeGeneratedWordPack({
        category: record.category,
        words: record.words,
        exhausted: record.exhausted,
      });
    } catch {
      continue;
    }
    const words = normalized.words.filter((word) =>
      !excluded.has(wordPackComparisonKey(word))
    );
    // A non-exhausted partial is a miss because a provider refill may complete
    // it. An exhausted partial remains a playable hit and must suppress that
    // known-futile refill (provided at least two words survive exclusions).
    if (words.length < 2) continue;
    if (words.length < input.request.requestedCount) {
      if (!normalized.exhausted) continue;
      // Exhaustion describes the provider's search space after exclusions.
      // Reusing that partial for another exclusion set could incorrectly turn
      // a rich theme into a short pack, so partial exhaustion is exact-only.
      if (record.exclusion_key !== input.request.exclusionKey) continue;
    }
    candidates.set(variantKey, {
      category: normalized.category,
      words: words.slice(0, input.request.requestedCount),
      exhausted: normalized.exhausted,
      variantKey,
      ...(record.id ? { recordID: record.id } : {}),
      expiresAt: new Date(expiresAt).toISOString(),
    });
  }

  const eligible = [...candidates.values()].sort((left, right) =>
    left.variantKey.localeCompare(right.variantKey)
  );
  if (!eligible.length) return null;
  const index = await stableVariantIndex(
    input.selectionSeed ?? input.request.cacheKey,
    eligible.length,
  );
  return eligible[index];
}

export async function lookupWordPackCache(input: {
  store: Pick<WordPackEntityStore<WordPackCacheVariantRecord>, "filter">;
  request: PreparedWordPackCacheRequest;
  now?: Date;
  selectionSeed?: string;
  limit?: number;
}): Promise<WordPackCacheHit | null> {
  const limit = Math.max(
    1,
    Math.min(
      MAX_WORD_PACK_CACHE_VARIANTS_PER_KEY,
      Math.trunc(input.limit ?? MAX_WORD_PACK_CACHE_VARIANTS_PER_KEY),
    ),
  );
  const records = await input.store.filter(
    { cache_key: input.request.cacheKey },
    "-generated_at",
    limit,
    0,
  );
  return await selectWordPackCacheHit({
    records,
    request: input.request,
    now: input.now,
    selectionSeed: input.selectionSeed,
  });
}

export async function persistWordPackCacheVariant(input: {
  store: WordPackEntityStore<WordPackCacheVariantRecord>;
  request: PreparedWordPackCacheRequest;
  result: { category: unknown; words: unknown; exhausted: unknown };
  now?: Date;
  ttlMilliseconds?: number;
}): Promise<WordPackCacheVariantRecord> {
  const record = await buildWordPackCacheVariantRecord(input);
  const existing = await input.store.filter(
    { variant_key: record.variant_key },
    "created_date",
    20,
    0,
  );
  const existingMatch = existing.find((candidate) =>
    exactCacheRecord(candidate, input.request) &&
    candidate.variant_key === record.variant_key &&
    (validDate(candidate.expires_at) ?? Number.NEGATIVE_INFINITY) >
      (input.now ?? new Date()).getTime()
  );
  if (existingMatch) return existingMatch;
  return await input.store.create(record);
}

export async function pruneExpiredWordPackCacheVariants(input: {
  store: WordPackEntityStore<WordPackCacheVariantRecord>;
  userID: string;
  now?: Date;
  limit?: number;
}): Promise<number> {
  if (!input.store.delete) return 0;
  const nowTimestamp = (input.now ?? new Date()).getTime();
  if (!Number.isFinite(nowTimestamp)) {
    throw new InvalidWordPackCacheInputError("Cache prune date is invalid.");
  }
  const limit = Math.max(1, Math.min(50, Math.trunc(input.limit ?? 10)));
  const records = await input.store.filter(
    { user_id: normalizeWordPackUserID(input.userID) },
    "expires_at",
    limit,
    0,
  );
  const expiredIDs = records.flatMap((record) => {
    const expiresAt = validDate(record.expires_at);
    return expiresAt !== null && expiresAt <= nowTimestamp && record.id
      ? [record.id]
      : [];
  });
  await Promise.all(expiredIDs.map((id) => input.store.delete!(id)));
  return expiredIDs.length;
}

/**
 * The returned object is deliberately allow-listed. In particular, it has no
 * `theme`/`normalizedTheme` property and can be safely passed to telemetry.
 */
export function wordPackTelemetryDimensions(
  request: PreparedWordPackCacheRequest,
): Readonly<Record<string, string | number>> {
  return Object.freeze({
    theme_key: request.themeKey,
    language_key: request.languageKey,
    prompt_version: request.promptVersion,
    requested_count: request.requestedCount,
    excluded_count: request.exclusionKeys.length,
  });
}
