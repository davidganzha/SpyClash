import { base44 } from "@/api/base44Client";
import { dispatchWordPackGeneration } from "@/lib/wordPackTransport";

/**
 * Generates a word pool for a custom theme using AI.
 * @param {string} theme - User's theme/category input
 * @param {number} wordCount - Target number of words (default 25, max 100)
 * @param {string[]} excludedWords - Existing words that must not be repeated
 * @returns {Promise<{words: string[], display_category: string}>}
 */
export async function generateWordPool(theme, wordCount = 25, excludedWords = []) {
  const result = await dispatchWordPackGeneration({
    theme,
    count: wordCount,
    excludedWords,
    invoke: (payload) => base44.functions.invoke("generateWordPack", payload),
  });

  return {
    ...result,
    words: Array.isArray(result.words) ? result.words : [],
    display_category: result.display_category || result.category || result.name || theme,
  };
}
