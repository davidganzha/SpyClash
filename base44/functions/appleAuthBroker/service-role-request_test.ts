import { createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { requestForBase44ServiceRole } from "./service-role-request.ts";

Deno.test("service-role request removes OIDC Basic auth and preserves Base44 context", () => {
  const request = new Request(
    "https://spyclash.com/functions/appleAuthBroker?action=token",
    {
      method: "POST",
      headers: {
        Authorization: "Basic dGVzdDpzZWNyZXQ=",
        "Base44-App-Id": "app-id",
        "Base44-Service-Authorization": "Bearer service-token",
        "Base44-Api-Url": "https://base44.app",
        "Base44-Functions-Version": "version-id",
        "Base44-State": "opaque-state",
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: "grant_type=authorization_code",
    },
  );

  const sanitized = requestForBase44ServiceRole(request);

  assertEquals(sanitized.headers.get("Authorization"), null);
  assertEquals(sanitized.headers.get("Base44-App-Id"), "app-id");
  assertEquals(
    sanitized.headers.get("Base44-Service-Authorization"),
    "Bearer service-token",
  );
  assertEquals(sanitized.headers.get("Base44-Api-Url"), "https://base44.app");
  assertEquals(sanitized.headers.get("Base44-Functions-Version"), "version-id");
  assertEquals(sanitized.headers.get("Base44-State"), "opaque-state");
});

Deno.test("service-role request preserves app-user Bearer auth", () => {
  const request = new Request(
    "https://spyclash.com/functions/appleAuthBroker",
    {
      headers: {
        Authorization: "Bearer app-user-token",
        "Base44-App-Id": "app-id",
        "Base44-Service-Authorization": "Bearer service-token",
      },
    },
  );

  const sanitized = requestForBase44ServiceRole(request);

  assertEquals(sanitized.headers.get("Authorization"), "Bearer app-user-token");
  assertEquals(
    sanitized.headers.get("Base44-Service-Authorization"),
    "Bearer service-token",
  );
});

Deno.test("sanitized OIDC token request initializes the Base44 service-role SDK", () => {
  const request = new Request(
    "https://spyclash.com/functions/appleAuthBroker?action=token",
    {
      headers: {
        Authorization: "Basic dGVzdDpzZWNyZXQ=",
        "Base44-App-Id": "app-id",
        "Base44-Service-Authorization": "Bearer service-token",
        "Base44-Api-Url": "https://base44.app",
      },
    },
  );

  assertThrows(
    () => createClientFromRequest(request),
    Error,
    'Expected "Bearer <token>"',
  );

  const client = createClientFromRequest(
    requestForBase44ServiceRole(request),
  );
  // Accessing this getter is the exact point that used to fail in
  // appleCredentialStores before any entity request could be made.
  void client.asServiceRole.entities.AppleSignInCredential;
  client.asServiceRole.cleanup();
  client.cleanup();
});
