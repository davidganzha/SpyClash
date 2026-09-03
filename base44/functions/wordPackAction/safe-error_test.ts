import { assertEquals } from "jsr:@std/assert@1";
import { safeWordPackErrorDetails } from "./safe-error.ts";

Deno.test("cyclic word-pack SDK errors become structured-log-safe scalars", () => {
  const sdkResponse: Record<string, unknown> = { status: 503 };
  const sdkError: Record<string, unknown> = {
    message: "upstream request failed",
    code: "backend_unavailable",
    response: sdkResponse,
  };
  sdkError.self = sdkError;
  sdkResponse.error = sdkError;

  const details = safeWordPackErrorDetails(sdkError);
  assertEquals(details, {
    message: "upstream request failed",
    status: 503,
    code: "backend_unavailable",
  });
  assertEquals(
    JSON.stringify(details),
    '{"message":"upstream request failed","status":503,"code":"backend_unavailable"}',
  );
});

Deno.test("cyclic word-pack message fields use bounded scalar fallbacks", () => {
  const sdkError: Record<string, unknown> = { statusCode: "409" };
  sdkError.message = sdkError;
  sdkError.code = sdkError;
  sdkError.request = sdkError;

  assertEquals(safeWordPackErrorDetails(sdkError), {
    message: "Word pack request failed",
    status: 409,
    code: "",
  });
});
