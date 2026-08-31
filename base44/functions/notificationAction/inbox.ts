import {
  announcementCopy,
  clean,
  decodeCursor,
  encodeCursor,
  type Entity,
  INBOX_EPOCH,
  INBOX_RETENTION_MS,
  integer,
  language,
  localizedAnnouncement,
  NotificationContractError,
  optionalActionDeepLink,
  optionalExpiry,
  requireAnnouncementID,
  requireImportance,
  requireRequestID,
  requireRevision,
  requireTopic,
  sourceTime,
} from "./contracts.ts";

export type InboxScope = "all" | "global" | "personal";
export type InboxItem = {
  id: string;
  scope: "global" | "personal";
  kind: string;
  importance: "quiet" | "important";
  title: string;
  body: string;
  published_at: string;
  read_at: string | null;
  action_deep_link: string;
};

const PAGE_SIZE = 100;
const MAX_ADMIN_SCAN_ROWS = 500;
export const INBOX_SCOPE_WINDOW_LIMIT = 500;
export const INBOX_QUERY_LIMITS = {
  sourcePage: INBOX_SCOPE_WINDOW_LIMIT,
  receiptKeys: 50,
  receiptDuplicatesPerKey: 4,
} as const;
const PERSONAL_EVENT_TYPES = new Set([
  "friend_request",
  "room_invite",
]);

async function allMatching(
  store: any,
  filter: Record<string, unknown>,
  sort = "-created_date",
  maximum = MAX_ADMIN_SCAN_ROWS,
): Promise<Entity[]> {
  const records: Entity[] = [];
  for (let skip = 0; skip < maximum; skip += PAGE_SIZE) {
    const page = await store.filter(
      filter,
      sort,
      Math.min(PAGE_SIZE, maximum - skip),
      skip,
    ) || [];
    records.push(...page);
    if (page.length < PAGE_SIZE) return records;
  }
  return records;
}

async function one(
  store: any,
  filter: Record<string, unknown>,
): Promise<Entity | null> {
  const rows = await store.filter(filter, "created_date", 2, 0) || [];
  return rows.length === 1 ? rows[0] : null;
}

function hasMaterializedPersonalProjection(event: Entity): boolean {
  return event.inbox_visible === true &&
    Boolean(clean(event.inbox_committed_at)) &&
    Number(event.inbox_projection_version || 0) >= 1 &&
    Boolean(clean(event.inbox_kind)) &&
    Boolean(clean(event.inbox_title_en)) &&
    Boolean(clean(event.inbox_body_en)) &&
    Boolean(clean(event.inbox_published_at));
}

function materializedPersonalProjection(
  event: Entity,
  localeValue: unknown,
): InboxItem | null {
  const type = clean(event.event_type);
  if (
    !PERSONAL_EVENT_TYPES.has(type) || clean(event.state) === "cancelled" ||
    !hasMaterializedPersonalProjection(event)
  ) return null;
  const locale = language(localeValue);
  const title = clean(event[`inbox_title_${locale}`] || event.inbox_title_en)
    .slice(0, 80);
  const body = clean(event[`inbox_body_${locale}`] || event.inbox_body_en)
    .slice(0, 800);
  if (!title || !body) return null;
  const configuredDeepLink = clean(event.inbox_action_deep_link).slice(0, 500);
  return {
    id: `personal:${clean(event.id)}`,
    scope: "personal",
    kind: clean(event.inbox_kind) || type,
    importance: clean(event.inbox_importance) === "quiet"
      ? "quiet"
      : "important",
    title,
    body,
    published_at: sourceTime({
      published_at: event.inbox_published_at,
      created_at: event.created_at,
      created_date: event.created_date,
    }),
    read_at: null,
    action_deep_link: configuredDeepLink.startsWith("spyclash://")
      ? configuredDeepLink
      : "spyclash://notifications",
  };
}

function projectPersonalEvent(input: {
  event: Entity;
  userID: string;
  locale: unknown;
}): InboxItem | null {
  if (clean(input.event.recipient_user_id) !== input.userID) return null;
  return materializedPersonalProjection(input.event, input.locale);
}

function isVisibleGlobal(announcement: Entity, now: Date): boolean {
  if (clean(announcement.status) !== "published") return false;
  const published = Date.parse(clean(announcement.published_at));
  const expiry = Date.parse(clean(announcement.expires_at));
  return Number.isFinite(published) && published <= now.getTime() &&
    (!Number.isFinite(expiry) || expiry > now.getTime());
}

