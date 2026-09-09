import {
  type CheckTestNotificationResponse,
  Environment,
  type SendTestNotificationResponse,
} from "npm:@apple/app-store-server-library@3.1.0";
import { inspectAppleTestNotification } from "./apple-verification-error.ts";

export class AppleNotificationDiagnosticError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
    this.name = "AppleNotificationDiagnosticError";
  }
}

function validTestToken(value: unknown): value is string {
  // The API documents an opaque string. Permit one URL-safe path component,
  // without assuming a UUID version or accepting a user-supplied API path.
  return typeof value === "string" && /^[A-Za-z0-9_-]{1,512}$/.test(value);
}

export async function runAppleNotificationDiagnostic(input: {
  user: { id?: string; role?: string } | null;
  body: Record<string, unknown>;
  clientFor: (environment: Environment) => {
    requestTestNotification: () => Promise<SendTestNotificationResponse>;
    getTestNotificationStatus: (
      token: string,
    ) => Promise<CheckTestNotificationResponse>;
  };
  verifyTestPayload: (
    environment: Environment,
    signedPayload: string,
  ) => Promise<{ notificationType?: string }>;
}) {
  if (!input.user?.id || input.user.role !== "admin") {
    throw new AppleNotificationDiagnosticError(
      "Administrator access required.",
      403,
    );
  }
  const environment = input.body.environment;
  if (
    environment !== Environment.SANDBOX &&
    environment !== Environment.PRODUCTION
  ) {
    throw new AppleNotificationDiagnosticError(
      "Choose Sandbox or Production explicitly.",
      422,
    );
  }
  const action = input.body.action;
  if (
    action !== "request_test_notification" &&
    action !== "get_test_notification_status"
  ) {
    throw new AppleNotificationDiagnosticError(
      "Unsupported notification diagnostic action.",
      400,
    );
  }
  const token = input.body.test_notification_token;
  if (action === "get_test_notification_status" && !validTestToken(token)) {
    throw new AppleNotificationDiagnosticError(
      "Invalid Apple test notification token.",
      422,
    );
  }
  const client = input.clientFor(environment);
  try {
    if (action === "request_test_notification") {
      const response = await client.requestTestNotification();
      if (!validTestToken(response.testNotificationToken)) {
        throw new AppleNotificationDiagnosticError(
          "Apple did not return a valid test notification token.",
          503,
        );
      }
      return {
        success: true,
        environment,
        testNotificationToken: response.testNotificationToken,
      };
    }
    const response = await client.getTestNotificationStatus(token as string);
    const verification = response.signedPayload
      ? await inspectAppleTestNotification({
        signedPayload: response.signedPayload,
        verify: (signedPayload) =>
          input.verifyTestPayload(environment, signedPayload),
      })
      : { valid: false, status: "MISSING_TEST_PAYLOAD" };
    return {
      success: true,
      environment,
      testNotificationToken: token as string,
      verification,
      sendAttempts: (response.sendAttempts || []).slice(0, 6).map((
        attempt,
      ) => ({
        attemptDate: Number.isFinite(attempt.attemptDate)
          ? attempt.attemptDate
          : null,
        sendAttemptResult: typeof attempt.sendAttemptResult === "string"
          ? attempt.sendAttemptResult.slice(0, 128)
          : "UNKNOWN",
      })),
    };
  } catch (error) {
    if (error instanceof AppleNotificationDiagnosticError) throw error;
    const httpStatus = Number(
      (error as { httpStatusCode?: unknown })?.httpStatusCode,
    );
    const suffix =
      Number.isInteger(httpStatus) && httpStatus >= 400 && httpStatus <= 599
        ? ` (provider HTTP ${httpStatus})`
        : "";
    // Never return Apple's raw response, a signed payload or credential detail.
    throw new AppleNotificationDiagnosticError(
      `Apple notification diagnostic is unavailable${suffix}.`,
      503,
    );
  }
}
