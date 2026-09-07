export function cleanWord(value: unknown) {
  return String(value || "")
    .replace(/^[\s,;.\-–—"'`]+|[\s,;.\-–—"'`]+$/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

export function uniqueWords(values: unknown[]) {
  const seen = new Set<string>();
  const words: string[] = [];
  // Each structured AI array item is one entry, even when its name contains punctuation.
  for (const rawValue of values || []) {
    const word = cleanWord(rawValue).slice(0, 120).trim();
    const key = word.toLowerCase();
    if (!word || seen.has(key)) continue;
    seen.add(key);
    words.push(word);
  }
  return words;
}
