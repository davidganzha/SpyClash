import { assertEquals } from "jsr:@std/assert@1";

const communityActionURL = new URL(
  "../functions/communityAction/main.ts",
  import.meta.url,
);

Deno.test("profile updates cannot overwrite the independent language preference", async () => {
  const source = await Deno.readTextFile(communityActionURL);
  const start = source.indexOf('if (action === "update_profile")');
  const end = source.indexOf('if (action === "state")', start);
  const updateProfileAction = source.slice(start, end);

  assertEquals(start >= 0 && end > start, true);
  assertEquals(updateProfileAction.includes("language"), false);
});
