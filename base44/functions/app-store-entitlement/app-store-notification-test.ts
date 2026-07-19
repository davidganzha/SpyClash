export type AppStoreServerEnvironmentName = "Sandbox" | "Production";

export type AppStoreNotificationTestUser = {
  role?: unknown;
};

export type AppStoreNotificationTestClient = {
  requestTestNotification(): Promise<{
    testNotificationToken?: string;
  }>;
  getTestNotificationStatus(testNotificationToken: string): Promise<{
    // Intentionally accepted from Apple but never returned or logged.
    signedPayload?: string;
    sendAttempts?: Array<{
      attemptDate?: number;
      sendAttemptResult?: string;
    }>;
  }>;
};

export type AppStoreNotificationTestClientSource =
  | AppStoreNotificationTestClient
  | (() => AppStoreNotificationTestClient);

export type AppStoreNotificationTestAuditEvent = {
  event: "app_store_server_notification_test";
  action: "request_test_notification" | "get_test_notification_status";
  outcome: "success" | "error";
  environment: AppStoreServerEnvironmentName;
  testNotificationToken?: string;
  sendAttemptResult: string | null;
  sendAttemptCount: number;
  errorCode?: string;
};

export type AppStoreNotificationTestAudit = (
  event: AppStoreNotificationTestAuditEvent,
) => void;

export class AppStoreNotificationTestError extends Error {
  status: number;
  code: string;

  constructor(code: string, message: string, status: number) {
    super(message);
    this.name = "AppStoreNotificationTestError";
    this.status = status;
    this.code = code;
  }
}

export function isAppStoreNotificationTestAdmin(
  user: AppStoreNotificationTestUser | null | undefined,
): boolean {
  return String(user?.role || "").trim().toLowerCase() === "admin";
}

export function parseAppStoreServerEnvironment(
  value: unknown,
): AppStoreServerEnvironmentName {
  const normalized = String(value || "").trim().toLowerCase();
  if (normalized === "sandbox") return "Sandbox";
  if (normalized === "production") return "Production";
  throw new AppStoreNotificationTestError(
    "INVALID_ENVIRONMENT",
    "environment must be Sandbox or Production.",
    422,
  );
}

export function canonicalTestNotificationToken(value: unknown): string {
  if (typeof value !== "string") {
    throw new AppStoreNotificationTestError(
      "INVALID_TEST_NOTIFICATION_TOKEN",
      "A valid test_notification_token is required.",
      422,
    );
  }
  const token = value;
  if (
    token.length === 0 || token.length > 256 ||
    !/^[A-Za-z0-9._~-]+$/.test(token)
  ) {
    throw new AppStoreNotificationTestError(
      "INVALID_TEST_NOTIFICATION_TOKEN",
      "A valid test_notification_token is required.",
      422,
    );
  }
  return token;
}

function safeSendAttemptResult(value: unknown): string {
  const result = String(value || "").trim().toUpperCase();
  return /^[A-Z_]{1,64}$/.test(result) ? result : "UNKNOWN";
}

function safeAudit(
  audit: AppStoreNotificationTestAudit,
  event: AppStoreNotificationTestAuditEvent,
) {
  try {
    audit(event);
  } catch {
    // Observability must never change the result of an Apple API operation.
  }
}

function actionFailure(
  error: unknown,
  fallbackCode: string,
): AppStoreNotificationTestError {
  if (error instanceof AppStoreNotificationTestError) return error;

  const apiError = error && typeof error === "object" && "apiError" in error
    ? Number((error as { apiError?: unknown }).apiError)
    : null;
  switch (apiError) {
    case 4_040_007:
      return new AppStoreNotificationTestError(
        "SERVER_NOTIFICATION_URL_NOT_FOUND",
        "No App Store Server Notifications URL is configured for this environment.",
        409,
      );
    case 4_040_008:
      return new AppStoreNotificationTestError(
        "TEST_NOTIFICATION_NOT_FOUND",
        "The App Store notification test was not found in this environment.",
        404,
      );
    case 4_000_020:
      return new AppStoreNotificationTestError(
        "INVALID_TEST_NOTIFICATION_TOKEN",
        "Apple rejected the test_notification_token.",
        422,
      );
  }

  return new AppStoreNotificationTestError(
    fallbackCode,
    "App Store Server API notification testing is temporarily unavailable.",
    503,
  );
}

