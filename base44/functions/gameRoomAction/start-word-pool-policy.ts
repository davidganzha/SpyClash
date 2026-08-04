export type StartWordPoolEntry = {
  word?: unknown;
  enabled?: unknown;
};

function normalizedWordKey(value: unknown): string {
  return String(value ?? "").normalize("NFKC").trim().toLocaleLowerCase();
}

export function hasValidEnabledStartWordPool(
  wordPool: readonly StartWordPoolEntry[],
  secretWord: unknown,
): boolean {
  const enabledWordKeys = new Set(
    wordPool
      .filter((entry) => entry?.enabled === true)
      .map((entry) => normalizedWordKey(entry.word))
      .filter(Boolean),
  );
  const secretWordKey = normalizedWordKey(secretWord);
  return enabledWordKeys.size >= 2 && enabledWordKeys.has(secretWordKey);
}
