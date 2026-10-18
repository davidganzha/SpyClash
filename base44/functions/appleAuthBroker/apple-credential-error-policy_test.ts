import { AppleSignInCredentialError, appleCredentialFailureDiagnostics } from "./apple-sign-in-credential.ts";
import { publicAppleCredentialBrokerError } from "./apple-credential-error-policy.ts";

function assertEquals<T>(actual: T, expected: T, message: string) {
  if (actual !== expected) {
    throw new Error(
      `${message}: expected ${String(expected)}, got ${String(actual)}`,
    );
  }
}

Deno.test("temporary Apple credential failures remain HTTP 503", () => {
  for (const status of [500, 502, 503]) {
    const mapped = publicAppleCredentialBrokerError(
      new AppleSignInCredentialError(
        "apple_credential_deletion_in_progress",
        status,
        "Internal lifecycle detail that must not be exposed.",
      ),
    );

    assertEquals(
      mapped?.code,
      "temporarily_unavailable",
      "public code drifted",
    );
    assertEquals(mapped?.status, 503, "temporary status became a generic 500");
  }
});

Deno.test("client-invalid Apple credentials remain invalid grants", () => {
  for (const status of [400, 401, 409]) {
    const mapped = publicAppleCredentialBrokerError(
      new AppleSignInCredentialError(
        "apple_credential_invalid",
        status,
        "Internal validation detail that must not be exposed.",
      ),
    );

    assertEquals(mapped?.code, "invalid_grant", "public code drifted");
    assertEquals(mapped?.status, 400, "client error status drifted");
  }
});

Deno.test("unrelated failures are not misclassified as Apple credentials", () => {
  assertEquals(
    publicAppleCredentialBrokerError(new Error("storage unavailable")),
    undefined,
    "unrelated error was mapped",
  );
});

Deno.test("private lifecycle diagnosis preserves cause without changing public response", () => {
  const error = new AppleSignInCredentialError(
    "apple_credential_lifecycle_unavailable", 503,
    "Synthetic private identity and token must never appear in diagnostics", "active_lease",
  );
  assertEquals(JSON.stringify(appleCredentialFailureDiagnostics(error)),
    JSON.stringify({ credential_code: "apple_credential_lifecycle_unavailable", lifecycle_code: "active_lease" }),
    "safe lifecycle cause was lost");
  assertEquals(JSON.stringify(publicAppleCredentialBrokerError(error)),
    JSON.stringify({ code: "temporarily_unavailable", status: 503 }), "public surface changed");
  const untrusted = new AppleSignInCredentialError("private-token", 503, "private-message");
  assertEquals(JSON.stringify(appleCredentialFailureDiagnostics(untrusted)), "{}", "unknown code leaked");
  assertEquals(JSON.stringify(appleCredentialFailureDiagnostics({
    code: "apple_credential_invalid", lifecycleCode: "active_lease", config: { token: "private-token" },
  })), "{}", "untyped SDK object entered private diagnostics");
});

Deno.test("broker response path applies the Apple credential policy", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const responseOffset = source.indexOf("function errorResponse(");
  const handlerOffset = source.indexOf("Deno.serve", responseOffset);
  if (responseOffset < 0 || handlerOffset < 0) {
    throw new Error("appleAuthBroker response path is missing");
  }
  const responsePath = source.slice(responseOffset, handlerOffset);

  if (!responsePath.includes("publicAppleCredentialBrokerError(error)")) {
    throw new Error(
      "Apple credential policy is disconnected from errorResponse",
    );
  }
  if (!responsePath.includes("publicAppleError.status")) {
    throw new Error("mapped HTTP status is ignored by errorResponse");
  }
});