function globalProjection(
  announcement: Entity,
  locale: unknown,
): InboxItem {
  const copy = localizedAnnouncement(announcement, locale);
  const configuredDeepLink = clean(announcement.action_deep_link).slice(0, 500);
  return {
    id: `global:${clean(announcement.id)}`,
    scope: "global",
    kind: clean(announcement.topic) || "developer",
    importance: clean(announcement.importance) === "important"
      ? "important"
      : "quiet",
    title: copy.title,
    body: copy.body,
    published_at: sourceTime(announcement),
    read_at: null,
    action_deep_link: configuredDeepLink.startsWith("spyclash://")
      ? configuredDeepLink
      : "spyclash://notifications",
  };
}

export function requireScope(value: unknown): InboxScope {
  const scope = clean(value || "all") as InboxScope;
  if (!(["all", "global", "personal"] as string[]).includes(scope)) {
    throw new NotificationContractError("Inbox scope is invalid.");
  }
  return scope;
}

function sorted(items: InboxItem[]): InboxItem[] {
  return [...items].sort((left, right) =>
    right.published_at.localeCompare(left.published_at) ||
    left.id.localeCompare(right.id)
  );
}

function readState(
  items: InboxItem[],
  receipts: Entity[],
): InboxItem[] {
  const individual = new Map<string, string>();
  const watermark = receiptWatermarks(receipts);
  for (const receipt of receipts) {
    const key = clean(receipt.notification_key);
    const readAt = sourceTime({ published_at: receipt.read_at });
    if (/^(global|personal):/.test(key)) {
      const current = individual.get(key);
      if (!current || readAt > current) individual.set(key, readAt);
    }
  }
  return items.map((item) => {
    const mark = individual.get(item.id);
    const allMark = watermark.all;
    const scopedMark = watermark[item.scope];
    const applicable =
      [mark, allMark, scopedMark].filter((value): value is string =>
        Boolean(value) && item.published_at <= value!
      ).sort().at(-1) || null;
    return { ...item, read_at: applicable };
  });
}

function receiptWatermarks(
  receipts: Entity[],
): Partial<Record<InboxScope, string>> {
  const watermarks: Partial<Record<InboxScope, string>> = {};
  for (const receipt of receipts) {
    const key = clean(receipt.notification_key);
    const scope = key === "__all__"
      ? "all"
      : key === "__all__:global"
      ? "global"
      : key === "__all__:personal"
      ? "personal"
      : null;
    if (!scope) continue;
    const readAt = sourceTime({ published_at: receipt.read_at });
    const current = watermarks[scope];
    if (!current || readAt > current) watermarks[scope] = readAt;
  }
  return watermarks;
}

function unreadLowerBounds(
  receipts: Entity[],
): Partial<Record<"global" | "personal", string>> {
  const watermarks = receiptWatermarks(receipts);
  const result: Partial<Record<"global" | "personal", string>> = {};
  for (const scope of ["global", "personal"] as const) {
    const candidates = [watermarks.all, watermarks[scope]].filter(
      (value): value is string => Boolean(value),
    );
    if (candidates.length) result[scope] = candidates.sort().at(-1);
  }
  return result;
}

export function unreadCounts(items: InboxItem[]) {
  const global =
    items.filter((item) => item.scope === "global" && !item.read_at).length;
  const personal =
    items.filter((item) => item.scope === "personal" && !item.read_at).length;
  return { global, personal, total: global + personal };
}

type InboxCursor = [string, string] | null;

type SourcePage = {
  items: InboxItem[];
  next_cursor: string | null;
};

function previousMillisecond(value: string): string {
  const parsed = Date.parse(value);
  return new Date(parsed - 1).toISOString();
}

function timeRangeFilter(
  base: Record<string, unknown>,
  field: string,
  upperInclusive: string,
): Record<string, unknown> {
  const existing = base[field];
  const operators = existing && typeof existing === "object" &&
      !Array.isArray(existing)
    ? existing as Record<string, unknown>
    : {};
  return {
    ...base,
    [field]: { ...operators, $lte: upperInclusive },
  };
}

function cursorAtSourceTimestamp(
  prefix: "global:" | "personal:",
  cursor: InboxCursor,
): { include: boolean; rawIDAfter?: string } {
  if (!cursor) return { include: false };
  const cursorID = cursor[1];
  if (cursorID.startsWith(prefix)) {
    return { include: true, rawIDAfter: cursorID.slice(prefix.length) };
  }
  return { include: prefix.localeCompare(cursorID) > 0 };
}

function sourceRowTime(row: Entity, field: string): string {
  return sourceTime({ published_at: row[field] });
}

