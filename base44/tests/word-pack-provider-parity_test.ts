import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

Deno.test("legacy, native relay, and native direct generation share identical naming and cache policy", async () => {
  const paths = [
    "../functions/generateWordPack/openai-word-pack-provider.ts",
    "../functions/nativeGameCenterWordPack/openai-word-pack-provider.ts",
    "../../experiments/supabase-game-core/supabase/functions/app-services/word-generation/openai-word-pack-provider.ts",
  ];
  const sources = await Promise.all(
    paths.map((path) => Deno.readTextFile(new URL(path, import.meta.url))),
  );
  assertEquals(sources[1], sources[0]);
  assertEquals(sources[2], sources[0]);
  assertStringIncludes(sources[0], "canonical-names-v3");
});
