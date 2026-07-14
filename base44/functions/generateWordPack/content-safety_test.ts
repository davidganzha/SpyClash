import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  filterSafeCommunityStrings,
  ObjectionableCommunityContentError,
  requireSafeCommunityText,
  safeCommunityTextForDisplay,
} from "./content-safety.ts";

Deno.test("AI word-pack input rejects objectionable themes before generation", () => {
  assertThrows(
    () => requireSafeCommunityText("k1ll yourself", "Theme"),
    ObjectionableCommunityContentError,
  );
  assertEquals(
    requireSafeCommunityText("Classic cinema", "Theme"),
    "Classic cinema",
  );
});

Deno.test("AI word-pack output removes unsafe words and replaces unsafe category", () => {
  assertEquals(
    filterSafeCommunityStrings(["Embassy", "f.u.c.k", "Museum"]),
    ["Embassy", "Museum"],
  );
  assertEquals(
    safeCommunityTextForDisplay("k1ll yourself", "CLASSIC"),
    "CLASSIC",
  );
});