async function exactTimestampRows(input: {
  store: any;
  baseFilter: Record<string, unknown>;
  timeField: string;
  timestamp: string;
  rawIDAfter?: string;
  limit: number;
}): Promise<Entity[]> {
  const filter: Record<string, unknown> = {
    ...input.baseFilter,
    [input.timeField]: input.timestamp,
  };
  if (input.rawIDAfter) filter.id = { $gt: input.rawIDAfter };
  return await input.store.filter(filter, "id", input.limit, 0) || [];
}

/**
 * Reads one source in (published_at DESC, id ASC) order without offsets.
 * Base44 exposes one sort field, so a boundary timestamp is re-read by exact
 * timestamp + id keyset. That prevents a large equal-timestamp group from
 * being split nondeterministically by the range query.
 */
async function sourceRowsPage(input: {
  store: any;
  baseFilter: Record<string, unknown>;
  timeField: string;
  prefix: "global:" | "personal:";
  cursor: InboxCursor;
  upperInclusive: string;
  limit: number;
}): Promise<{ rows: Entity[]; hasMore: boolean }> {
  const rows: Entity[] = [];
  let remaining = input.limit;
  let upperInclusive = input.cursor
    ? previousMillisecond(input.cursor[0])
    : input.upperInclusive;

  const sameTimestamp = cursorAtSourceTimestamp(input.prefix, input.cursor);
  if (input.cursor && sameTimestamp.include) {
    const sameRows = await exactTimestampRows({
      store: input.store,
      baseFilter: input.baseFilter,
      timeField: input.timeField,
      timestamp: input.cursor[0],
      rawIDAfter: sameTimestamp.rawIDAfter,
      limit: remaining + 1,
    });
    rows.push(...sameRows.slice(0, remaining));
    if (sameRows.length > remaining) return { rows, hasMore: true };
    remaining -= sameRows.length;
    if (remaining === 0) {
      const older = await input.store.filter(
        timeRangeFilter(
          input.baseFilter,
          input.timeField,
          upperInclusive,
        ),
        `-${input.timeField}`,
        1,
        0,
      ) || [];
      return { rows, hasMore: older.length > 0 };
    }
  }

  while (remaining > 0) {
    const rangeRows: Entity[] = await input.store.filter(
      timeRangeFilter(input.baseFilter, input.timeField, upperInclusive),
      `-${input.timeField}`,
      remaining + 1,
      0,
    ) || [];
    if (!rangeRows.length) return { rows, hasMore: false };

    const normalized = [...rangeRows].sort((left, right) =>
      sourceRowTime(right, input.timeField).localeCompare(
        sourceRowTime(left, input.timeField),
      ) || clean(left.id).localeCompare(clean(right.id))
    );
    const boundaryTime = sourceRowTime(normalized.at(-1)!, input.timeField);
    const complete = normalized.filter((row) =>
      sourceRowTime(row, input.timeField) > boundaryTime
    );
    if (complete.length >= remaining) {
      rows.push(...complete.slice(0, remaining));
      return { rows, hasMore: true };
    }
    rows.push(...complete);
    remaining -= complete.length;

    const boundaryRows = await exactTimestampRows({
      store: input.store,
      baseFilter: input.baseFilter,
      timeField: input.timeField,
      timestamp: boundaryTime,
      limit: remaining + 1,
    });
    rows.push(...boundaryRows.slice(0, remaining));
    if (boundaryRows.length > remaining) return { rows, hasMore: true };
    remaining -= boundaryRows.length;
    upperInclusive = previousMillisecond(boundaryTime);

    // A short range plus an exhausted exact boundary proves there is no tail.
    if (rangeRows.length < complete.length + boundaryRows.length + 1) {
      return { rows, hasMore: false };
    }
  }
  return { rows, hasMore: true };
}

function earliestInboxTime(now: Date): string {
  return new Date(Math.max(
    Date.parse(INBOX_EPOCH),
    now.getTime() - INBOX_RETENTION_MS,
  )).toISOString();
}

function lowerBoundBefore(value: string): string {
  return previousMillisecond(value);
}

