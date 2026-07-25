export type AppleCodeExchangeTokenOutcome = "not_issued" | "unknown";

const APPLE_TOKEN_ERROR_CODES = new Set([
  "invalid_request",
  "invalid_client",
  "invalid_grant",
  "unauthorized_client",
  "unsupported_grant_type",
  "invalid_scope",
]);

export function appleCodeExchangeTokenOutcome(
  response: Pick<Response, "ok" | "status">,
  payload: unknown,
): AppleCodeExchangeTokenOutcome {
  if (response.ok || response.status !== 400) return "unknown";
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return "unknown";
  }
  const record = payload as Record<string, unknown>;
  const error = typeof record.error === "string" ? record.error.trim() : "";
  const refreshToken = typeof record.refresh_token === "string"
    ? record.refresh_token.trim()
    : "";

  // Apple documents a structured HTTP 400 ErrorResponse as the deterministic
  // token-endpoint failure. Edge/transport 408, 429, 5xx and malformed bodies
  // do not prove that no external bearer token was created, so they retain the
  // durable issuance boundary for service-role reconciliation.
  return APPLE_TOKEN_ERROR_CODES.has(error) && !refreshToken
    ? "not_issued"
    : "unknown";
}
