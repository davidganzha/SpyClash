import { clean, NotificationContractError } from "./contracts.ts";
import { safeNotificationErrorDetails } from "./safe-error.ts";

type ErrorShape = {
  status?: unknown;
  statusCode?: unknown;
  response?: {
    status?: unknown;
    headers?: Headers | Record<string, unknown>;
  };
  headers?: Headers | Record<string, unknown>;
};

function headerValue(
  headers: Headers | Record<string, unknown> | undefined,
  name: string,
): string {
  if (!headers) return "";
  if (headers instanceof Headers) return clean(headers.get(name));
  const match = Object.entries(headers).find(([key]) =>
    key.toLowerCase() === name.toLowerCase()
  );
  return clean(match?.[1]);
}

function retryAfter(error: unknown): string {
  const shape = error as ErrorShape | null;
  const supplied = headerValue(shape?.response?.headers, "retry-after") ||
    headerValue(shape?.headers, "retry-after");
  const seconds = Number.parseInt(supplied, 10);
  return Number.isInteger(seconds) && seconds >= 1 && seconds <= 300
    ? String(seconds)
    : "2";
}

function retryableResponse(
  error: unknown,
  status: 429 | 503,
  code: "rate_limited" | "notifications_unavailable",
  message: string,
): Response {
  return Response.json(
    { error: message, code, retryable: true },
    {
      status,
      headers: { "Retry-After": retryAfter(error) },
    },
  );
}

export function notificationErrorResponse(error: unknown): Response {
  if (error instanceof NotificationContractError) {
    const retryableLifecycleConflict = error.status === 409 &&
      ["active_lease", "cas_contention"].includes(error.code);
    const retryable = retryableLifecycleConflict || error.status === 429 ||
      error.status === 503;
    return Response.json(
      {
        error: error.message,
        code: error.code,
        ...(retryable ? { retryable: true } : {}),
      },
      {
        status: error.status,
        ...(retryable
          ? {
            headers: {
              "Retry-After": retryableLifecycleConflict
                ? "1"
                : retryAfter(error),
            },
          }
          : {}),
      },
    );
  }

  const details = safeNotificationErrorDetails(error);
  console.error("notificationAction failed", details.message, details.status);
  const status = details.status;
  if (status === 429) {
    return retryableResponse(
      error,
      429,
      "rate_limited",
      "Too many notification requests. Retry shortly.",
    );
  }
  if (status === 502 || status === 503 || status === 504) {
    return retryableResponse(
      error,
      503,
      "notifications_unavailable",
      "Notifications are temporarily unavailable.",
    );
  }
  return Response.json(
    {
      error: "Notifications are temporarily unavailable.",
      code: "notifications_unavailable",
    },
    { status: 500 },
  );
}
