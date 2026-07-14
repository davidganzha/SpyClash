import { googleTransactionChannelFromClaim } from "./confirmation.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("Google transaction channel accepts only signed known values", () => {
  assert(
    googleTransactionChannelFromClaim("primary") === "primary",
    "primary channel rejected",
  );
  assert(
    googleTransactionChannelFromClaim("fallback") === "fallback",
    "fallback channel rejected",
  );
  for (
    const invalid of [
      null,
      undefined,
      "",
      "PRIMARY",
      "both",
      1,
      {},
    ]
  ) {
    assert(
      googleTransactionChannelFromClaim(invalid) === null,
      `invalid channel accepted: ${String(invalid)}`,
    );
  }
});
