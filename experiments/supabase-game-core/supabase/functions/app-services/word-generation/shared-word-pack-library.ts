import {
  InvalidWordPackCacheInputError,
  normalizeGeneratedWordPack,
  normalizeWordPackExclusions,
  normalizeWordPackLanguage,
  normalizeWordPackPromptVersion,
  normalizeWordPackTheme,
  wordPackComparisonKey,
} from "./generation-cache.ts";
import { filterSafeCommunityStrings } from "./content-safety.ts";
import { assertNoKnownNamedThemeDrift } from "./openai-word-pack-provider.ts";

export const SHARED_WORD_PACK_TTL_MILLISECONDS = 30 * 24 * 60 * 60 * 1000;
// Base44 and the native edge worker do not share a clock. Match the server RPC
// allowance so a just-published variant cannot become a false cache miss.
const SHARED_WORD_PACK_CLOCK_SKEW_MILLISECONDS = 60_000;

/** Internal transport failure, not a confirmed cache miss. Never start paid
 * provider work in response to this error. */
export class SharedWordPackLibraryError extends Error {
  readonly status = 503;
  readonly retryable = true;

  constructor(
    readonly code = "shared_library_unavailable",
    message = "Word library is temporarily unavailable. Retry this request.",
  ) {
    super(message);
    this.name = "SharedWordPackLibraryError";
  }
}

export type SharedWordPackRequest = {
  /** Input held in memory for quality validation only. Never persist or log. */
  normalizedTheme: string;
  cacheKey: string;
  languageKey: string;
  promptVersion: string;
  requestedCount: number;
  exclusionKey: string;
  exclusionKeys: string[];
};

/** Intentionally contains neither account identifiers nor the raw theme. */
export type SharedWordPackVariant = {
  cache_key: string;
  variant_key: string;
  language_key: string;
  prompt_version: string;
  exclusion_key: string;
  words: string[];
  exhausted: boolean;
  word_count: number;
  generated_at: string;
  expires_at: string;
};

export type SharedWordPackHit = {
  words: string[];
  exhausted: boolean;
  /** Composite identifier, not the id of a private Base44 cache record. */
  variantKey: string;
  expiresAt: string;
};

export interface SharedWordPackLibraryStore {
  read(request: SharedWordPackRequest): Promise<SharedWordPackHit | null>;
  claim(cacheKey: string, token: string): Promise<boolean>;
  publish(record: SharedWordPackVariant, token: string): Promise<boolean>;
  release(cacheKey: string, token: string): Promise<void>;
}

export function sharedWordPackLibraryEnabled(
  config: Readonly<Record<string, string | undefined>>,
): boolean {
  return config.SPYCLASH_SHARED_WORD_PACKS_ENABLED === "true";
}

async function key(prefix: string, domain: string, values: readonly string[]) {
  const encoder = new TextEncoder();
  const material = [domain, ...values].map((value) =>
    `${encoder.encode(value).length}:${value}`
  ).join("|");
  const bytes = new Uint8Array(
    await crypto.subtle.digest("SHA-256", encoder.encode(material)),
  );
  return `${prefix}_${
    btoa(String.fromCharCode(...bytes))
      .replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "")
  }`;
}

export async function prepareSharedWordPackRequest(input: {
  theme: unknown;
  language: unknown;
  promptVersion: unknown;
  requestedCount: unknown;
  exclusions?: unknown;
}): Promise<SharedWordPackRequest> {
  const normalizedTheme = normalizeWordPackTheme(input.theme);
  if (!normalizedTheme) {
    throw new InvalidWordPackCacheInputError("Theme is required.");
  }
  const languageKey = normalizeWordPackLanguage(input.language);
  const promptVersion = normalizeWordPackPromptVersion(input.promptVersion);
  const requestedCount = Number(input.requestedCount);
  if (
    !Number.isInteger(requestedCount) || requestedCount < 2 ||
    requestedCount > 100
  ) {
    throw new InvalidWordPackCacheInputError(
      "Word count must be from 2 through 100.",
    );
  }
  const exclusionKeys = normalizeWordPackExclusions(input.exclusions);
  // Count and exclusions do not fragment the reusable pool. Both language and
  // quality contract are part of its exact key. No user scope is included.
  const cacheKey = await key("swk1", "spyclash:shared-word-pack:v1", [
    normalizedTheme,
    languageKey,
    promptVersion,
  ]);
  const exclusionKey = await key(
    "swe1",
    "spyclash:shared-word-pack-exclusions:v1",
    [
      cacheKey,
      ...exclusionKeys,
    ],
  );
  return {
    normalizedTheme,
    cacheKey,
    languageKey,
    promptVersion,
    requestedCount,
    exclusionKey,
    exclusionKeys,
  };
}

function usableWords(
  request: SharedWordPackRequest,
  words: unknown[],
): string[] {
  const denied = new Set(request.exclusionKeys);
  const safe = filterSafeCommunityStrings(words).filter((word) =>
    !denied.has(wordPackComparisonKey(word))
  );
  assertNoKnownNamedThemeDrift(request.normalizedTheme, safe);
  // This reuses the application's exact Unicode and punctuation comparison.
  // Normalization rejects fewer than two playable words.
  return normalizeGeneratedWordPack({
    category: "AI GENERATED",
    words: safe,
    exhausted: false,
  }).words;
}

