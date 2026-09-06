import { assertEquals } from "jsr:@std/assert@1";

const fixtureURL = new URL(
  "../../scripts/tests/fixtures/notification-step-a-schema-response.json",
  import.meta.url,
);

/** Archived 22-entity Step A response checked in by 3421db8. Its pre-notification
 * projection must continue matching the approved f09988… Step 0 schema digest.
 * Pin the archive itself so current entity additions never redefine history. */
export async function readHistoricalNotificationSchemas(): Promise<
  Array<Record<string, unknown>>
> {
  const bytes = await Deno.readFile(fixtureURL);
  const digest = [
    ...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)),
  ]
    .map((byte) => byte.toString(16).padStart(2, "0")).join("");
  assertEquals(
    digest,
    "e4e0790067df81ea3e71af603193434e9bb8ee0a4e8acd2228f8249a829d70f8",
    "The approved notification archive must not drift with current schemas",
  );
  const response = JSON.parse(new TextDecoder().decode(bytes)) as {
    total: number;
    schemas: Array<
      { entity_name: string; entity_schema: Record<string, unknown> }
    >;
  };
  assertEquals(response.total, 22);
  assertEquals(response.schemas.length, 22);
  assertEquals(
    new Set(response.schemas.map((row) => row.entity_name)).size,
    22,
  );
  for (const row of response.schemas) {
    assertEquals(row.entity_name, row.entity_schema.name);
  }
  return response.schemas.map((row) => row.entity_schema);
}
