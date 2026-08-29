import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  applyWordPackSelfAudit,
  WordPackQualityGateError,
  wordPackSelfAuditSchema,
} from "./word-pack-quality.ts";

Deno.test("single-pass quality audit keeps accepted drafts in order and appends replacements", () => {
  assertEquals(
    applyWordPackSelfAudit({
      draft_words: ["Наруто Удзумаки", "Сёнэн", "Сейлор Мун"],
      accepted_indices: [2, 0],
      replacement_words: ["Монки Д. Луффи"],
      accepted_replacement_indices: [0],
      category: "Имена аниме персонажей",
      exhausted: false,
    }, 3),
    {
      words: ["Наруто Удзумаки", "Сейлор Мун", "Монки Д. Луффи"],
      category: "Имена аниме персонажей",
      exhausted: false,
      rejectedCount: 1,
      replacementCount: 1,
    },
  );
});

Deno.test("single-pass quality audit deduplicates replacements before enforcing count", () => {
  assertEquals(
    applyWordPackSelfAudit({
      draft_words: ["Баста", "Микрофон", "Noize MC"],
      accepted_indices: [0, 2],
      replacement_words: ["баста", "Oxxxymiron"],
      accepted_replacement_indices: [0, 1],
      category: "Русские популярные рэперы",
      exhausted: false,
    }, 3),
    {
      words: ["Баста", "Noize MC", "Oxxxymiron"],
      category: "Русские популярные рэперы",
      exhausted: false,
      rejectedCount: 2,
      replacementCount: 1,
    },
  );
});

Deno.test("single-pass quality audit never re-accepts a rejected draft as a replacement", () => {
  assertThrows(
    () =>
      applyWordPackSelfAudit({
        draft_words: ["Tom Hanks", "Camera", "Meryl Streep"],
        accepted_indices: [0, 2],
        replacement_words: ["Camera"],
        accepted_replacement_indices: [0],
        category: "Famous actors",
        exhausted: false,
      }, 3),
    WordPackQualityGateError,
  );
});

Deno.test("single-pass quality audit excludes forbidden draft and replacement words", () => {
  assertEquals(
    applyWordPackSelfAudit(
      {
        draft_words: ["Mars", "Venus", "Earth"],
        accepted_indices: [0, 1, 2],
        replacement_words: ["Mercury"],
        accepted_replacement_indices: [0],
        category: "Planets",
        exhausted: false,
      },
      3,
      ["Mars"],
    ),
    {
      words: ["Venus", "Earth", "Mercury"],
      category: "Planets",
      exhausted: false,
      rejectedCount: 1,
      replacementCount: 1,
    },
  );
});

Deno.test("single-pass quality schema binds draft, audit, replacements and exhaustion", () => {
  const schema = wordPackSelfAuditSchema({
    requestedCount: 25,
    draftDescription: "Exact-theme draft words.",
    categoryDescription: "Theme label.",
    exhaustedDescription: "True only when the exact set is exhausted.",
  });

  assertEquals(schema.properties.draft_words.maxItems, 25);
  assertEquals(schema.properties.accepted_indices.items.minimum, 0);
  assertEquals(schema.properties.accepted_indices.items.maximum, 24);
  assertEquals(schema.properties.accepted_indices.maxItems, 25);
  assertEquals(schema.properties.replacement_words.maxItems, 25);
  assertEquals(
    schema.properties.accepted_replacement_indices.items.maximum,
    24,
  );
  assertEquals(schema.required, [
    "draft_words",
    "accepted_indices",
    "replacement_words",
    "accepted_replacement_indices",
    "category",
    "exhausted",
  ]);
  assertEquals(schema.additionalProperties, false);
});

Deno.test("single-pass quality gate fails closed on invalid or incomplete audits", () => {
  const base = {
    draft_words: ["A", "B", "C"],
    accepted_indices: [0, 1, 2],
    replacement_words: [],
    accepted_replacement_indices: [],
    category: "Letters",
    exhausted: false,
  };

  for (
    const candidate of [
      { ...base, accepted_indices: [0, 0, 2] },
      { ...base, accepted_indices: [-1, 1, 2] },
      { ...base, accepted_indices: [0, 1, 3] },
      { ...base, accepted_indices: [0, 1.5, 2] },
      { ...base, accepted_indices: ["0", 1, 2] },
      { ...base, accepted_replacement_indices: [0] },
      { ...base, accepted_indices: [0, 1], exhausted: false },
      { ...base, exhausted: true },
      { ...base, unexpected: true },
    ]
  ) {
    const error = assertThrows(
      () => applyWordPackSelfAudit(candidate, 3),
      WordPackQualityGateError,
    );
    assertEquals(error.code, "ai_output_failed_quality_gate");
    assertEquals(error.status, 502);
    assertEquals(error.retryable, true);
  }
});

Deno.test("single-pass quality gate permits a truthful exhausted short pack", () => {
  assertEquals(
    applyWordPackSelfAudit({
      draft_words: ["Mercury", "Venus"],
      accepted_indices: [0, 1],
      replacement_words: [],
      accepted_replacement_indices: [],
      category: "Planets near the Sun",
      exhausted: true,
    }, 10),
    {
      words: ["Mercury", "Venus"],
      category: "Planets near the Sun",
      exhausted: true,
      rejectedCount: 0,
      replacementCount: 0,
    },
  );
});
