export const COMMUNITY_REPORT_REASONS = [
  "harassment",
  "hate_speech",
  "sexual_content",
  "violence_or_threats",
  "spam",
  "impersonation",
  "other",
] as const;

export type CommunityReportReason = typeof COMMUNITY_REPORT_REASONS[number];
export type CommunitySafetyCategory =
  | "abusive_language"
  | "hate_speech"
  | "sexual_exploitation"
  | "violence_or_threats"
  | "self_harm_encouragement";

export class ObjectionableCommunityContentError extends Error {
  readonly status = 422;
  readonly code = "objectionable_content";

  constructor(public readonly field: string) {
    super(`${field} contains content that is not allowed.`);
    this.name = "ObjectionableCommunityContentError";
  }
}

const ZERO_WIDTH = /[\u200B-\u200D\u2060\uFEFF]/g;
const COMBINING_MARKS = /\p{M}+/gu;
const NON_ALPHANUMERIC = /[^\p{L}\p{N}]+/gu;
const PUBLIC_AVATARS = new Set([
  "🕵️",
  "🥷",
  "🧠",
  "🎭",
  "🃏",
  "👁️",
  "🔥",
  "⚡️",
  "🎯",
  "🛡️",
]);

const LEET_EQUIVALENTS: Record<string, string> = {
  "0": "o",
  "1": "i",
  "3": "e",
  "4": "a",
  "5": "s",
  "7": "t",
  "8": "b",
  "9": "g",
};

const ABUSIVE_TOKENS = new Set([
  "bitch",
  "cunt",
  "fuck",
  "motherfucker",
  "whore",
  "блядь",
  "блять",
  "долбоеб",
  "сука",
  "хуй",
  "mierda",
  "puta",
]);

const HATE_TOKENS = new Set([
  "faggot",
  "kike",
  "nigger",
  "пидор",
  "пидарас",
  "maricon",
]);

const SEXUAL_EXPLOITATION_PHRASES = [
  "child porn",
  "child pornography",
  "детское порно",
  "pornografia infantil",
];

const THREAT_PHRASES = [
  "i will kill you",
  "im going to kill you",
  "kill them all",
  "я тебя убью",
  "убью тебя",
  "убить вас всех",
  "te voy a matar",
  "voy a matarte",
];

const SELF_HARM_PHRASES = [
  "kill yourself",
  "go kill yourself",
  "убей себя",
  "покончи с собой",
  "matate",
];

function normalizedSafetyText(value: unknown): string {
  return String(value ?? "")
    .normalize("NFKD")
    .replace(COMBINING_MARKS, "")
    .replace(ZERO_WIDTH, "")
    .toLocaleLowerCase()
    .replace(
      /[01345789]/g,
      (character) => LEET_EQUIVALENTS[character] || character,
    )
    .replace(NON_ALPHANUMERIC, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function safetyTokens(normalized: string): string[] {
  const tokens = normalized.split(" ").filter(Boolean);
  const expanded = [...tokens];
  let singleLetterRun = "";
  for (const token of [...tokens, "boundary"]) {
    if (token.length === 1) {
      singleLetterRun += token;
      continue;
    }
    if (singleLetterRun.length >= 3) expanded.push(singleLetterRun);
    singleLetterRun = "";
  }
  return expanded;
}

function includesPhrase(normalized: string, phrases: readonly string[]) {
  const padded = ` ${normalized} `;
  return phrases.some((phrase) => padded.includes(` ${phrase} `));
}

export function classifyObjectionableMaterial(
  value: unknown,
): CommunitySafetyCategory | null {
  const normalized = normalizedSafetyText(value);
  if (!normalized) return null;

  const tokens = safetyTokens(normalized);
  if (tokens.some((token) => HATE_TOKENS.has(token))) return "hate_speech";
  if (includesPhrase(normalized, SEXUAL_EXPLOITATION_PHRASES)) {
    return "sexual_exploitation";
  }
  if (includesPhrase(normalized, THREAT_PHRASES)) {
    return "violence_or_threats";
  }
  if (
    tokens.includes("kys") ||
    includesPhrase(normalized, SELF_HARM_PHRASES)
  ) {
    return "self_harm_encouragement";
  }
  if (tokens.some((token) => ABUSIVE_TOKENS.has(token))) {
    return "abusive_language";
  }
  return null;
}

export function requireSafeCommunityText(
  value: unknown,
  field: string,
): string {
  const text = String(value ?? "")
    .replace(/[\u0000-\u001F\u007F]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (classifyObjectionableMaterial(text)) {
    throw new ObjectionableCommunityContentError(field);
  }
  return text;
}

export function safeCommunityTextForDisplay(
  value: unknown,
  fallback: string,
): string {
  const text = String(value ?? "").trim();
  return text && !classifyObjectionableMaterial(text) ? text : fallback;
}

export function validateSharedWordPackContent(input: {
  name: unknown;
  category?: unknown;
  words: unknown[];
}): { name: string; category: string; words: string[] } {
  const name = requireSafeCommunityText(input.name, "Pack name").slice(0, 80);
  const category = requireSafeCommunityText(
    input.category || name,
    "Pack category",
  ).slice(0, 80);
  const words: string[] = [];
  const seen = new Set<string>();
  for (const rawWord of input.words || []) {
    const word = requireSafeCommunityText(rawWord, "Pack word").slice(0, 80);
    const key = word.toLocaleLowerCase();
    if (!word || seen.has(key)) continue;
    seen.add(key);
    words.push(word);
  }
  if (!name || words.length < 2) {
    throw Object.assign(
      new Error("A pack name and at least two words are required."),
      {
        status: 422,
        code: "invalid_word_pack",
      },
    );
  }
  return { name, category: category || name, words };
}

export function safeCommunityDisplayName(value: unknown): string {
  const displayName = String(value ?? "")
    .replace(/[\u0000-\u001F\u007F]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 48);
  if (!displayName || classifyObjectionableMaterial(displayName)) {
    return "OPERATIVE";
  }
  return displayName;
}

export function safeCommunityAvatar(value: unknown): string {
  const avatar = String(value ?? "").trim();
  return PUBLIC_AVATARS.has(avatar) ? avatar : "🕵️";
}

export function sanitizeCommunityReportDetails(value: unknown): string {
  return String(value ?? "")
    .replace(/\r\n?/g, "\n")
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "")
    .trim()
    .slice(0, 500);
}

export function normalizeCommunityReportReason(
  value: unknown,
): CommunityReportReason | null {
  const reason = String(value ?? "").trim().toLowerCase();
  return COMMUNITY_REPORT_REASONS.includes(reason as CommunityReportReason)
    ? reason as CommunityReportReason
    : null;
}

export function blockedByUserID(
  friendship: Record<string, unknown>,
): string | null {
  if (String(friendship.status ?? "").trim() !== "blocked") return null;
  const explicit = String(friendship.blocked_by_id ?? "").trim();
  if (explicit) return explicit;
  const legacyOwner = String(friendship.requester_id ?? "").trim();
  return legacyOwner || null;
}

export function friendshipBlocksPair(
  friendship: Record<string, unknown> | null | undefined,
  firstUserID: unknown,
  secondUserID: unknown,
): boolean {
  if (!friendship || String(friendship.status ?? "") !== "blocked") {
    return false;
  }
  const first = String(firstUserID ?? "").trim();
  const second = String(secondUserID ?? "").trim();
  const requester = String(friendship.requester_id ?? "").trim();
  const addressee = String(friendship.addressee_id ?? "").trim();
  return (requester === first && addressee === second) ||
    (requester === second && addressee === first);
}