async function sourceItemsPage(input: {
  base44: any;
  userID: string;
  locale: unknown;
  scope: "global" | "personal";
  cursor: InboxCursor;
  limit: number;
  now: Date;
  lowerExclusive?: string;
}): Promise<{ items: InboxItem[]; hasMore: boolean }> {
  const earliest = earliestInboxTime(input.now);
  const lower = input.lowerExclusive && input.lowerExclusive > earliest
    ? input.lowerExclusive
    : lowerBoundBefore(earliest);
  const upper = input.cursor?.[0] || input.now.toISOString();
  if (input.scope === "global") {
    const page = await sourceRowsPage({
      store: input.base44.asServiceRole.entities.NotificationAnnouncement,
      baseFilter: {
        status: "published",
        published_at: { $gt: lower },
        $or: [
          { expires_at: { $gt: input.now.toISOString() } },
          { expires_at: { $exists: false } },
          { expires_at: null },
        ],
      },
      timeField: "published_at",
      prefix: "global:",
      cursor: input.cursor,
      upperInclusive: upper,
      limit: input.limit,
    });
    return {
      items: page.rows.filter((row) => isVisibleGlobal(row, input.now)).map(
        (row) => globalProjection(row, input.locale),
      ),
      hasMore: page.hasMore,
    };
  }

  const page = await sourceRowsPage({
    store: input.base44.asServiceRole.entities.PushNotificationEvent,
    baseFilter: {
      recipient_user_id: input.userID,
      inbox_visible: true,
      inbox_committed_at: { $gt: lowerBoundBefore(INBOX_EPOCH) },
      inbox_projection_version: { $gt: 0 },
      inbox_published_at: { $gt: lower },
      inbox_kind: { $gt: "" },
      inbox_title_en: { $gt: "" },
      inbox_body_en: { $gt: "" },
      event_type: { $in: [...PERSONAL_EVENT_TYPES] },
      state: {
        $in: [
          "pending",
          "processing",
          "retry",
          "delivered",
          "partial",
          "no_devices",
          "failed",
        ],
      },
    },
    timeField: "inbox_published_at",
    prefix: "personal:",
    cursor: input.cursor,
    upperInclusive: upper,
    limit: input.limit,
  });
  return {
    items: page.rows.map((event) =>
      projectPersonalEvent({
        event,
        userID: input.userID,
        locale: input.locale,
      })
    ).filter((item): item is InboxItem => Boolean(item)),
    hasMore: page.hasMore,
  };
}

async function rawInboxPage(input: {
  base44: any;
  userID: string;
  locale: unknown;
  scope: InboxScope;
  cursor: unknown;
  limit: unknown;
  now?: Date;
  lowerExclusive?: string;
}): Promise<SourcePage> {
  const now = input.now || new Date();
  const cursor = decodeCursor(input.cursor);
  const limit = integer(
    input.limit,
    30,
    1,
    INBOX_QUERY_LIMITS.sourcePage,
  );
  const requested = limit + 1;
  const [globals, personal] = await Promise.all([
    input.scope === "personal"
      ? Promise.resolve({ items: [], hasMore: false })
      : sourceItemsPage({
        ...input,
        scope: "global",
        cursor,
        limit: requested,
        now,
      }),
    input.scope === "global"
      ? Promise.resolve({ items: [], hasMore: false })
      : sourceItemsPage({
        ...input,
        scope: "personal",
        cursor,
        limit: requested,
        now,
      }),
  ]);
  const merged = sorted([...globals.items, ...personal.items]);
  const items = merged.slice(0, limit);
  const hasMore = merged.length > limit || globals.hasMore || personal.hasMore;
  const last = items.at(-1);
  return {
    items,
    next_cursor: hasMore && last
      ? encodeCursor(last.published_at, last.id)
      : null,
  };
}

async function matchingReceipts(input: {
  store: any;
  userID: string;
  keys: string[];
}): Promise<Entity[]> {
  const rows: Entity[] = [];
  const keys = [...new Set(input.keys.map(clean).filter(Boolean))];
  for (
    let offset = 0;
    offset < keys.length;
    offset += INBOX_QUERY_LIMITS.receiptKeys
  ) {
    const batch = keys.slice(offset, offset + INBOX_QUERY_LIMITS.receiptKeys);
    const maximum = batch.length *
      INBOX_QUERY_LIMITS.receiptDuplicatesPerKey;
    const page: Entity[] = await input.store.filter(
      {
        user_id: input.userID,
        notification_key: { $in: batch },
      },
      "-read_at",
      maximum + 1,
      0,
    ) || [];
    if (page.length > maximum) {
      throw new NotificationContractError(
        "Notification receipts require repair.",
        503,
        "receipt_cardinality_exceeded",
      );
    }
    rows.push(...page);
  }
  return rows;
}

const WATERMARK_KEYS = ["__all__", "__all__:global", "__all__:personal"];

