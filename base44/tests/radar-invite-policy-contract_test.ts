import { assertEquals } from "jsr:@std/assert@1";

const userSchemaURL = new URL("../entities/User.jsonc", import.meta.url);

Deno.test("Radar invite policy is a shared optional User account field", async () => {
  const schema = JSON.parse(await Deno.readTextFile(userSchemaURL));
  const policy = schema.properties.radar_invite_policy;

  assertEquals(policy.type, "string");
  assertEquals(policy.enum, ["ask", "automatic", "blocked"]);
  assertEquals("default" in policy, false);
});
