type UnknownRecord = Record<string, unknown>;

export type WordPackSelfAuditCandidate = {
  draft_words?: unknown;
  accepted_indices?: unknown;
  replacement_words?: unknown;
  accepted_replacement_indices?: unknown;
  category?: unknown;
  exhausted?: unknown;
};

export type WordPackSelfAuditResult = {
  words: string[];
  category: string;
  exhausted: boolean;
  rejectedCount: number;
  replacementCount: number;
};

export class WordPackQualityGateError extends Error {
  readonly status = 502;
  readonly code = "ai_output_failed_quality_gate";
  readonly retryable = true;

  constructor() {
    super("AI output did not stay inside the requested theme. Try again.");
    this.name = "WordPackQualityGateError";
  }
}

export function wordPackSelfAuditSchema(input: {
  requestedCount: number;
  draftDescription: string;
  categoryDescription: string;
  exhaustedDescription: string;
}) {
  const requestedCount = input.requestedCount;
  if (
    !Number.isInteger(requestedCount) || requestedCount < 2 ||
    requestedCount > 100
  ) {
    throw new WordPackQualityGateError();
  }

  return {
    type: "object",
    properties: {
      draft_words: {
        type: "array",
        description:
          `Draft exactly ${requestedCount} candidates before auditing them. ${input.draftDescription}`,
        items: { type: "string", minLength: 1, maxLength: 120 },
        maxItems: requestedCount,
      },
      accepted_indices: {
        type: "array",
        description:
          "Zero-based indices of only the draft candidates that truthfully and directly satisfy the exact theme after the model's strict self-audit.",
        items: {
          type: "integer",
          minimum: 0,
          maximum: requestedCount - 1,
        },
        maxItems: requestedCount,
      },
      replacement_words: {
        type: "array",
        description:
          "Candidate replacements for rejected draft items. Never repeat a draft candidate or excluded item. Audit these candidates before accepting them.",
        items: { type: "string", minLength: 1, maxLength: 120 },
        maxItems: requestedCount,
      },
      accepted_replacement_indices: {
        type: "array",
        description:
          "Zero-based indices of only the replacement candidates that independently pass the same exact-theme audit as accepted draft items.",
        items: {
          type: "integer",
          minimum: 0,
          maximum: requestedCount - 1,
        },
        maxItems: requestedCount,
      },
      category: {
        type: "string",
        minLength: 1,
        maxLength: 120,
        description: input.categoryDescription,
      },
      exhausted: {
        type: "boolean",
        description: input.exhaustedDescription,
      },
    },
    required: [
      "draft_words",
      "accepted_indices",
      "replacement_words",
      "accepted_replacement_indices",
      "category",
      "exhausted",
    ],
    additionalProperties: false,
  };
}

function validWord(value: unknown): value is string {
  return typeof value === "string" && Boolean(value.trim()) &&
    value.length <= 120;
}

function normalizedWordKey(value: string): string {
  return value.normalize("NFKC").trim().toLowerCase();
}

export function applyWordPackSelfAudit(
  candidate: WordPackSelfAuditCandidate,
  requestedCount: number,
  forbiddenWords: readonly string[] = [],
): WordPackSelfAuditResult {
  const record = candidate !== null && typeof candidate === "object"
    ? candidate as UnknownRecord
    : null;
  const draftWords = record?.draft_words;
  const rawIndices = record?.accepted_indices;
  const replacementWords = record?.replacement_words;
  const rawReplacementIndices = record?.accepted_replacement_indices;
  const category = record?.category;
  const exhausted = record?.exhausted;
  const keys = record ? Object.keys(record).sort() : [];

  if (
    !Number.isInteger(requestedCount) || requestedCount < 2 ||
    requestedCount > 100 || !Array.isArray(draftWords) ||
    draftWords.length > requestedCount || !draftWords.every(validWord) ||
    !Array.isArray(rawIndices) || rawIndices.length > draftWords.length ||
    !Array.isArray(replacementWords) ||
    replacementWords.length > requestedCount ||
    !replacementWords.every(validWord) ||
    !Array.isArray(rawReplacementIndices) ||
    rawReplacementIndices.length > replacementWords.length ||
    !validWord(category) ||
    typeof exhausted !== "boolean" ||
    keys.join(",") !==
      "accepted_indices,accepted_replacement_indices,category,draft_words,exhausted,replacement_words"
  ) {
    throw new WordPackQualityGateError();
  }

  const acceptedReplacementIndices = new Set<number>();
  for (const value of rawReplacementIndices) {
    if (
      !Number.isInteger(value) || Number(value) < 0 ||
      Number(value) >= replacementWords.length ||
      acceptedReplacementIndices.has(Number(value))
    ) {
      throw new WordPackQualityGateError();
    }
    acceptedReplacementIndices.add(Number(value));
  }

  const acceptedIndices = new Set<number>();
  for (const value of rawIndices) {
    if (
      !Number.isInteger(value) || Number(value) < 0 ||
      Number(value) >= draftWords.length ||
      acceptedIndices.has(Number(value))
    ) {
      throw new WordPackQualityGateError();
    }
    acceptedIndices.add(Number(value));
  }

  const words: string[] = [];
  const seen = new Set<string>();
  const draftWordKeys = new Set(draftWords.map(normalizedWordKey));
  const forbiddenWordKeys = new Set(forbiddenWords.map(normalizedWordKey));
  const append = (value: string): boolean => {
    const normalized = value.trim();
    const key = normalizedWordKey(normalized);
    if (
      !key || forbiddenWordKeys.has(key) || seen.has(key) ||
      words.length >= requestedCount
    ) return false;
    seen.add(key);
    words.push(normalized);
    return true;
  };

  let acceptedDraftCount = 0;
  draftWords.forEach((value, index) => {
    if (acceptedIndices.has(index) && append(value)) acceptedDraftCount += 1;
  });
  let replacementCount = 0;
  replacementWords.forEach((word, index) => {
    // A rejected draft must never be able to re-enter the final pack by being
    // echoed as a "replacement". Silently ignore repeats when the response
    // also contains enough genuinely new replacements; the final count check
    // below still fails closed when it does not.
    if (
      acceptedReplacementIndices.has(index) &&
      !draftWordKeys.has(normalizedWordKey(word)) && append(word)
    ) {
      replacementCount += 1;
    }
  });

  if (
    (words.length < requestedCount && !exhausted) ||
    (words.length >= requestedCount && exhausted)
  ) {
    throw new WordPackQualityGateError();
  }

  return {
    words,
    category: category.trim(),
    exhausted,
    rejectedCount: draftWords.length - acceptedDraftCount +
      replacementWords.length - replacementCount,
    replacementCount,
  };
}
