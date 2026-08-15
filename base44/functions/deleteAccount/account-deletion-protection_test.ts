import {
  ADMIN_ACCOUNT_DELETION_CODE,
  protectedAccountDeletionResponse,
  UNVERIFIED_ACCOUNT_ROLE_DELETION_CODE,
} from "./account-deletion-protection.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

Deno.test("administrator deletion is blocked without a retry instruction", async () => {
  for (const role of ["admin", " ADMIN ", "Admin"]) {
    const response = protectedAccountDeletionResponse({ role });
    assert(response, `administrator role ${JSON.stringify(role)} was allowed`);
    const body = await response.clone().json();

    assert(response.status === 409, "administrator response status changed");
    assert(
      response.headers.get("cache-control") === "no-store",
      "administrator response became cacheable",
    );
    assert(body.code === ADMIN_ACCOUNT_DELETION_CODE, "error code changed");
    assert(body.retryable === false, "administrator response became retryable");
  }
});

Deno.test("only a verified ordinary user continues to account deletion", () => {
  for (const user of [{ role: "user" }, { role: " USER " }, { role: "User" }]) {
    assert(
      protectedAccountDeletionResponse(user) === undefined,
      "ordinary user was blocked",
    );
  }
});

Deno.test("missing and unknown roles fail closed before deletion", async () => {
  for (const user of [{}, { role: "owner" }, undefined, null]) {
    const response = protectedAccountDeletionResponse(user);
    assert(response, "unverified account role reached deletion");
    const body = await response.clone().json();

    assert(response.status === 503, "unverified role status changed");
    assert(
      response.headers.get("cache-control") === "no-store",
      "unverified role response became cacheable",
    );
    assert(response.headers.get("retry-after") === "60", "retry delay changed");
    assert(
      body.code === UNVERIFIED_ACCOUNT_ROLE_DELETION_CODE,
      "unverified role code changed",
    );
    assert(body.retryable === true, "unverified role became terminal");
  }
});

Deno.test("administrator guard remains before every deletion side effect", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const handlerOffset = source.indexOf("Deno.serve");
  assert(handlerOffset >= 0, "deleteAccount request handler is missing");
  const handler = source.slice(handlerOffset);
  const guardOffset = handler.indexOf("protectedAccountDeletionResponse(user)");
  assert(guardOffset >= 0, "administrator guard is missing from the handler");

  for (
    const operation of [
      "entitlementRetentionPatch(user.id)",
      "acquireBillingDeletionMarker(",
      "acquireAppleAccountDeletionLeases(",
      "revokeAppleSignInCredentials(",
      "deleteUserRecord(",
    ]
  ) {
    const operationOffset = handler.indexOf(operation);
    assert(operationOffset >= 0, `${operation} is missing from the handler`);
    assert(
      guardOffset < operationOffset,
      `administrator guard runs after ${operation}`,
    );
  }
});
