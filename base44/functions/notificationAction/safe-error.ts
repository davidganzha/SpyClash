export type SafeNotificationErrorDetails = Readonly<{
  message: string;
  status: number;
}>;

const MAX_LOG_MESSAGE_LENGTH = 500;

function property(value: unknown, key: string): unknown {
  if (
    value === null ||
    (typeof value !== "object" && typeof value !== "function")
  ) return undefined;
  try {
    return Reflect.get(value, key);
  } catch {
    return undefined;
  }
}

function scalarText(value: unknown): string {
  let text = "";
  if (typeof value === "string") text = value;
  else if (
    typeof value === "number" || typeof value === "bigint" ||
    typeof value === "boolean"
  ) text = String(value);
  return text.trim().slice(0, MAX_LOG_MESSAGE_LENGTH);
}

function httpStatus(value: unknown): number {
  const candidate = typeof value === "number"
    ? value
    : typeof value === "string" && /^\d{3}$/.test(value.trim())
    ? Number(value)
    : 0;
  return Number.isInteger(candidate) && candidate >= 400 && candidate < 600
    ? candidate
    : 0;
}

/**
 * SDK rejection values may contain circular request/response graphs. Reduce
 * them to bounded primitives before passing anything to structured logging.
 */
export function safeNotificationErrorDetails(
  error: unknown,
): SafeNotificationErrorDetails {
  const response = property(error, "response");
  const status = [
    property(error, "status"),
    property(error, "statusCode"),
    property(response, "status"),
  ].map(httpStatus).find(Boolean) || 0;
  const message = scalarText(property(error, "message")) ||
    scalarText(error) || "Unknown notification backend error";
  return { message, status };
}
