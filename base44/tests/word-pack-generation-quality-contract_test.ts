import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

function occurrences(source: string, needle: string): number {
  return source.split(needle).length - 1;
}

Deno.test("AI word packs bind one-pass exact-theme quality and theme-language policy", async () => {
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
    "../../SpyClash/Views/WordPackEditorSheet.swift",
  ].map((path) => Deno.readTextFile(new URL(path, import.meta.url))));
  assertEquals(
    occurrences(callSites[3], "appState.client.generateWordPack("),
    1,
  );
  const webClient = await Deno.readTextFile(
    new URL(
      "../../.web-reference/spyclash-web/src/utils/wordPoolAI.js",
      import.meta.url,
    ),
  );

  assertStringIncludes(
    provider,
    'WORD_PACK_PROMPT_VERSION = "word-pack-2026-08-29-v5"',
  );
  assertStringIncludes(provider, 'BASE44_WORD_PACK_MODEL = "gpt_5_4"');
  assertStringIncludes(provider, "strict set-membership constraint");
  assertStringIncludes(provider, "canonical proper name");
  assertStringIncludes(provider, "assertNoKnownNamedThemeDrift");
  assertStringIncludes(provider, "SAME NATURAL LANGUAGE");
  assertStringIncludes(provider, "never use an app, device, profile");
  assert(!provider.includes("reinterpret it at a generic conceptual level"));
  assert(!provider.includes("minItems: 2"));

  assert(!main.includes("body.language"));
  assert(!main.includes("user?.language"));
  assertStringIncludes(main, 'language: "und"');
  // One definition plus one normal call. A second call exists only inside the
  // explicit exhausted-result verification branch.
  assertEquals(occurrences(main, "invokeWordPackLLM("), 3);
  assertStringIncludes(main, "if (exhausted)");
  assertStringIncludes(main, "exhaustion_verification_used");
  assertEquals(occurrences(main, "auditNamedThemeWords("), 0);
  assertEquals(occurrences(main, "optional refill"), 0);
  assertStringIncludes(main, "assertNoKnownNamedThemeDrift(theme, words)");
  assertStringIncludes(main, "category = theme");
  assertStringIncludes(
    main,
    'const STORED_WORD_PACK_CATEGORY = "AI GENERATED"',
  );
  assertEquals(
    occurrences(main, "category: STORED_WORD_PACK_CATEGORY"),
    2,
  );
  assertStringIncludes(main, "single_pass_quality_gate");
  assertStringIncludes(main, "ai_duration_ms");
  assertStringIncludes(main, "quality_rejected_count");
  assertEquals(
    main.match(/^\s+model: BASE44_WORD_PACK_MODEL,/gm)?.length ?? 0,
    1,
  );
  assertStringIncludes(main, "promptVersion: WORD_PACK_CACHE_VERSION");

  assertStringIncludes(quality, 'code = "ai_output_failed_quality_gate"');
  assertStringIncludes(quality, "draft_words");
  assertStringIncludes(quality, "accepted_indices");
  assertStringIncludes(quality, "replacement_words");
  assertStringIncludes(quality, "accepted_replacement_indices");
  assertStringIncludes(quality, "applyWordPackSelfAudit");
  assert(!quality.includes("uniqueItems"));

  const payloadStart = client.indexOf("private struct GenerateWordPackPayload");
  const payloadEnd = client.indexOf(
    "private struct AssociationState",
    payloadStart,
  );
  const payload = client.slice(payloadStart, payloadEnd);
  assert(!payload.includes("language"));
  assertEquals(
    callSites.reduce(
      (total, source) =>
        total +
        (source.match(
          /generateWordPack\([\s\S]{0,220}?language: appState\.language/g,
        )?.length ?? 0),
      0,
    ),
    0,
  );
  assert(!webClient.match(/generateWordPack[\s\S]{0,180}?language\s*:/));
});
