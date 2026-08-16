import { assertEquals } from "jsr:@std/assert@1";
import {
  classifyObjectionableMaterial,
  safeCommunityDisplayName,
  safeCommunityTextForDisplay,
} from "./content-safety.ts";

Deno.test("shared pack safety catches zalup variants and public fallback", () => {
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
    assertEquals(safeCommunityDisplayName(value), "OPERATIVE");
  }
  assertEquals(classifyObjectionableMaterial("Pizza Lupin"), null);
  assertEquals(
    safeCommunityTextForDisplay("Pizza Lupin", "CLASSIFIED"),
    "Pizza Lupin",
  );
  assertEquals(safeCommunityDisplayName("Pizza Lupin"), "Pizza Lupin");
});
