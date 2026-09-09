import {
  appleRequestErrorResponse,
  RequestError,
} from "./apple-request-error.ts";
import { AppleAccountLeaseGuardError } from "./apple-account-lease-guard.ts";

function assertEquals(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

const PUBLIC_FAILURE = "Unable to verify App Store entitlement.";

Deno.test("active binding contention serializes a retryable 503 without its internal details", async () => {
  const response = appleRequestErrorResponse(
    new RequestError(
      "Apple account binding is being updated. Retry shortly.",
      503,
      "apple_account_binding_busy",
    ),
    PUBLIC_FAILURE,
    503,
  );
  assertEquals(response.status, 503);
  assertEquals(await response.json(), {
    error: PUBLIC_FAILURE,
    code: "apple_account_binding_busy",
    retryable: true,
  });
});

Deno.test("unavailable binding, verification, and lost lease 503s remain generic without retry metadata", async () => {
  const failures = [
    new RequestError("Apple account binding is not available yet.", 503),
    new RequestError(
      "Apple account binding changed concurrently. Retry shortly.",
      503,
    ),
    new RequestError("Private server configuration detail", 503),
    new RequestError("Private Apple verification detail", 503),
    new AppleAccountLeaseGuardError("Private lease ownership detail"),
  ];
  for (const error of failures) {
    const response = appleRequestErrorResponse(error, PUBLIC_FAILURE, 503);
    assertEquals(response.status, 503);
    assertEquals(await response.json(), { error: PUBLIC_FAILURE });
  }
});

Deno.test("an untyped error cannot opt a server failure into client retries", async () => {
  const error = Object.assign(new Error("Private provider detail"), {
    status: 503,
    code: "apple_account_binding_busy",
    retryable: true,
  });
  const response = appleRequestErrorResponse(error, PUBLIC_FAILURE, 503);
  assertEquals(await response.json(), { error: PUBLIC_FAILURE });
});

Deno.test("binding retry metadata requires both the typed error status and HTTP status to be 503", async () => {
  for (
    const [errorStatus, httpStatus] of [[409, 409], [409, 503], [503, 500]]
  ) {
    const error = new RequestError(
      "Private ownership detail",
      errorStatus,
      "apple_account_binding_busy",
    );
    const response = appleRequestErrorResponse(
      error,
      PUBLIC_FAILURE,
      httpStatus,
    );
    assertEquals(response.status, httpStatus);
    assertEquals(await response.json(), { error: PUBLIC_FAILURE });
  }
});
