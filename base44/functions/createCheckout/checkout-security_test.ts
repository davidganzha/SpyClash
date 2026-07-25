import {
  checkoutIdempotencyKey,
  CURRENT_BASE44_APP_ID,
  resolveExpectedBase44AppID,
} from "./checkout-security.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("checkout app id uses valid environment value and safe current fallback", () => {
  assert(
    resolveExpectedBase44AppID(" 69A0E57FA939F578082F8092 ") ===
      "69a0e57fa939f578082f8092",
    "valid environment app id was ignored",
  );
  assert(
    resolveExpectedBase44AppID("unknown", "") === CURRENT_BASE44_APP_ID,
    "invalid environment app id did not fall back to the linked app",
  );
});

Deno.test("checkout idempotency key is deterministic and account scoped", async () => {
  const common = {
    appID: CURRENT_BASE44_APP_ID,
    userID: "user-1",
    priceID: "price_legacy",
    email: "Agent@Example.com",
    now: new Date("2026-07-14T12:01:00Z"),
  };
  const first = await checkoutIdempotencyKey(common);
  const repeated = await checkoutIdempotencyKey(common);
  const anotherUser = await checkoutIdempotencyKey({
    ...common,
    userID: "user-2",
  });

  assert(first === repeated, "repeated checkout generated a different key");
  assert(first !== anotherUser, "different users shared a checkout key");
  assert(first.length < 255, "Stripe idempotency key is too long");
});

Deno.test("checkout idempotency is stable only inside its five-minute window", async () => {
  const base = {
    appID: CURRENT_BASE44_APP_ID,
    userID: "user-1",
    priceID: "price_legacy",
    email: "agent@example.com",
  };
  const first = await checkoutIdempotencyKey({
    ...base,
    now: new Date("2026-07-14T12:01:00Z"),
  });
  const sameWindow = await checkoutIdempotencyKey({
    ...base,
    now: new Date("2026-07-14T12:04:59Z"),
  });
  const nextWindow = await checkoutIdempotencyKey({
    ...base,
    now: new Date("2026-07-14T12:05:00Z"),
  });
  const changedEmail = await checkoutIdempotencyKey({
    ...base,
    email: "new-agent@example.com",
    now: new Date("2026-07-14T12:01:00Z"),
  });

  assert(first === sameWindow, "same-window retries generated a new key");
  assert(first !== nextWindow, "a later checkout window reused the old key");
  assert(first !== changedEmail, "email was omitted from the fingerprint");
});
