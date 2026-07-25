import { appleCodeExchangeTokenOutcome } from "./apple-code-exchange.ts";

function assertEquals<T>(actual: T, expected: T, message: string) {
  if (actual !== expected) {
    throw new Error(
      `${message}: expected ${String(expected)}, got ${String(actual)}`,
    );
  }
}

Deno.test("only a structured Apple HTTP 400 error proves no token was issued", () => {
  for (
    const error of [
      "invalid_request",
      "invalid_client",
      "invalid_grant",
      "unauthorized_client",
      "unsupported_grant_type",
      "invalid_scope",
    ]
  ) {
    assertEquals(
      appleCodeExchangeTokenOutcome(
        { ok: false, status: 400 },
        { error },
      ),
      "not_issued",
      `documented ${error} ErrorResponse was not classified`,
    );
  }
  for (const status of [408, 425, 429, 500, 502, 503]) {
    assertEquals(
      appleCodeExchangeTokenOutcome(
        { ok: false, status },
        { error: "temporarily_unavailable" },
      ),
      "unknown",
      `HTTP ${status} incorrectly released the issuance boundary`,
    );
  }
});

Deno.test("malformed and token-bearing Apple error responses remain ambiguous", () => {
  for (
    const payload of [
      undefined,
      "not-json",
      {},
      { error: "" },
      { error: "temporarily_unavailable" },
      { error: "not_an_apple_error" },
      { error: "invalid_grant", refresh_token: "possibly-issued" },
    ]
  ) {
    assertEquals(
      appleCodeExchangeTokenOutcome({ ok: false, status: 400 }, payload),
      "unknown",
      "ambiguous HTTP 400 response released the issuance boundary",
    );
  }
  assertEquals(
    appleCodeExchangeTokenOutcome({ ok: true, status: 200 }, {}),
    "unknown",
    "malformed successful response was treated as deterministic failure",
  );
});
