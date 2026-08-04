import { assertEquals } from "jsr:@std/assert@1";
import { hasValidEnabledStartWordPool } from "./start-word-pool-policy.ts";

Deno.test("start requires two unique enabled words including the secret", () => {
  assertEquals(
    hasValidEnabledStartWordPool(
      [
        { word: "Embassy", enabled: true },
        { word: "Harbor", enabled: true },
      ],
      "Embassy",
    ),
    true,
  );

  assertEquals(
    hasValidEnabledStartWordPool(
      [
        { word: "Embassy", enabled: true },
        { word: "Harbor", enabled: false },
      ],
      "Embassy",
    ),
    false,
  );

  assertEquals(
    hasValidEnabledStartWordPool(
      [
        { word: "Embassy", enabled: true },
        { word: " EMBASSY ", enabled: true },
      ],
      "Embassy",
    ),
    false,
  );

  assertEquals(
    hasValidEnabledStartWordPool(
      [
        { word: "Embassy", enabled: false },
        { word: "Harbor", enabled: true },
        { word: "Museum", enabled: true },
      ],
      "Embassy",
    ),
    false,
  );
});
