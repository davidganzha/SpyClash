import { assertEquals } from "jsr:@std/assert@1";
import { uniqueWords } from "./word-normalization.ts";

Deno.test("structured AI names retain commas and semicolons as one entry", () => {
  assertEquals(uniqueWords(["Тайлер, The Creator", "Tyler, The Creator", "AC;DC", "Nas"]),
    ["Тайлер, The Creator", "Tyler, The Creator", "AC;DC", "Nas"]);
});

Deno.test("normalization still cleans whitespace and deduplicates whole names", () => {
  assertEquals(uniqueWords([" Tyler,  The Creator ", "TYLER, THE CREATOR", "The Creator", "", null]),
    ["Tyler, The Creator", "The Creator"]);
});