async function hydrateReadState(input: {
  base44: any;
  userID: string;
  items: InboxItem[];
  watermarkReceipts?: Entity[];
}): Promise<InboxItem[]> {
  const watermarkReceipts = input.watermarkReceipts || await matchingReceipts({
    store: input.base44.asServiceRole.entities.NotificationReadReceipt,
    userID: input.userID,
    keys: WATERMARK_KEYS,
  });
  const individual = await matchingReceipts({
    store: input.base44.asServiceRole.entities.NotificationReadReceipt,
    userID: input.userID,
    keys: input.items.map((item) => item.id),
  });
  return readState(input.items, [...watermarkReceipts, ...individual]);
}

/**
 * The product inbox is an exact, bounded window: the newest 500 retained
 * global items and the newest 500 retained personal items. Keeping the caps
 * independent prevents a release-news burst from evicting invitations.
 *
 * rawInboxPage already orders each source by (published_at DESC, id ASC), so
 * one limit-sized source page is the complete visibility window for that
 * scope. Every list and unread response is derived from this same snapshot.
 */
async function boundedInboxWindow(input: {
  base44: any;
  userID: string;
  locale: unknown;
  now: Date;
  lowerExclusiveByScope?: Partial<
    Record<"global" | "personal", string>
  >;
}): Promise<InboxItem[]> {
  const [globals, personal] = await Promise.all([
    rawInboxPage({
      ...input,
      scope: "global",
      cursor: null,
      limit: INBOX_SCOPE_WINDOW_LIMIT,
      lowerExclusive: input.lowerExclusiveByScope?.global,
    }),
    rawInboxPage({
      ...input,
      scope: "personal",
      cursor: null,
      limit: INBOX_SCOPE_WINDOW_LIMIT,
      lowerExclusive: input.lowerExclusiveByScope?.personal,
    }),
  ]);
  return sorted([...globals.items, ...personal.items]);
}

async function inboxSnapshot(input: {
  base44: any;
  userID: string;
  locale: unknown;
  now?: Date;
}): Promise<{ items: InboxItem[]; unread: ReturnType<typeof unreadCounts> }> {
  const now = input.now || new Date();
  const rawItems = await boundedInboxWindow({ ...input, now });
  const items = await hydrateReadState({
    base44: input.base44,
    userID: input.userID,
    items: rawItems,
  });
  return { items, unread: unreadCounts(items) };
}

export async function inboxUnreadCounts(input: {
  base44: any;
  userID: string;
  locale: unknown;
  now?: Date;
}) {
  const now = input.now || new Date();
  const watermarkReceipts = await matchingReceipts({
    store: input.base44.asServiceRole.entities.NotificationReadReceipt,
    userID: input.userID,
    keys: WATERMARK_KEYS,
  });
  const rawItems = await boundedInboxWindow({
    ...input,
    now,
    lowerExclusiveByScope: unreadLowerBounds(watermarkReceipts),
  });
  const items = await hydrateReadState({
    base44: input.base44,
    userID: input.userID,
    items: rawItems,
    watermarkReceipts,
  });
  return unreadCounts(items);
}

export async function queryInboxPage(input: {
  base44: any;
  userID: string;
  locale: unknown;
  scope: InboxScope;
  cursor: unknown;
  limit: unknown;
  now?: Date;
}): Promise<SourcePage & { unread: ReturnType<typeof unreadCounts> }> {
  const snapshot = await inboxSnapshot(input);
  return {
    ...pageInbox({
      items: snapshot.items,
      scope: input.scope,
      limit: input.limit,
      cursor: input.cursor,
    }),
    unread: snapshot.unread,
  };
}

export async function buildInbox(input: {
  base44: any;
  userID: string;
  locale: unknown;
  now?: Date;
}): Promise<InboxItem[]> {
  return (await inboxSnapshot(input)).items;
}

export function pageInbox(input: {
  items: InboxItem[];
  scope: InboxScope;
  limit: unknown;
  cursor: unknown;
}) {
  const cursor = decodeCursor(input.cursor);
  const scoped = input.scope === "all"
    ? input.items
    : input.items.filter((item) => item.scope === input.scope);
  const afterCursor = cursor
    ? scoped.filter((item) =>
      item.published_at < cursor[0] ||
      (item.published_at === cursor[0] && item.id > cursor[1])
    )
    : scoped;
  const limit = integer(input.limit, 30, 1, 100);
  const items = afterCursor.slice(0, limit);
  const hasMore = afterCursor.length > items.length;
  const last = items.at(-1);
  return {
    items,
    next_cursor: hasMore && last
      ? encodeCursor(last.published_at, last.id)
      : null,
  };
}