function resolveClient(
  source: AppStoreNotificationTestClientSource,
): AppStoreNotificationTestClient {
  return typeof source === "function" ? source() : source;
}

export async function requestAppStoreTestNotification(input: {
  client: AppStoreNotificationTestClientSource;
  environment: AppStoreServerEnvironmentName;
  audit: AppStoreNotificationTestAudit;
}) {
  try {
    const response = await resolveClient(input.client)
      .requestTestNotification();
    let testNotificationToken: string;
    try {
      testNotificationToken = canonicalTestNotificationToken(
        response.testNotificationToken,
      );
    } catch {
      throw new AppStoreNotificationTestError(
        "INVALID_APPLE_TEST_NOTIFICATION_RESPONSE",
        "App Store Server API notification testing is temporarily unavailable.",
        503,
      );
    }
    safeAudit(input.audit, {
      event: "app_store_server_notification_test",
      action: "request_test_notification",
      outcome: "success",
      environment: input.environment,
      testNotificationToken,
      sendAttemptResult: null,
      sendAttemptCount: 0,
    });
    return {
      success: true,
      environment: input.environment,
      test_notification_token: testNotificationToken,
    };
  } catch (error) {
    const failure = actionFailure(
      error,
      "REQUEST_TEST_NOTIFICATION_FAILED",
    );
    safeAudit(input.audit, {
      event: "app_store_server_notification_test",
      action: "request_test_notification",
      outcome: "error",
      environment: input.environment,
      sendAttemptResult: null,
      sendAttemptCount: 0,
      errorCode: failure.code,
    });
    throw failure;
  }
}

export async function getAppStoreTestNotificationStatus(input: {
  client: AppStoreNotificationTestClientSource;
  environment: AppStoreServerEnvironmentName;
  testNotificationToken: unknown;
  audit: AppStoreNotificationTestAudit;
}) {
  let testNotificationToken: string | undefined;
  try {
    testNotificationToken = canonicalTestNotificationToken(
      input.testNotificationToken,
    );
    const response = await resolveClient(input.client)
      .getTestNotificationStatus(
        testNotificationToken,
      );
    const sendAttempts = (response.sendAttempts || []).map((attempt) => ({
      attempt_date: Number.isSafeInteger(attempt.attemptDate)
        ? attempt.attemptDate
        : null,
      send_attempt_result: safeSendAttemptResult(attempt.sendAttemptResult),
    }));
    const latestAttempt = sendAttempts.reduce<
      (typeof sendAttempts)[number] | null
    >((latest, candidate) => {
      if (!latest) return candidate;
      return Number(candidate.attempt_date || 0) >=
          Number(latest.attempt_date || 0)
        ? candidate
        : latest;
    }, null);
    const delivered = sendAttempts.some((attempt) =>
      attempt.send_attempt_result === "SUCCESS"
    );

    safeAudit(input.audit, {
      event: "app_store_server_notification_test",
      action: "get_test_notification_status",
      outcome: "success",
      environment: input.environment,
      testNotificationToken,
      sendAttemptResult: latestAttempt?.send_attempt_result || null,
      sendAttemptCount: sendAttempts.length,
    });
    return {
      success: true,
      environment: input.environment,
      test_notification_token: testNotificationToken,
      delivered,
      pending: sendAttempts.length === 0,
      send_attempts: sendAttempts,
    };
  } catch (error) {
    const failure = actionFailure(
      error,
      "GET_TEST_NOTIFICATION_STATUS_FAILED",
    );
    safeAudit(input.audit, {
      event: "app_store_server_notification_test",
      action: "get_test_notification_status",
      outcome: "error",
      environment: input.environment,
      ...(testNotificationToken ? { testNotificationToken } : {}),
      sendAttemptResult: null,
      sendAttemptCount: 0,
      errorCode: failure.code,
    });
    throw failure;
  }
}
