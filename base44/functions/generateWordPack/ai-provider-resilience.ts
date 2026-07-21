const DEFAULT_RETRY_DELAYS_MILLISECONDS = [250, 750] as const;

const TRANSIENT_HTTP_STATUSES = new Set([
  408,
  425,
  429,
  500,
  502,
  503,
  504,
]);

const TRANSIENT_ERROR_CODES = new Set([
  "eai_again",
  "econnaborted",
  "econnrefused",
  "econnreset",
  "ehostunreach",
  "enetdown",
  "enetreset",
  "enetunreach",
  "etimedout",
  "und_err_connect_timeout",
  "und_err_headers_timeout",
  "und_err_socket",
]);

const TRANSIENT_ERROR_NAMES = new Set([
  "connectionerror",
  "fetcherror",
  "networkerror",
  "timeouterror",
]);

type UnknownRecord = Record<string, unknown>;

export type AIProviderRetryInfo = {
  /** One-based attempt that just failed. */
  attempt: number;
  /** One-based attempt that will run after the delay. */
  nextAttempt: number;
  delayMilliseconds: number;
  error: unknown;
};

export class AIProviderUnavailableError extends Error {
  readonly status = 503 as const;
  readonly code = "ai_provider_unavailable" as const;
  readonly retryable = true as const;

  constructor() {
    super("AI provider is temporarily unavailable. Try again shortly.");
    this.name = "AIProviderUnavailableError";
  }
}

function recordValue(record: UnknownRecord, key: string): unknown {
  try {
    return record[key];
  } catch {
    return undefined;
  }
}

function asRecord(value: unknown): UnknownRecord | undefined {
  return value !== null && typeof value === "object"
    ? value as UnknownRecord
    : undefined;
}

function normalizedHTTPStatus(value: unknown): number | undefined {
  const status = typeof value === "number"
    ? value
    : typeof value === "string" && value.trim()
    ? Number(value)
    : Number.NaN;
  return Number.isInteger(status) && status >= 100 && status <= 599
    ? status
    : undefined;
}

function statusFromMessage(value: unknown): number | undefined {
  const message = typeof value === "string" ? value : "";
  const labeled = message.match(
    /\b(?:http|status(?:\s+code)?)\s*[:=]?\s*(\d{3})\b/i,
  );
  const leading = message.match(/^\s*(\d{3})\b/);
  return normalizedHTTPStatus(labeled?.[1] ?? leading?.[1]);
}

function errorMessage(error: unknown): string {
  if (typeof error === "string") return error;
  const record = asRecord(error);
  const message = record ? recordValue(record, "message") : undefined;
  return typeof message === "string" ? message : "";
}

function errorStatus(
  error: unknown,
  seen = new Set<unknown>(),
  depth = 0,
): number | undefined {
  if (depth > 3 || error === null || error === undefined || seen.has(error)) {
    return undefined;
  }
  seen.add(error);

  const direct = normalizedHTTPStatus(error);
  if (direct !== undefined) return direct;

  const record = asRecord(error);
  if (record) {
    for (
      const key of [
        "status",
        "statusCode",
        "status_code",
        "httpStatus",
        "http_status",
        "code",
      ]
    ) {
      const status = normalizedHTTPStatus(recordValue(record, key));
      if (status !== undefined) return status;
    }

    const responseStatus = errorStatus(
      recordValue(record, "response"),
      seen,
      depth + 1,
    );
    if (responseStatus !== undefined) return responseStatus;
  }

  const messageStatus = statusFromMessage(errorMessage(error));
  if (messageStatus !== undefined) return messageStatus;

  return record
    ? errorStatus(recordValue(record, "cause"), seen, depth + 1)
    : undefined;
}

function hasTransientTransportSignal(
  error: unknown,
  seen = new Set<unknown>(),
  depth = 0,
): boolean {
  if (depth > 3 || error === null || error === undefined || seen.has(error)) {
    return false;
  }
  seen.add(error);

  const record = asRecord(error);
  const name = record
    ? String(recordValue(record, "name") ?? "").trim().toLowerCase()
    : "";
  if (TRANSIENT_ERROR_NAMES.has(name)) return true;

  const code = record
    ? String(recordValue(record, "code") ?? "").trim().toLowerCase()
    : "";
  if (TRANSIENT_ERROR_CODES.has(code)) return true;

  const message = errorMessage(error).toLowerCase();
  if (
    [
      "connection closed",
      "connection refused",
      "connection reset",
      "failed to fetch",
      "fetch failed",
      "internal server error",
      "load failed",
      "network error",
      "network request failed",
      "rate limit",
      "service unavailable",
      "service temporarily unavailable",
      "socket hang up",
      "temporary failure in name resolution",
      "timed out",
      "timeout",
      "too many requests",
    ].some((marker) => message.includes(marker))
  ) {
    return true;
  }

  const cause = record ? recordValue(record, "cause") : undefined;
  return hasTransientTransportSignal(cause, seen, depth + 1);
}

export function isTransientAIProviderError(error: unknown): boolean {
  const status = errorStatus(error);
  if (status !== undefined) return TRANSIENT_HTTP_STATUSES.has(status);
  return hasTransientTransportSignal(error);
}

function normalizedDelay(value: number): number {
  return Number.isFinite(value) ? Math.max(0, Math.trunc(value)) : 0;
}

async function defaultDelay(milliseconds: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}

export async function invokeAIProviderWithRetry<T>(input: {
  operation: (attempt: number) => T | Promise<T>;
  delays?: readonly number[];
  delay?: (milliseconds: number) => void | Promise<void>;
  onRetry?: (info: AIProviderRetryInfo) => void | Promise<void>;
}): Promise<T> {
  const delays = (input.delays ?? DEFAULT_RETRY_DELAYS_MILLISECONDS).map(
    normalizedDelay,
  );
  const delay = input.delay ?? defaultDelay;

  for (let attemptIndex = 0;; attemptIndex += 1) {
    try {
      return await input.operation(attemptIndex + 1);
    } catch (error) {
      if (!isTransientAIProviderError(error)) throw error;
      if (attemptIndex >= delays.length) {
        throw new AIProviderUnavailableError();
      }

      const delayMilliseconds = delays[attemptIndex];
      await input.onRetry?.({
        attempt: attemptIndex + 1,
        nextAttempt: attemptIndex + 2,
        delayMilliseconds,
        error,
      });
      await delay(delayMilliseconds);
    }
  }
}
