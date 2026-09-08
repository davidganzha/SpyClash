import { runAppleNotificationDiagnostic } from "./apple-notification-diagnostic.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

async function rejects(work: () => Promise<unknown>, expected: string) {
  try {
    await work();
  } catch (error) {
    assert(
      String(error).includes(expected),
      `Unexpected error: ${String(error)}`,
    );
    return;
  }
  throw new Error(`Expected rejection containing ${expected}`);
}

function fixture() {
  const calls: string[] = [];
  return {
    calls,
    input: {
      user: { id: "administrator-1", role: "admin" } as {
        id?: string;
        role?: string;
      } | null,
      body: {
        action: "request_test_notification",
        environment: "Sandbox",
      } as Record<string, unknown>,
      clientFor: (environment: string) => {
        calls.push(`client:${environment}`);
        return {
          requestTestNotification: async () => {
            calls.push("request");
            return { testNotificationToken: "opaque-test-token-123" };
          },
          getTestNotificationStatus: async (token: string) => {
            calls.push(`status:${token}`);
            return {
              signedPayload: "private-signed-payload-must-never-be-returned",
              sendAttempts: [{
                attemptDate: 123_000,
                sendAttemptResult: "SUCCESS",
              }],
            };
          },
        };
      },
    },
  };
}

Deno.test("only the authenticated administrator can ask Apple to send a TEST", async () => {
  for (
    const user of [null, { id: "user-1", role: "user" }, { id: "user-1" }, {
      role: "admin",
    }]
  ) {
    const { input, calls } = fixture();
    input.user = user;
    input.body.role = "admin";
    await rejects(
      () => runAppleNotificationDiagnostic(input),
      "Administrator access",
    );
    assert(calls.length === 0, "unauthorized input reached Apple");
  }
});

Deno.test("diagnostic requires explicit supported environment and a fixed action", async () => {
  for (
    const environment of [
      undefined,
      "",
      "sandbox",
      "Xcode",
      "https://example.com",
    ]
  ) {
    const { input, calls } = fixture();
    input.body.environment = environment;
    await rejects(
      () => runAppleNotificationDiagnostic(input),
      "Sandbox or Production",
    );
    assert(calls.length === 0, "invalid environment constructed a client");
  }
  const { input, calls } = fixture();
  input.body.action = "refund";
  await rejects(() => runAppleNotificationDiagnostic(input), "Unsupported");
  assert(calls.length === 0, "diagnostic became an arbitrary Apple API proxy");
});

Deno.test("administrator can request Sandbox and Production TEST without a purchase grant", async () => {
  for (const environment of ["Sandbox", "Production"]) {
    const { input, calls } = fixture();
    input.body.environment = environment;
    const result = await runAppleNotificationDiagnostic(input);
    assert(
      calls.join(",") === `client:${environment},request`,
      "incorrect operation",
    );
    assert(
      result.testNotificationToken === "opaque-test-token-123",
      "missing test token",
    );
    assert(
      !("entitlement" in result),
      "test response implied membership access",
    );
  }
});

Deno.test("test status rejects missing, excessive and path-injection tokens before Apple", async () => {
  for (
    const token of [
      undefined,
      "",
      "..",
      "../../transactions/123",
      "a?b",
      "a#b",
      "x".repeat(513),
      123,
    ]
  ) {
    const { input, calls } = fixture();
    input.body = {
      action: "get_test_notification_status",
      environment: "Sandbox",
      test_notification_token: token,
    };
    await rejects(
      () => runAppleNotificationDiagnostic(input),
      "Invalid Apple test",
    );
    assert(calls.length === 0, "invalid token reached API path");
  }
});

Deno.test("test status exposes delivery attempts but never the signed payload", async () => {
  const { input, calls } = fixture();
  input.body = {
    action: "get_test_notification_status",
    environment: "Sandbox",
    test_notification_token: "opaque-test-token-123",
  };
  const result = await runAppleNotificationDiagnostic(input);
  assert(
    calls.join(",") === "client:Sandbox,status:opaque-test-token-123",
    "wrong status request",
  );
  assert(
    result.sendAttempts?.[0]?.sendAttemptResult === "SUCCESS",
    "missing delivery evidence",
  );
  assert(
    !JSON.stringify(result).includes("private-signed"),
    "signed payload leaked",
  );
});

Deno.test("provider failure returns only a safe diagnostic, never a raw response", async () => {
  const { input } = fixture();
  const clientFor = input.clientFor;
  input.clientFor = (environment) => ({
    ...clientFor(environment),
    requestTestNotification: () =>
      Promise.reject({
        httpStatusCode: 401,
        message: "private-provider-response",
      }),
  });
  try {
    await runAppleNotificationDiagnostic(input);
    throw new Error("provider failure was ignored");
  } catch (error) {
    assert(
      String(error).includes("provider HTTP 401"),
      "HTTP diagnostic was lost",
    );
    assert(!String(error).includes("private-provider"), "raw response leaked");
  }
});
