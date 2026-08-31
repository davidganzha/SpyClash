import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import * as autoRegisterContext from "../functions/autoRegisterUser/base44-context.ts";
import * as appStoreContext from "../functions/app-store-entitlement/base44-context.ts";
import * as checkSubscriptionContext from "../functions/checkSubscription/base44-context.ts";
import * as communityContext from "../functions/communityAction/base44-context.ts";
import * as createCheckoutContext from "../functions/createCheckout/base44-context.ts";
import * as deleteAccountContext from "../functions/deleteAccount/base44-context.ts";
import * as generateWordPackContext from "../functions/generateWordPack/base44-context.ts";
import * as notificationContext from "../functions/notificationAction/base44-context.ts";
import * as pushContext from "../functions/pushNotificationAction/base44-context.ts";
import * as stripeWebhookContext from "../functions/stripe-entitlement-webhook/base44-context.ts";
import * as wordPackContext from "../functions/wordPackAction/base44-context.ts";

const APP_ID = "69a0e57fa939f578082f8091";
const API_URL = "https://base44.app";

const routingContexts = [
  checkSubscriptionContext,
  communityContext,
  createCheckoutContext,
  generateWordPackContext,
  notificationContext,
  wordPackContext,
];
const canonicalOnlyContexts = [
  appStoreContext,
  deleteAccountContext,
  pushContext,
  stripeWebhookContext,
];

Deno.test("service-role functions reject foreign app context", () => {
  for (const context of [autoRegisterContext, ...routingContexts]) {
    const trusted = new Request("https://functions.test/action", {
      method: "POST",
      headers: {
        "Base44-App-Id": APP_ID,
        "Base44-Service-Authorization": "Bearer service-token",
      },
    });
    const foreign = new Request("https://functions.test/action", {
      method: "POST",
      headers: {
        "Base44-App-Id": "foreign-app",
        "Base44-Service-Authorization": "Bearer service-token",
      },
    });

    assertEquals(context.hasTrustedBase44Context(trusted), true);
    assertEquals(context.hasTrustedBase44Context(foreign), false);
  }
});

Deno.test("service-role SDK clients always use canonical Base44 routing", () => {
  for (const context of [...routingContexts, ...canonicalOnlyContexts]) {
    const request = new Request("https://functions.test/action", {
      method: "POST",
      headers: {
        "Base44-App-Id": APP_ID,
        "Base44-Api-Url": "https://attacker.invalid",
        "Base44-Service-Authorization": "Bearer service-token",
      },
    });
    const canonical = context.canonicalBase44Request(request);
    assertEquals(canonical.headers.get("Base44-App-Id"), APP_ID);
    assertEquals(canonical.headers.get("Base44-Api-Url"), API_URL);
    assertEquals(
      canonical.headers.get("Base44-Service-Authorization"),
      "Bearer service-token",
    );
  }
});

Deno.test("body-token identity clients cannot be redirected by request headers", () => {
  for (
    const context of [
      autoRegisterContext,
      communityContext,
      wordPackContext,
    ]
  ) {
    assertEquals(context.canonicalIdentityClientConfig("user-token"), {
      appId: APP_ID,
      serverUrl: API_URL,
      token: "user-token",
    });
  }
});

Deno.test("mutating Base44 entrypoints require POST before reading the body", async () => {
  const entrypoints = [
    "../functions/autoRegisterUser/main.ts",
    "../functions/checkSubscription/main.ts",
    "../functions/communityAction/main.ts",
    "../functions/createCheckout/main.ts",
    "../functions/gameRoomAction/main.ts",
    "../functions/generateWordPack/main.ts",
    "../functions/wordPackAction/main.ts",
  ];

  for (const entrypoint of entrypoints) {
    const source = await Deno.readTextFile(
      new URL(entrypoint, import.meta.url),
    );
    const handler = source.slice(source.indexOf("Deno.serve"));
    assertStringIncludes(handler, 'req.method !== "POST"', entrypoint);
    const bodyReadIndex = handler.indexOf("req.json()");
    assertEquals(
      bodyReadIndex < 0 ||
        handler.indexOf('req.method !== "POST"') < bodyReadIndex,
      true,
      entrypoint,
    );
  }
});
