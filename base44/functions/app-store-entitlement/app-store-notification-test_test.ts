import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  type AppStoreNotificationTestAuditEvent,
  AppStoreNotificationTestError,
  canonicalTestNotificationToken,
  getAppStoreTestNotificationStatus,
  isAppStoreNotificationTestAdmin,
  parseAppStoreServerEnvironment,
  requestAppStoreTestNotification,
} from "./app-store-notification-test.ts";

const TOKEN = "8cd2974c-f905-492a-bf9a-b2f47c791d19";

Deno.test("App Store notification test actions are admin-only", () => {
  assertEquals(isAppStoreNotificationTestAdmin(null), false);
  assertEquals(isAppStoreNotificationTestAdmin({ role: "user" }), false);
  assertEquals(isAppStoreNotificationTestAdmin({ role: " ADMIN " }), true);
});

Deno.test("App Store notification test input accepts only server API environments and safe tokens", () => {
  assertEquals(parseAppStoreServerEnvironment("sandbox"), "Sandbox");
  assertEquals(parseAppStoreServerEnvironment("Production"), "Production");
  assertEquals(
    canonicalTestNotificationToken(TOKEN.toUpperCase()),
    TOKEN.toUpperCase(),
  );

  let environmentError: unknown;
  try {
    parseAppStoreServerEnvironment("Xcode");
  } catch (error) {
    environmentError = error;
  }
  assert(environmentError instanceof AppStoreNotificationTestError);
  assertEquals(environmentError.status, 422);
});

Deno.test("test notification tokens stay opaque and reject unsafe input", () => {
  const opaqueToken = "FutureToken_ABC.123-xyz";
  assertEquals(canonicalTestNotificationToken(opaqueToken), opaqueToken);

  for (
    const invalid of [
      "",
      " token",
      "token\n",
      "token/path",
      "token?query",
      "token#fragment",
      "token%2fpath",
      "token\\path",
      "token\u2028line",
      "token\u2029line",
      "x".repeat(257),
      123,
    ]
  ) {
    let tokenError: unknown;
    try {
      canonicalTestNotificationToken(invalid);
    } catch (error) {
      tokenError = error;
    }
    assert(tokenError instanceof AppStoreNotificationTestError);
    assertEquals(tokenError.status, 422);
  }
});

Deno.test("request_test_notification returns and audits only the Apple test token", async () => {
  const audit: AppStoreNotificationTestAuditEvent[] = [];
  const response = await requestAppStoreTestNotification({
    client: {
      requestTestNotification: async () => ({
        testNotificationToken: TOKEN,
      }),
      getTestNotificationStatus: async () => ({}),
    },
    environment: "Sandbox",
    audit: (event) => audit.push(event),
  });

  assertEquals(response, {
    success: true,
    environment: "Sandbox",
    test_notification_token: TOKEN,
  });
  assertEquals(audit, [{
    event: "app_store_server_notification_test",
    action: "request_test_notification",
    outcome: "success",
    environment: "Sandbox",
    testNotificationToken: TOKEN,
    sendAttemptResult: null,
    sendAttemptCount: 0,
  }]);
});

Deno.test("get_test_notification_status strips signedPayload and audits delivery result", async () => {
  const audit: AppStoreNotificationTestAuditEvent[] = [];
  const response = await getAppStoreTestNotificationStatus({
    client: {
      requestTestNotification: async () => ({}),
      getTestNotificationStatus: async (token) => {
        assertEquals(token, TOKEN);
        return {
          signedPayload: "header.secret-jws.signature",
          sendAttempts: [{
            attemptDate: 1_721_000_000_000,
            sendAttemptResult: "SUCCESS",
          }],
        };
      },
    },
    environment: "Production",
    testNotificationToken: TOKEN,
    audit: (event) => audit.push(event),
  });

  assertEquals(response, {
    success: true,
    environment: "Production",
    test_notification_token: TOKEN,
    delivered: true,
    pending: false,
    send_attempts: [{
      attempt_date: 1_721_000_000_000,
      send_attempt_result: "SUCCESS",
    }],
  });
  assert(!JSON.stringify(response).includes("secret-jws"));
  assert(!JSON.stringify(audit).includes("secret-jws"));
  assertEquals(audit[0].sendAttemptResult, "SUCCESS");
  assertEquals(audit[0].sendAttemptCount, 1);
});

