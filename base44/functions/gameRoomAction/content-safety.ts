// Function-local copy: Base44 deploys each function directory independently.
const ZERO_WIDTH = /[\u200B-\u200D\u2060\uFEFF]/g;
const COMBINING_MARKS = /\p{M}+/gu;
const NON_ALPHANUMERIC = /[^\p{L}\p{N}]+/gu;
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

export class ObjectionableCommunityContentError extends Error {
  readonly status = 422;
  readonly code = "objectionable_content";
  constructor(public readonly field: string) {
    super(`${field} contains content that is not allowed.`);
    this.name = "ObjectionableCommunityContentError";
  }
}

function normalizedSafetyText(value: unknown): string {
  return String(value ?? "").normalize("NFKD").replace(COMBINING_MARKS, "")
    .replace(ZERO_WIDTH, "").toLocaleLowerCase()
    .replace(
      /[01345789]/g,
      (character) => LEET_EQUIVALENTS[character] || character,
    )
    .replace(NON_ALPHANUMERIC, " ").replace(/\s+/g, " ").trim();
}

function safetyTokens(normalized: string): string[] {
  const tokens = normalized.split(" ").filter(Boolean);
  const expanded = [...tokens];
  let run = "";
  for (const token of [...tokens, "boundary"]) {
    if (token.length === 1) {
      run += token;
    } else {
      if (run.length >= 3) expanded.push(run);
      run = "";
    }
  }
  return expanded;
}

function includesPhrase(normalized: string, phrases: readonly string[]) {
  const padded = ` ${normalized} `;
  return phrases.some((phrase) => padded.includes(` ${phrase} `));
}

export function classifyObjectionableMaterial(value: unknown): string | null {
  const normalized = normalizedSafetyText(value);
  if (!normalized) return null;
  const tokens = safetyTokens(normalized);
  if (tokens.some((token) => HATE_TOKENS.has(token))) return "hate_speech";
  if (includesPhrase(normalized, SEXUAL_EXPLOITATION_PHRASES)) {
    return "sexual_exploitation";
  }
  if (includesPhrase(normalized, THREAT_PHRASES)) return "violence_or_threats";
  if (tokens.includes("kys") || includesPhrase(normalized, SELF_HARM_PHRASES)) {
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
  const text = String(value ?? "").replace(/[\u0000-\u001F\u007F]/g, " ")
    .replace(/\s+/g, " ").trim();
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

export function safeCommunityDisplayName(value: unknown): string {
  const name = String(value ?? "").replace(/[\u0000-\u001F\u007F]/g, "")
    .replace(/\s+/g, " ").trim().slice(0, 48);
  return name && !classifyObjectionableMaterial(name) ? name : "OPERATIVE";
}

export function safeCommunityAvatar(value: unknown): string {
  const avatar = String(value ?? "").trim();
  return PUBLIC_AVATARS.has(avatar) ? avatar : "🕵️";
}
