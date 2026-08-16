import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  classifyObjectionableMaterial,
  filterSafeCommunityStrings,
  ObjectionableCommunityContentError,
  requireSafeCommunityText,
  safeCommunityTextForDisplay,
} from "./content-safety.ts";

Deno.test("AI pack safety catches zalup variants", () => {
  for (
    const value of [
      "ZALUPA",
      "ЗАЛУПА",
      "zalup",
      "залуп",
      "za.lu-pa",
      "za lu pa",
      "zal upa",
      "zal u p a",
      "за лу па",
      "zаlupa",
      "3a1up4",
      "zаluрa",
      "z@lup@",
      "za|upa",
      "z a l u p a",
      "з а л у п а",
      "z4lup4",
    ]
  ) {
    assertEquals(classifyObjectionableMaterial(value), "abusive_language");
    assertEquals(
      safeCommunityTextForDisplay(value, "CLASSIFIED"),
      "CLASSIFIED",
    );
  }
  assertEquals(classifyObjectionableMaterial("Pizza Lupin"), null);
  assertEquals(
    safeCommunityTextForDisplay("Pizza Lupin", "CLASSIFIED"),
    "Pizza Lupin",
  );
});

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
