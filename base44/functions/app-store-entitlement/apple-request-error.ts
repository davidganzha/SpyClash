type AppleRequestErrorCode = "apple_account_binding_busy";

export class RequestError extends Error {
  status: number;
  readonly code?: AppleRequestErrorCode;

  constructor(message: string, status = 400, code?: AppleRequestErrorCode) {
    super(message);
    this.name = "RequestError";
    this.status = status;
    this.code = code;
  }
}

export function appleRequestErrorResponse(
  error: unknown,
  publicMessage: string,
  status: number,
): Response {
  // Only the recognized active-lease contention permits a client retry.
  // Other 503s, including lost leases and verification/configuration failures,
  // retain the existing public error body without internal error details.
  const bindingBusy = status === 503 && error instanceof RequestError &&
    error.status === 503 && error.code === "apple_account_binding_busy";
  return Response.json(
    bindingBusy
      ? {
        error: publicMessage,
        code: "apple_account_binding_busy",
        retryable: true,
      }
      : { error: publicMessage },
    { status },
  );
}
