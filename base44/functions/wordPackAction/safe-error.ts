export type SafeWordPackErrorDetails = Readonly<{
  message: string;
  status: number;
  code: string;
}>;

const MAX_MESSAGE_LENGTH = 500;
const MAX_CODE_LENGTH = 100;

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

function scalarText(value: unknown, maximum: number): string {
  let text = "";
  if (typeof value === "string") text = value;
  else if (
    typeof value === "number" || typeof value === "bigint" ||
    typeof value === "boolean"
  ) text = String(value);
  return text.trim().slice(0, maximum);
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
 * Never stringify raw SDK errors: Base44 request and response objects can form
 * cycles. Only bounded scalar fields leave this boundary.
 */
export function safeWordPackErrorDetails(
  error: unknown,
): SafeWordPackErrorDetails {
  const response = property(error, "response");
  const status = [
    property(error, "status"),
    property(error, "statusCode"),
    property(response, "status"),
  ].map(httpStatus).find(Boolean) || 0;
  const message = scalarText(property(error, "message"), MAX_MESSAGE_LENGTH) ||
    scalarText(error, MAX_MESSAGE_LENGTH) || "Word pack request failed";
  const code = scalarText(property(error, "code"), MAX_CODE_LENGTH);
  return { message, status, code };
}
