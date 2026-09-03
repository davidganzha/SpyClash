import { assertEquals } from "jsr:@std/assert@1";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import { wordPackLifecycleErrorResponse } from "./lifecycle-error-response.ts";

Deno.test("word-pack pre-action contention is retryable", async () => {
  for (const code of ["active_lease", "cas_contention"] as const) {
    const response = wordPackLifecycleErrorResponse(
      new BillingIdentityLifecycleError(code, "Word packs are busy."),
    );
    assertEquals(response.status, 409);
    assertEquals(response.headers.get("Retry-After"), "1");
    assertEquals(await response.json(), {
      error: "Word packs are busy.",
      code,
      retryable: true,
    });
  }
});

Deno.test("word-pack deletion and ambiguous lifecycle stay fail-closed", async () => {
  const deletion = wordPackLifecycleErrorResponse(
    new BillingIdentityLifecycleError(
      "deletion_in_progress",
      "Account deletion is in progress.",
    ),
  );
  assertEquals(deletion.status, 409);
  assertEquals(deletion.headers.get("Retry-After"), null);
  assertEquals(await deletion.json(), {
    error: "Account deletion is in progress.",
    code: "deletion_in_progress",
  });

  const ambiguous = wordPackLifecycleErrorResponse(
    new BillingIdentityLifecycleError(
      "ambiguous",
      "Lifecycle state is ambiguous.",
    ),
  );
  assertEquals(ambiguous.status, 503);
  assertEquals(ambiguous.headers.get("Retry-After"), null);
  assertEquals(await ambiguous.json(), {
    error: "Lifecycle state is ambiguous.",
    code: "ambiguous",
  });
});
