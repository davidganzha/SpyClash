import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

function occurrences(source: string, needle: string): number {
  return source.split(needle).length - 1;
}

Deno.test("AI word packs bind exact-theme quality, locale, cache, and client payload", async () => {
  const main = await Deno.readTextFile(
    new URL("../functions/generateWordPack/main.ts", import.meta.url),
  );
  const provider = await Deno.readTextFile(
    new URL(
      "../functions/generateWordPack/openai-word-pack-provider.ts",
      import.meta.url,
    ),
  );
  const quality = await Deno.readTextFile(
    new URL(
      "../functions/generateWordPack/word-pack-quality.ts",
      import.meta.url,
    ),
  );
  const client = await Deno.readTextFile(
    new URL("../../SpyClash/Services/Base44Client.swift", import.meta.url),
  );
  const callSites = await Promise.all([
    "../../SpyClash/Views/GameView.swift",
    "../../SpyClash/Views/LocalGameView.swift",
    "../../SpyClash/Views/WordPacksView.swift",
  ].map((path) => Deno.readTextFile(new URL(path, import.meta.url))));

  assertStringIncludes(
    provider,
    'WORD_PACK_PROMPT_VERSION = "word-pack-2026-08-29-v4"',
  );
  assertStringIncludes(provider, 'BASE44_WORD_PACK_MODEL = "gpt_5_4"');
  assertStringIncludes(provider, "strict set-membership constraint");
  assertStringIncludes(provider, "canonical proper name");
  assert(!provider.includes("reinterpret it at a generic conceptual level"));
  assert(!provider.includes("minItems: 2"));

  assertStringIncludes(main, "parseWordPackLanguage(body.language)");
  assertStringIncludes(main, "parseWordPackLanguage(user?.language)");
  assertStringIncludes(main, 'const cacheLanguage = promptLanguage ?? "und"');
  assertStringIncludes(main, "language: cacheLanguage");
  assertStringIncludes(
    main,
    'wordPackThemeMode(theme) ===\n              "named_entities"',
  );
  assertEquals(occurrences(main, "auditNamedThemeWords("), 2);
  assertStringIncludes(
    main,
    "if (!requiresQualityAudit && !exhausted && words.length < count)",
  );
  assertStringIncludes(main, "category = theme");
  assertStringIncludes(
    main,
    'const STORED_WORD_PACK_CATEGORY = "AI GENERATED"',
  );
  assertEquals(
    occurrences(main, "category: STORED_WORD_PACK_CATEGORY"),
    2,
  );
  assertStringIncludes(main, "quality_audit_attempts");
  assertStringIncludes(main, "quality_rejected_count");
  assertEquals(
    main.match(/^\s+model: BASE44_WORD_PACK_MODEL,/gm)?.length ?? 0,
    2,
  );
  assertStringIncludes(main, "promptVersion: WORD_PACK_CACHE_VERSION");

  assertStringIncludes(quality, 'code = "ai_output_failed_quality_gate"');
  assertStringIncludes(quality, "Do not accept an item just to reach a quota");
  assert(!quality.includes("uniqueItems"));

  assertStringIncludes(client, "language: language.rawValue");
  assertStringIncludes(client, "let language: String");
  assertEquals(
    callSites.reduce(
      (total, source) =>
        total +
        (source.match(
          /generateWordPack\([\s\S]{0,220}?language: appState\.language/g,
        )?.length ?? 0),
      0,
    ),
    5,
  );
});