export async function buildSharedWordPackVariant(input: {
  request: SharedWordPackRequest;
  result: { words: unknown[]; exhausted: boolean };
  now?: Date;
}): Promise<SharedWordPackVariant> {
  const now = input.now ?? new Date();
  if (!Number.isFinite(now.getTime())) {
    throw new InvalidWordPackCacheInputError("Generation date is invalid.");
  }
  if (typeof input.result.exhausted !== "boolean") {
    throw new InvalidWordPackCacheInputError("Exhaustion must be declared.");
  }
  const words = usableWords(input.request, input.result.words).slice(0, 100);
  if (words.length < input.request.requestedCount && !input.result.exhausted) {
    throw new InvalidWordPackCacheInputError(
      "Incomplete word packs cannot be shared.",
    );
  }
  const variantKey = await key("swv1", "spyclash:shared-word-pack-variant:v1", [
    input.request.cacheKey,
    input.request.exclusionKey,
    String(input.result.exhausted),
    ...words,
  ]);
  return {
    cache_key: input.request.cacheKey,
    variant_key: variantKey,
    language_key: input.request.languageKey,
    prompt_version: input.request.promptVersion,
    exclusion_key: input.request.exclusionKey,
    words,
    exhausted: input.result.exhausted,
    word_count: words.length,
    generated_at: now.toISOString(),
    expires_at: new Date(now.getTime() + SHARED_WORD_PACK_TTL_MILLISECONDS)
      .toISOString(),
  };
}

export async function selectSharedWordPackHit(input: {
  request: SharedWordPackRequest;
  records: unknown[];
  now?: Date;
}): Promise<SharedWordPackHit | null> {
  const now = (input.now ?? new Date()).getTime();
  if (!Number.isFinite(now)) {
    throw new InvalidWordPackCacheInputError("Lookup date is invalid.");
  }
  const candidates: {
    record: SharedWordPackVariant;
    words: string[];
    expires: number;
  }[] = [];
  for (const value of input.records) {
    if (!value || typeof value !== "object" || Array.isArray(value)) continue;
    const record = value as SharedWordPackVariant;
    if (
      record.cache_key !== input.request.cacheKey ||
      record.language_key !== input.request.languageKey ||
      record.prompt_version !== input.request.promptVersion ||
      !/^swv1_[A-Za-z0-9_-]{43}$/u.test(record.variant_key ?? "") ||
      !/^swe1_[A-Za-z0-9_-]{43}$/u.test(record.exclusion_key ?? "") ||
      !Array.isArray(record.words) || record.words.length > 100 ||
      record.words.some((word) =>
        typeof word !== "string" || word.length > 120
      ) ||
      typeof record.exhausted !== "boolean"
    ) continue;
    const expires = Date.parse(record.expires_at),
      generated = Date.parse(record.generated_at);
    if (
      !Number.isFinite(expires) || !Number.isFinite(generated) ||
      expires <= now ||
      generated > now + SHARED_WORD_PACK_CLOCK_SKEW_MILLISECONDS ||
      expires <= generated ||
      expires - generated > SHARED_WORD_PACK_TTL_MILLISECONDS
    ) continue;
    try {
      // Validate the complete pack first. Exclusions can leave only one word,
      // which is still useful when combined with other valid variants.
      const verified = usableWords(
        { ...input.request, exclusionKeys: [] },
        record.words,
      );
      const denied = new Set(input.request.exclusionKeys);
      const words = verified.filter((word) =>
        !denied.has(wordPackComparisonKey(word))
      );
      candidates.push({ record, words, expires });
    } catch {
      // Corrupt or obsolete-quality variants are not usable stock.
    }
  }
  candidates.sort((a, b) =>
    b.record.generated_at.localeCompare(a.record.generated_at) ||
    a.record.variant_key.localeCompare(b.record.variant_key)
  );
  const seen = new Set<string>(),
    words: string[] = [],
    sourceKeys: string[] = [];
  let earliestExpiry = Number.POSITIVE_INFINITY;
  let exactExhaustion = false;
  for (const candidate of candidates) {
    if (
      candidate.record.exhausted &&
      candidate.record.exclusion_key === input.request.exclusionKey
    ) {
      exactExhaustion = true;
    }
    let used = false;
    for (const word of candidate.words) {
      const comparison = wordPackComparisonKey(word);
      if (!seen.has(comparison)) {
        seen.add(comparison);
        words.push(word);
        used = true;
      }
      if (words.length >= input.request.requestedCount) break;
    }
    if (used) {
      sourceKeys.push(candidate.record.variant_key);
      earliestExpiry = Math.min(earliestExpiry, candidate.expires);
    }
    if (words.length >= input.request.requestedCount) break;
  }
  if (
    words.length < 2 ||
    (words.length < input.request.requestedCount && !exactExhaustion)
  ) return null;
  return {
    words,
    exhausted: words.length < input.request.requestedCount,
    variantKey: await key("swh1", "spyclash:shared-word-pack-hit:v1", [
      input.request.cacheKey,
      ...sourceKeys,
      ...words,
    ]),
    expiresAt: new Date(earliestExpiry).toISOString(),
  };
}