Deno.test("Apple API failures emit anonymous error audit without raw error data", async () => {
  const audit: AppStoreNotificationTestAuditEvent[] = [];
  await assertRejects(
    () =>
      getAppStoreTestNotificationStatus({
        client: {
          requestTestNotification: async () => ({}),
          getTestNotificationStatus: () =>
            Promise.reject(new Error("private-key-and-jws-must-not-leak")),
        },
        environment: "Sandbox",
        testNotificationToken: TOKEN,
        audit: (event) => audit.push(event),
      }),
    AppStoreNotificationTestError,
    "temporarily unavailable",
  );

  assertEquals(audit, [{
    event: "app_store_server_notification_test",
    action: "get_test_notification_status",
    outcome: "error",
    environment: "Sandbox",
    testNotificationToken: TOKEN,
    sendAttemptResult: null,
    sendAttemptCount: 0,
    errorCode: "GET_TEST_NOTIFICATION_STATUS_FAILED",
  }]);
  assert(!JSON.stringify(audit).includes("private-key"));
});

Deno.test("credential client failures are audited without exposing credential errors", async () => {
  const audit: AppStoreNotificationTestAuditEvent[] = [];
  await assertRejects(
    () =>
      requestAppStoreTestNotification({
        client: () => {
          throw new Error("issuer-id-and-private-key-must-not-leak");
        },
        environment: "Production",
        audit: (event) => audit.push(event),
      }),
    AppStoreNotificationTestError,
    "temporarily unavailable",
  );

  assertEquals(audit, [{
    event: "app_store_server_notification_test",
    action: "request_test_notification",
    outcome: "error",
    environment: "Production",
    sendAttemptResult: null,
    sendAttemptCount: 0,
    errorCode: "REQUEST_TEST_NOTIFICATION_FAILED",
  }]);
  assert(!JSON.stringify(audit).includes("private-key"));
  assert(!JSON.stringify(audit).includes("issuer-id"));
});

Deno.test("known Apple notification test errors remain actionable without raw messages", async () => {
  const cases = [
    {
      apiError: 4_040_007,
      code: "SERVER_NOTIFICATION_URL_NOT_FOUND",
      status: 409,
    },
    {
      apiError: 4_040_008,
      code: "TEST_NOTIFICATION_NOT_FOUND",
      status: 404,
    },
    {
      apiError: 4_000_020,
      code: "INVALID_TEST_NOTIFICATION_TOKEN",
      status: 422,
    },
  ];

  for (const testCase of cases) {
    const audit: AppStoreNotificationTestAuditEvent[] = [];
    let caught: unknown;
    try {
      await getAppStoreTestNotificationStatus({
        client: {
          requestTestNotification: async () => ({}),
          getTestNotificationStatus: () =>
            Promise.reject({
              httpStatusCode: 404,
              apiError: testCase.apiError,
              errorMessage: "private-apple-diagnostic-must-not-leak",
            }),
        },
        environment: "Sandbox",
        testNotificationToken: TOKEN,
        audit: (event) => audit.push(event),
      });
    } catch (error) {
      caught = error;
    }

    assert(caught instanceof AppStoreNotificationTestError);
    assertEquals(caught.code, testCase.code);
    assertEquals(caught.status, testCase.status);
    assertEquals(audit[0].errorCode, testCase.code);
    assert(!JSON.stringify(caught).includes("private-apple"));
    assert(!JSON.stringify(audit).includes("private-apple"));
  }
});
