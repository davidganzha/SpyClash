import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  applyWordPackQualityAudit,
  buildWordPackQualityAuditPrompt,
  requireWordPackRepairQuality,
  wordPackQualityAuditSchema,
  WordPackQualityGateError,
} from "./word-pack-quality.ts";

Deno.test("named-theme quality audit rejects adjacent anime and rapper concepts", () => {
  const animePrompt = buildWordPackQualityAuditPrompt({
    theme: "Имена аниме персонажей",
    language: "ru",
    requestedCount: 25,
    alreadyExcluded: ["Гоку"],
    words: ["Наруто Удзумаки", "Сёнэн", "Ниндзя"],
  });
  const rapperPrompt = buildWordPackQualityAuditPrompt({
    theme: "Русские популярные реперы",
    language: "ru",
    requestedCount: 25,
    alreadyExcluded: ["Oxxxymiron"],
    words: ["Баста", "Микрофон", "Студия"],
  });

  for (const prompt of [animePrompt, rapperPrompt]) {
    assert(prompt.includes("strictly as data"));
    assert(prompt.includes("truthful direct member"));
    assert(prompt.includes("proper name of one specific matching entity"));
    assert(prompt.includes("preserve the requested answer type"));
    assert(prompt.includes("If and only if the grammatical answer type"));
    assert(prompt.includes("Do not accept an item just to reach a quota"));
    assert(prompt.includes("return enough unique replacement words"));
  }
  assert(animePrompt.includes("shonen, shojo, seinen, josei, mecha, isekai"));
  assert(rapperPrompt.includes("microphone, beat, rhyme, studio, and concert"));
});

Deno.test("quality repair accepts a full pack despite an unused rejected extra", () => {
  requireWordPackRepairQuality({
    returnedCount: 25,
    requestedCount: 25,
    rejectedCount: 1,
    exhausted: false,
  });
  requireWordPackRepairQuality({
    returnedCount: 4,
    requestedCount: 25,
    rejectedCount: 1,
    exhausted: true,
  });

  for (
    const input of [
      {
        returnedCount: 24,
        requestedCount: 25,
        rejectedCount: 0,
        exhausted: false,
      },
    ]
  ) {
    assertThrows(
      () => requireWordPackRepairQuality(input),
      WordPackQualityGateError,
    );
  }
});

Deno.test("quality audit keeps accepted candidates in original order", () => {
  assertEquals(
    applyWordPackQualityAudit(
      ["Наруто Удзумаки", "Сёнэн", "Сейлор Мун"],
      {
        accepted_indices: [2, 0],
        replacement_words: ["Монки Д. Луффи"],
        exhausted: false,
      },
    ),
    {
      words: ["Наруто Удзумаки", "Сейлор Мун"],
      replacementWords: ["Монки Д. Луффи"],
      rejectedCount: 1,
      exhausted: false,
    },
  );
});

Deno.test("quality audit schema and parser fail closed on invalid indices", () => {
  const schema = wordPackQualityAuditSchema(3, 25);
  assertEquals(schema.properties.accepted_indices.items.minimum, 0);
  assertEquals(schema.properties.accepted_indices.items.maximum, 2);
  assertEquals(schema.properties.accepted_indices.maxItems, 3);
  assertEquals(schema.properties.replacement_words.maxItems, 25);
  assertEquals(
    schema.required,
    ["accepted_indices", "replacement_words", "exhausted"],
  );

  for (const accepted_indices of [[0, 0], [-1], [3], [1.5], ["0"], null]) {
    const error = assertThrows(
      () =>
        applyWordPackQualityAudit(["A", "B", "C"], {
          accepted_indices,
          replacement_words: [],
          exhausted: false,
        }),
      WordPackQualityGateError,
    );
    assertEquals(error.code, "ai_output_failed_quality_gate");
    assertEquals(error.status, 502);
    assertEquals(error.retryable, true);
  }

  assertEquals(
    applyWordPackQualityAudit([], {
      accepted_indices: [],
      replacement_words: ["Баста", "Noize MC"],
      exhausted: false,
    }),
    {
      words: [],
      replacementWords: ["Баста", "Noize MC"],
      rejectedCount: 0,
      exhausted: false,
    },
  );
});
