import { assertEquals } from "jsr:@std/assert@1";
import { uniqueWords } from "./word-normalization.ts";

Deno.test("structured boss names preserve punctuation instead of becoming extra words", () => {
  const words = [
    "Маления, Клинок Микеллы",
    "Астель, Рожденный Бездной",
    "Двое из кожи богов",
    "AC;DC",
  ];
  assertEquals(uniqueWords(words), words);
});

Deno.test("normalization deduplicates whole entries without changing internal punctuation", () => {
  assertEquals(
    uniqueWords([
      "  Маления,  Клинок Микеллы  ",
      "маления, клинок микеллы",
      "  Астель, Рожденный Бездной  ",
      "",
      "   ",
    ]),
    ["Маления, Клинок Микеллы", "Астель, Рожденный Бездной"],
  );
});
