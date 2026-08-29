import { assertEquals } from "jsr:@std/assert@1";

const userSchemaURL = new URL("../entities/User.jsonc", import.meta.url);

Deno.test("User onboarding fields are optional self-editable account metadata", async () => {
  const schema = JSON.parse(await Deno.readTextFile(userSchemaURL));
  const properties = schema.properties as Record<
    string,
    Record<string, unknown>
  >;
  const required = Array.isArray(schema.required) ? schema.required : [];

  assertEquals(properties.language.type, "string");
  assertEquals(properties.language.enum, ["ru", "en", "es", "uk"]);

  assertEquals(properties.onboarding_completed.type, "boolean");
  assertEquals("default" in properties.onboarding_completed, false);

  assertEquals(properties.onboarding_version.type, "integer");
  assertEquals(properties.onboarding_version.minimum, 1);
  assertEquals("default" in properties.onboarding_version, false);

  assertEquals(properties.onboarding_completed_at.type, "string");
  assertEquals(properties.onboarding_completed_at.format, "date-time");
  assertEquals("default" in properties.onboarding_completed_at, false);

  assertEquals(properties.acquisition_source.type, "string");
  assertEquals(properties.acquisition_source.enum, [
    "chatgpt",
    "app_store_search",
    "web_search",
    "social_media",
    "friends_or_family",
    "other",
  ]);
  assertEquals("default" in properties.acquisition_source, false);

  for (
    const field of [
      "onboarding_completed",
      "onboarding_version",
      "onboarding_completed_at",
      "acquisition_source",
    ]
  ) {
    assertEquals(
      required.includes(field),
      false,
      `${field} must remain optional`,
    );
    assertEquals(
      "rls" in properties[field],
      false,
      `${field} must remain self-editable through the built-in User boundary`,
    );
  }
});