async function receiptDedupeKey(userID: string, key: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`spyclash-notification-receipt:${userID}:${key}`),
  );
  const hex = Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  return `receipt:${hex.slice(0, 48)}`;
}

export async function upsertReceipt(input: {
  store: any;
  userID: string;
  key: string;
  readAt: string;
  persist: <T>(writer: () => Promise<T>) => Promise<T>;
}): Promise<Entity> {
  const matches = await input.store.filter(
    {
      user_id: input.userID,
      notification_key: input.key,
    },
    "created_date",
    INBOX_QUERY_LIMITS.receiptDuplicatesPerKey + 1,
    0,
  ) || [];
  if (matches.length > INBOX_QUERY_LIMITS.receiptDuplicatesPerKey) {
    throw new NotificationContractError(
      "Notification receipts require repair.",
      503,
      "receipt_cardinality_exceeded",
    );
  }
  const canonical =
    [...matches].sort((left, right) =>
      clean(left.created_date).localeCompare(clean(right.created_date)) ||
      clean(left.id).localeCompare(clean(right.id))
    )[0];
  const now = input.readAt;
  let saved: Entity;
  if (canonical?.id) {
    saved = await input.persist(() =>
      input.store.update(canonical.id, {
        read_at: now,
        updated_at: now,
      })
    );
  } else {
    const dedupeKey = await receiptDedupeKey(input.userID, input.key);
    saved = await input.persist(() =>
      input.store.create({
        dedupe_key: dedupeKey,
        user_id: input.userID,
        notification_key: input.key,
        read_at: now,
        created_at: now,
        updated_at: now,
      })
    );
  }
  for (const duplicate of matches) {
    if (clean(duplicate.id) && clean(duplicate.id) !== clean(saved.id)) {
      await input.persist(() => input.store.delete(duplicate.id));
    }
  }
  return saved;
}

export async function validateItemOwnership(input: {
  base44: any;
  userID: string;
  itemID: string;
  locale: unknown;
  now?: Date;
}): Promise<InboxItem> {
  const now = input.now || new Date();
  const earliest = Math.max(
    Date.parse(INBOX_EPOCH),
    now.getTime() - INBOX_RETENTION_MS,
  );
  let item: InboxItem | null = null;
  if (input.itemID.startsWith("global:")) {
    const announcement = await one(
      input.base44.asServiceRole.entities.NotificationAnnouncement,
      { id: input.itemID.slice("global:".length) },
    );
    if (
      announcement && isVisibleGlobal(announcement, now) &&
      Date.parse(sourceTime(announcement)) >= earliest
    ) item = globalProjection(announcement, input.locale);
  } else if (input.itemID.startsWith("personal:")) {
    const event = await one(
      input.base44.asServiceRole.entities.PushNotificationEvent,
      {
        id: input.itemID.slice("personal:".length),
        recipient_user_id: input.userID,
      },
    );
    if (event) {
      item = await projectPersonalEvent({
        event,
        userID: input.userID,
        locale: input.locale,
      });
      if (item && Date.parse(item.published_at) < earliest) item = null;
    }
  }
  if (!item) {
    throw new NotificationContractError(
      "Notification is unavailable.",
      404,
      "notification_not_found",
    );
  }
  return item;
}

function sameDraftContent(left: Entity, right: Entity): boolean {
  return [
    "topic",
    "importance",
    "title_en",
    "body_en",
    "title_ru",
    "body_ru",
    "title_es",
    "body_es",
    "title_uk",
    "body_uk",
    "action_deep_link",
    "expires_at",
  ].every((field) => clean(left[field]) === clean(right[field]));
}

function announcementPayload(body: Entity, now: Date): Entity {
  return {
    topic: requireTopic(body.topic || "developer"),
    importance: requireImportance(body.importance || "quiet"),
    ...announcementCopy(body),
    action_deep_link: optionalActionDeepLink(body.action_deep_link),
    expires_at: optionalExpiry(body.expires_at, now),
  };
}

type Persist = <T>(writer: () => Promise<T>) => Promise<T>;
const directPersist: Persist = async (writer) => await writer();

