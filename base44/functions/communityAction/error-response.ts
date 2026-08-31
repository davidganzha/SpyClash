import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";

type ErrorShape = {
  message?: unknown;
  status?: unknown;
  statusCode?: unknown;
  response?: { status?: unknown; headers?: Headers | Record<string, unknown> };
  headers?: Headers | Record<string, unknown>;
};

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function statusFrom(error: unknown): number {
  const shape = error as ErrorShape | null;
  const candidate = Number(
    shape?.status ?? shape?.statusCode ?? shape?.response?.status ?? 0,
  );
  return Number.isInteger(candidate) && candidate >= 400 && candidate < 600
    ? candidate
    : 500;
}

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

function retryAfter(error: unknown, fallback: number): string {
  const shape = error as ErrorShape | null;
  const supplied = headerValue(shape?.response?.headers, "retry-after") ||
    headerValue(shape?.headers, "retry-after");
  const seconds = Number.parseInt(supplied, 10);
  return Number.isInteger(seconds) && seconds >= 1 && seconds <= 300
    ? String(seconds)
    : String(fallback);
}

function response(
  message: string,
  status: number,
  code?: string,
  retryAfterSeconds?: string,
): Response {
  return Response.json(
    {
      error: message,
      ...(code ? { code } : {}),
      ...(retryAfterSeconds ? { retryable: true } : {}),
    },
    {
      status,
      ...(retryAfterSeconds
        ? { headers: { "Retry-After": retryAfterSeconds } }
        : {}),
    },
  );
}

export function communityErrorResponse(error: unknown): Response {
  if (error instanceof BillingIdentityLifecycleError) {
    const conflict = [
      "active_lease",
      "cas_contention",
      "deletion_in_progress",
    ].includes(error.code);
    return response(
      error.message,
      conflict ? 409 : 503,
      error.code,
      retryAfter(error, conflict ? 1 : 2),
    );
  }

  const status = statusFrom(error);
  if (status === 429) {
    return response(
      "Too many community requests. Retry shortly.",
      429,
      "rate_limited",
      retryAfter(error, 2),
    );
  }
  if (status === 502 || status === 503 || status === 504) {
    return response(
      "Community is temporarily unavailable.",
      503,
      "community_unavailable",
      retryAfter(error, 2),
    );
  }
  if (status >= 400 && status < 500) {
    const message = clean((error as ErrorShape | null)?.message) ||
      "Community request was rejected.";
    return response(message, status);
  }
  return response(
    "Community is temporarily unavailable.",
    500,
    "community_unavailable",
  );
}
