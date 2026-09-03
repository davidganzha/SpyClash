import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

Deno.test("best-effort push paths reduce arbitrary SDK errors before logging", async () => {
  const main = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const backfill = await Deno.readTextFile(
    new URL("./inbox-backfill.ts", import.meta.url),
  );

  for (const label of [
    "terminal intent reconciliation deferred",
    "finished room community profile repair deferred",
    "durable community profile repair drain deferred",
    "room reconciliation checkpoint deferred",
    "room reconciliation cursor advance deferred",
    "live activity terminal probe prompt deferred",
  ]) {
    const labelIndex = main.indexOf(label);
    assertEquals(labelIndex >= 0, true, `missing log site: ${label}`);
    const surroundingCatch = main.slice(
      Math.max(0, main.lastIndexOf("catch", labelIndex)),
      main.indexOf(");", labelIndex) + 2,
    );
    assertStringIncludes(surroundingCatch, "safePushErrorDetails(error)");
    assertStringIncludes(surroundingCatch, "details.message");
    assertStringIncludes(surroundingCatch, "details.status || 500");
  }

  for (const label of [
    "legacy inbox backfill retry rotation failed",
    "legacy inbox backfill row failed",
  ]) {
    const labelIndex = backfill.indexOf(label);
    assertEquals(labelIndex >= 0, true, `missing log site: ${label}`);
    const surroundingCatch = backfill.slice(
      Math.max(0, backfill.lastIndexOf("catch", labelIndex)),
      backfill.indexOf(");", labelIndex) + 2,
    );
    assertStringIncludes(surroundingCatch, "safePushErrorDetails(");
    assertStringIncludes(surroundingCatch, "details.message");
    assertStringIncludes(surroundingCatch, "details.status || 500");
  }
});