async function convergeRequestRows(input: {
  store: any;
  rows: Entity[];
  payload: Entity;
  persist: Persist;
}): Promise<Entity> {
  if (!input.rows.length) {
    throw new NotificationContractError(
      "Announcement create result is ambiguous.",
      503,
      "ambiguous_create",
    );
  }
  if (input.rows.some((row) => !sameDraftContent(row, input.payload))) {
    throw new NotificationContractError(
      "request_id was already used with different content.",
      409,
      "idempotency_conflict",
    );
  }
  const published = input.rows.filter((row) =>
    clean(row.status) === "published"
  );
  const withdrawn = input.rows.filter((row) =>
    clean(row.status) === "withdrawn"
  );
  if (published.length > 1 || withdrawn.length > 0 && input.rows.length > 1) {
    throw new NotificationContractError(
      "request_id has ambiguous announcement state.",
      503,
      "ambiguous_idempotency_state",
    );
  }
  const canonical = (published.length ? published : input.rows).sort(
    (left, right) =>
      clean(left.created_at || left.created_date).localeCompare(
        clean(right.created_at || right.created_date),
      ) || clean(left.id).localeCompare(clean(right.id)),
  )[0];
  for (const duplicate of input.rows) {
    if (
      clean(duplicate.id) && clean(duplicate.id) !== clean(canonical.id) &&
      clean(duplicate.status) === "draft"
    ) {
      await input.persist(() => input.store.delete(duplicate.id));
    }
  }
  return canonical;
}

export async function createDraft(input: {
  store: any;
  body: Entity;
  now?: Date;
  randomUUID?: () => string;
  persist?: Persist;
}): Promise<Entity> {
  const now = input.now || new Date();
  const requestID = requireRequestID(input.body.request_id);
  const dedupeKey = `notification:${requestID}`;
  const existing = await allMatching(
    input.store,
    { dedupe_key: dedupeKey },
    "created_date",
    10,
  );
  const payload = announcementPayload({
    ...input.body,
    // A caller that omitted expiry must be able to retry the same request id
    // later without the rolling 90-day default looking like new content.
    expires_at: clean(input.body.expires_at) || clean(existing[0]?.expires_at),
  }, now);
  const persist = input.persist || directPersist;
  if (existing.length) {
    return await convergeRequestRows({
      store: input.store,
      rows: existing,
      payload,
      persist,
    });
  }
  const revision = (input.randomUUID || (() => crypto.randomUUID()))();
  const nowISO = now.toISOString();
  let createError: unknown;
  try {
    await persist(() =>
      input.store.create({
        dedupe_key: dedupeKey,
        ...payload,
        status: "draft",
        published_at: null,
        fanout_state: "not_requested",
        fanout_attempt_count: 0,
        fanout_phase: "enqueue",
        fanout_cursor_registration_id: "",
        fanout_cutoff_at: null,
        fanout_enqueued_count: 0,
        fanout_lease_token: "",
        fanout_lease_until: nowISO,
        fanout_revision: revision,
        fanout_next_attempt_at: null,
        fanout_last_error_code: "",
        fanout_completed_at: null,
        created_at: nowISO,
        updated_at: nowISO,
      })
    );
  } catch (error) {
    // Base44 may commit a create before the transport response is lost. The
    // stable request id lets us re-read and converge instead of duplicating it.
    createError = error;
  }
  const afterCreate = await allMatching(
    input.store,
    { dedupe_key: dedupeKey },
    "created_date",
    10,
  );
  if (!afterCreate.length && createError) throw createError;
  return await convergeRequestRows({
    store: input.store,
    rows: afterCreate,
    payload,
    persist,
  });
}

async function announcementByID(
  store: any,
  id: string,
): Promise<Entity | null> {
  return await one(store, { id });
}

export async function publishDraft(input: {
  store: any;
  announcementID: unknown;
  expectedRevision: unknown;
  now?: Date;
  randomUUID?: () => string;
  persist?: Persist;
}): Promise<Entity> {
  const id = requireAnnouncementID(input.announcementID);
  const expected = requireRevision(input.expectedRevision);
  const current = await announcementByID(input.store, id);
  if (!current) {
    throw new NotificationContractError(
      "Announcement not found.",
      404,
      "not_found",
    );
  }
  if (clean(current.status) === "published") return current;
  if (clean(current.status) !== "draft") {
    throw new NotificationContractError(
      "Announcement cannot be published.",
      409,
      "invalid_state",
    );
  }
  if (clean(current.fanout_revision) !== expected) {
    throw new NotificationContractError(
      "Announcement changed. Reload and retry.",
      409,
      "cas_conflict",
    );
  }
  const now = input.now || new Date();
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  const revision = randomUUID();
  const fanoutState = clean(current.importance) === "important"
    ? "pending"
    : "not_requested";
  const persist = input.persist || directPersist;
  const result: Entity = await persist(() =>
    input.store.updateMany({
      id,
      status: "draft",
      fanout_revision: expected,
    }, {
      $set: {
        status: "published",
        published_at: now.toISOString(),
        fanout_state: fanoutState,
        fanout_phase: "enqueue",
        fanout_cursor_registration_id: "",
        fanout_cutoff_at: now.toISOString(),
        fanout_enqueued_count: 0,
        fanout_revision: revision,
        fanout_next_attempt_at: fanoutState === "pending"
          ? now.toISOString()
          : null,
        updated_at: now.toISOString(),
      },
    })
  );
  if (Number(result?.updated) !== 1) {
    throw new NotificationContractError(
      "Announcement changed. Reload and retry.",
      409,
      "cas_conflict",
    );
  }
  const saved = await announcementByID(input.store, id);
  if (!saved || clean(saved.fanout_revision) !== revision) {
    throw new NotificationContractError(
      "Publish result is ambiguous.",
      503,
      "ambiguous_publish",
    );
  }
  return saved;
}

