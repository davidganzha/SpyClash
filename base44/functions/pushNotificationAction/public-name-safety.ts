// Function-local copy: Base44 deploys each function directory independently.
const ZERO_WIDTH = /[\u200B-\u200D\u2060\uFEFF]/g;
const COMBINING_MARKS = /\p{M}+/gu;
const NON_ALPHANUMERIC = /[^\p{L}\p{N}]+/gu;
const NON_ALPHANUMERIC_EXCEPT_WHITESPACE = /[^\p{L}\p{N}\s]+/gu;

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

const OBJECTIONABLE_ROOT_EQUIVALENTS: Record<string, string> = {
  "z": "z",
  "з": "z",
  "3": "z",
  "a": "a",
  "а": "a",
  "4": "a",
  "l": "l",
  "л": "l",
  "1": "l",
  "u": "u",
  "у": "u",
  "p": "p",
  "п": "p",
  "р": "p",
  "@": "a",
  "|": "l",
};

const OBJECTIONABLE_TOKENS = new Set([
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
  "faggot",
  "kike",
  "nigger",
  "пидор",
  "пидарас",
  "maricon",
]);
const OBJECTIONABLE_TOKEN_PREFIXES = ["zalup", "залуп"] as const;

const OBJECTIONABLE_PHRASES = [
  "child porn",
  "child pornography",
  "детское порно",
  "pornografia infantil",
  "i will kill you",
  "im going to kill you",
  "kill them all",
  "я тебя убью",
  "убью тебя",
  "убить вас всех",
  "te voy a matar",
  "voy a matarte",
  "kill yourself",
  "go kill yourself",
  "убей себя",
  "покончи с собой",
  "matate",
] as const;

function normalizedBase(value: unknown): string {
  return String(value ?? "")
    .normalize("NFKD")
    .replace(COMBINING_MARKS, "")
    .replace(ZERO_WIDTH, "")
    .toLocaleLowerCase()
    .replace(
      /[01345789]/g,
      (character) => LEET_EQUIVALENTS[character] || character,
    );
}

function normalizedSafetyText(value: unknown): string {
  return normalizedBase(value)
    .replace(NON_ALPHANUMERIC, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function punctuationCompactedSafetyText(value: unknown): string {
  return normalizedBase(value)
    .replace(NON_ALPHANUMERIC_EXCEPT_WHITESPACE, "")
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

function containsObjectionableRoot(value: unknown): boolean {
  const chunks = String(value ?? "")
    .normalize("NFKD")
    .replace(COMBINING_MARKS, "")
    .replace(ZERO_WIDTH, "")
    .toLocaleLowerCase()
    .replace(/[@|]/g, (character) => OBJECTIONABLE_ROOT_EQUIVALENTS[character])
    .replace(NON_ALPHANUMERIC, " ")
    .split(/\s+/)
    .filter(Boolean);
  let crossChunkRun = "";
  for (const chunk of chunks) {
    let tokenCanonical = "";
    let tokenIsRootOnly = true;
    let innerRun = "";
    for (const character of chunk) {
      const equivalent = OBJECTIONABLE_ROOT_EQUIVALENTS[character];
      if (!equivalent) {
        tokenIsRootOnly = false;
        innerRun = "";
        continue;
      }
      tokenCanonical += equivalent;
      innerRun += equivalent;
      if (innerRun.includes("zalup")) return true;
    }
    if (!tokenIsRootOnly) {
      crossChunkRun = "";
      continue;
    }
    crossChunkRun += tokenCanonical;
    if (crossChunkRun.includes("zalup")) return true;
  }
  return false;
}

function unsafePublicName(value: unknown): boolean {
  const normalized = normalizedSafetyText(value);
  if (!normalized) return true;
  const tokens = [
    ...safetyTokens(normalized),
    ...safetyTokens(punctuationCompactedSafetyText(value)),
  ];
  if (
    containsObjectionableRoot(value) ||
    tokens.some((token) =>
      token === "kys" || OBJECTIONABLE_TOKENS.has(token) ||
      OBJECTIONABLE_TOKEN_PREFIXES.some((prefix) => token.startsWith(prefix))
    )
  ) return true;
  const padded = ` ${normalized} `;
  return OBJECTIONABLE_PHRASES.some((phrase) => padded.includes(` ${phrase} `));
}

export function safePushActorName(value: unknown): string {
  const candidate = String(value ?? "")
    .replace(/[\u0000-\u001F\u007F]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 48);
  return candidate && !unsafePublicName(candidate) ? candidate : "An operative";
}
