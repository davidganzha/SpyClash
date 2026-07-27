export type Entity = Record<string, any>;
export type NotificationTopic =
  | "release"
  | "service"
  | "community"
  | "developer";
export type NotificationImportance = "quiet" | "important";

export const INBOX_EPOCH = "2026-07-27T00:00:00.000Z";
export const INBOX_RETENTION_MS = 90 * 24 * 60 * 60 * 1_000;

export class NotificationContractError extends Error {
  constructor(
    message: string,
    public readonly status = 422,
    public readonly code = "invalid_notification_request",
  ) {
    super(message);
    this.name = "NotificationContractError";
  }
}

export function clean(value: unknown): string {
  return String(value ?? "").trim();
}

export function boundedText(value: unknown, maximum: number): string {
  return clean(value).slice(0, maximum);
}

export function integer(
  value: unknown,
  fallback: number,
  minimum: number,
  maximum: number,
): number {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(maximum, Math.max(minimum, parsed));
}

export function requireRequestID(value: unknown): string {
  const requestID = clean(value).toLowerCase();
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      .test(
        requestID,
      )
  ) {
    throw new NotificationContractError(
      "A UUID request_id is required.",
      422,
      "invalid_request_id",
    );
  }
  return requestID;
}

export function requireAnnouncementID(value: unknown): string {
  const id = boundedText(value, 200);
  if (!id) {
    throw new NotificationContractError(
      "announcement_id is required.",
      422,
      "missing_announcement_id",
    );
  }
  return id;
}

export function requireRevision(value: unknown): string {
  const revision = boundedText(value, 200);
  if (!revision) {
    throw new NotificationContractError(
      "expected_revision is required.",
      428,
      "missing_expected_revision",
    );
  }
  return revision;
}

function safeCopy(value: unknown, maximum: number, required: boolean): string {
  const copy = clean(value);
  if (required && !copy) {
    throw new NotificationContractError("English title and body are required.");
  }
  if (copy.length > maximum) {
    throw new NotificationContractError(
      `Notification copy exceeds ${maximum} characters.`,
      422,
      "copy_too_long",
    );
  }
  if (
    /<\/?[a-z][^>]*>/i.test(copy) ||
    /[\u0000-\u0008\u000B\u000C\u000E-\u001F]/.test(copy)
  ) {
    throw new NotificationContractError(
      "Notification copy must be plain text.",
      422,
      "unsafe_copy",
    );
  }
  return copy;
}

export function announcementCopy(body: Entity): Entity {
  const copy: Entity = {
    title_en: safeCopy(body.title_en, 80, true),
    body_en: safeCopy(body.body_en, 800, true),
    title_ru: safeCopy(body.title_ru, 80, false),
    body_ru: safeCopy(body.body_ru, 800, false),
    title_es: safeCopy(body.title_es, 80, false),
    body_es: safeCopy(body.body_es, 800, false),
  };
  for (const locale of ["ru", "es"]) {
    if (Boolean(copy[`title_${locale}`]) !== Boolean(copy[`body_${locale}`])) {
      throw new NotificationContractError(
        `Both ${locale} title and body must be supplied together.`,
        422,
        "incomplete_translation",
      );
    }
  }
  return copy;
}

export function requireTopic(value: unknown): NotificationTopic {
  const topic = clean(value) as NotificationTopic;
  if (!["release", "service", "community", "developer"].includes(topic)) {
    throw new NotificationContractError("Unknown notification topic.");
  }
  return topic;
}

export function requireImportance(value: unknown): NotificationImportance {
  const importance = clean(value) as NotificationImportance;
  if (importance !== "quiet" && importance !== "important") {
    throw new NotificationContractError("Unknown notification importance.");
  }
  return importance;
}

export function optionalExpiry(value: unknown, now = new Date()): string {
  const raw = clean(value);
  if (!raw) {
    return new Date(now.getTime() + INBOX_RETENTION_MS).toISOString();
  }
  const parsed = Date.parse(raw);
  const maximum = now.getTime() + 365 * 24 * 60 * 60 * 1_000;
  if (!Number.isFinite(parsed) || parsed <= now.getTime() || parsed > maximum) {
    throw new NotificationContractError(
      "expires_at must be a future date within one year.",
      422,
      "invalid_expiry",
    );
  }
  return new Date(parsed).toISOString();
}

export function optionalActionDeepLink(value: unknown): string {
  const deepLink = boundedText(value, 500);
  if (!deepLink) return "spyclash://notifications";
  try {
    const parsed = new URL(deepLink);
    if (parsed.protocol !== "spyclash:") throw new Error("scheme");
    return deepLink;
  } catch {
    throw new NotificationContractError(
      "action_deep_link must use the spyclash:// scheme.",
      422,
      "invalid_deep_link",
    );
  }
}

export function language(value: unknown): "en" | "ru" | "es" {
  const locale = clean(value).toLowerCase().split(/[-_]/)[0];
  return locale === "ru" || locale === "es" ? locale : "en";
}

export function localizedAnnouncement(
  announcement: Entity,
  locale: unknown,
): { title: string; body: string } {
  const lang = language(locale);
  return {
    title: boundedText(
      announcement[`title_${lang}`] || announcement.title_en,
      80,
    ),
    body: boundedText(
      announcement[`body_${lang}`] || announcement.body_en,
      800,
    ),
  };
}

export function notificationKeys(value: unknown): string[] {
  if (!Array.isArray(value) || value.length < 1 || value.length > 50) {
    throw new NotificationContractError(
      "notification_keys must contain between 1 and 50 items.",
    );
  }
  const keys = value.map((item) => boundedText(item, 260));
  if (
    keys.some((key) => !/^(global|personal):[^:]{1,220}$/.test(key)) ||
    new Set(keys).size !== keys.length
  ) {
    throw new NotificationContractError("Notification keys are invalid.");
  }
  return keys;
}

export function sourceTime(row: Entity): string {
  const raw = clean(
    row.published_at || row.created_at || row.created_date || row.updated_date,
  );
  const parsed = Date.parse(raw);
  return Number.isFinite(parsed) ? new Date(parsed).toISOString() : INBOX_EPOCH;
}

export function encodeCursor(createdAt: string, key: string): string {
  return btoa(JSON.stringify([createdAt, key]));
}

export function decodeCursor(value: unknown): [string, string] | null {
  const raw = clean(value);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(atob(raw));
    if (
      !Array.isArray(parsed) || parsed.length !== 2 ||
      !Number.isFinite(Date.parse(clean(parsed[0]))) || !clean(parsed[1])
    ) throw new Error("invalid");
    return [
      new Date(Date.parse(clean(parsed[0]))).toISOString(),
      clean(parsed[1]),
    ];
  } catch {
    throw new NotificationContractError("Inbox cursor is invalid.");
  }
}