export async function publishGlobal(input: {
  store: any;
  body: Entity;
  now?: Date;
  randomUUID?: () => string;
  persist?: Persist;
}): Promise<Entity> {
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  const now = input.now || new Date();
  const body = {
    ...input.body,
    request_id: clean(input.body.request_id) || randomUUID(),
    title_en: input.body.title_en ?? input.body.title,
    body_en: input.body.body_en ?? input.body.body,
  };
  const draft = await createDraft({
    store: input.store,
    body,
    now,
    randomUUID,
    persist: input.persist,
  });
  if (clean(draft.status) === "published") return draft;
  if (clean(draft.status) !== "draft") {
    throw new NotificationContractError(
      "Announcement was withdrawn.",
      409,
      "invalid_state",
    );
  }
  return await publishDraft({
    store: input.store,
    announcementID: draft.id,
    expectedRevision: draft.fanout_revision,
    now,
    randomUUID,
    persist: input.persist,
  });
}

export async function withdrawAnnouncement(input: {
  announcementStore: any;
  pushEventStore: any;
  announcementID: unknown;
  expectedRevision: unknown;
  now?: Date;
  randomUUID?: () => string;
  persist?: Persist;
}): Promise<Entity> {
  const id = requireAnnouncementID(input.announcementID);
  const expected = requireRevision(input.expectedRevision);
  const current = await announcementByID(input.announcementStore, id);
  if (!current) {
    throw new NotificationContractError(
      "Announcement not found.",
      404,
      "not_found",
    );
  }
  if (clean(current.status) === "withdrawn") return current;
  if (
    clean(current.status) !== "published" ||
    clean(current.fanout_revision) !== expected
  ) {
    throw new NotificationContractError(
      "Announcement changed. Reload and retry.",
      409,
      "cas_conflict",
    );
  }
  const now = input.now || new Date();
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  const revision = randomUUID();
  const persist = input.persist || directPersist;
  const result: Entity = await persist(() =>
    input.announcementStore.updateMany({
      id,
      status: "published",
      fanout_revision: expected,
    }, {
      $set: {
        status: "withdrawn",
        fanout_state: "cancelled",
        fanout_lease_token: "",
        fanout_lease_until: now.toISOString(),
        fanout_revision: revision,
        fanout_next_attempt_at: null,
        fanout_last_error_code: "withdrawn",
        updated_at: now.toISOString(),
      },
    })
  );
  if (Number(result?.updated) !== 1) {
    throw new NotificationContractError(
      "Announcement changed. Reload and retry.",
      409,
      "cas_conflict",
    );
  }
  const events = await allMatching(input.pushEventStore, {
    event_type: "global_announcement",
    announcement_id: id,
  });
  for (const event of events) {
    if (!["pending", "retry", "processing"].includes(clean(event.state))) {
      continue;
    }
    await persist(() =>
      input.pushEventStore.updateMany({
        id: event.id,
        state: event.state,
        lease_token: event.lease_token,
        revision: event.revision,
      }, {
        $set: {
          state: "cancelled",
          lease_token: "",
          lease_until: now.toISOString(),
          revision: randomUUID(),
          next_attempt_at: null,
          last_error_code: "announcement_withdrawn",
          updated_at: now.toISOString(),
        },
      })
    );
  }
  const saved = await announcementByID(input.announcementStore, id);
  if (!saved) {
    throw new NotificationContractError(
      "Withdraw result is ambiguous.",
      503,
      "ambiguous_withdraw",
    );
  }
  return saved;
}

export function adminItem(announcement: Entity, locale: unknown): InboxItem {
  return globalProjection(announcement, locale);
}
