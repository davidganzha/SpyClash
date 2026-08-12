import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  buildInbox,
  createDraft,
  INBOX_QUERY_LIMITS,
  INBOX_SCOPE_WINDOW_LIMIT,
  inboxUnreadCounts,
  pageInbox,
  publishDraft,
  publishGlobal,
  queryInboxPage,
  unreadCounts,
  upsertReceipt,
} from "./inbox.ts";

type Row = Record<string, any>;

function matches(row: Row, filter: Row): boolean {
  return Object.entries(filter).every(([key, value]) => {
    if (key === "$or") {
      return (value as Row[]).some((branch) => matches(row, branch));
    }
    if (value && typeof value === "object" && !Array.isArray(value)) {
      return Object.entries(value as Row).every(([operator, expected]) => {
        if (operator === "$in") {
          return (expected as unknown[]).includes(row[key]);
        }
        if (operator === "$ne") return row[key] !== expected;
        if (operator === "$gt") return row[key] > expected;
        if (operator === "$lte") return row[key] <= expected;
        if (operator === "$exists") return (key in row) === expected;
        return false;
      });
    }
    return row[key] === value;
  });
}

class Store {
  filterCalls: Row[] = [];
  constructor(public records: Row[] = []) {
    this.records = structuredClone(records);
  }
  async filter(filter: Row, sort = "created_date", limit = 100, skip = 0) {
    this.filterCalls.push({ filter: structuredClone(filter), limit, skip });
    const descending = sort.startsWith("-");
    const field = descending ? sort.slice(1) : sort;
    return this.records.filter((row) => matches(row, filter)).sort(
      (left, right) => {
        const order = String(left[field] ?? "").localeCompare(
          String(right[field] ?? ""),
        );
        return descending ? -order : order;
      },
    ).slice(skip, skip + limit).map((row) => structuredClone(row));
  }
  async create(row: Row) {
    const saved = {
      id: `row-${this.records.length + 1}`,
      ...structuredClone(row),
    };
    this.records.push(saved);
    return structuredClone(saved);
  }
  async update(id: string, patch: Row) {
    const index = this.records.findIndex((row) => row.id === id);
    if (index < 0) throw new Error("missing");
    this.records[index] = { ...this.records[index], ...structuredClone(patch) };
    return structuredClone(this.records[index]);
  }
  async updateMany(filter: Row, update: Row) {
    let updated = 0;
    this.records = this.records.map((row) => {
      if (!Object.entries(filter).every(([key, value]) => row[key] === value)) {
        return row;
      }
      updated += 1;
      return { ...row, ...structuredClone(update.$set || {}) };
    });
    return { updated };
  }
  async delete(id: string) {
    this.records = this.records.filter((row) => row.id !== id);
  }
}

function base44(entities: Record<string, Store>) {
  return { asServiceRole: { entities } };
}

Deno.test("global and failed-delivery personal items remain safely visible", async () => {
  const entities = {
    NotificationAnnouncement: new Store([{
      id: "announcement-1",
      status: "published",
      topic: "release",
      importance: "quiet",
      title_en: "Build 29",
      body_en: "Swipe navigation is ready.",
      title_uk: "Збірка 29",
      body_uk: "Навігація свайпами готова.",
      action_deep_link: "spyclash://notifications?id=announcement-1",
      published_at: "2026-07-27T12:00:00.000Z",
      expires_at: "2026-08-27T12:00:00.000Z",
    }]),
    PushNotificationEvent: new Store([
      {
        id: "event-1",
        state: "failed",
        event_type: "friend_request",
        source_event_id: "friend-source-1",
        actor_user_id: "actor",
        recipient_user_id: "recipient",
        created_at: "2026-07-27T11:00:00.000Z",
        inbox_kind: "friend_request",
        inbox_importance: "important",
        inbox_title_en: "New friend request",
        inbox_body_en: "Red Raven wants to connect.",
        inbox_title_ru: "Новый запрос в друзья",
        inbox_body_ru: "Red Raven хочет добавить вас в друзья.",
        inbox_title_es: "Nueva solicitud de amistad",
        inbox_body_es: "Red Raven quiere conectar contigo.",
        inbox_title_uk: "Новий запит у друзі",
        inbox_body_uk: "Red Raven хоче додати вас у друзі.",
        inbox_action_deep_link: "spyclash://community/requests",
        inbox_published_at: "2026-07-27T11:00:00.000Z",
        inbox_projection_version: 1,
        inbox_visible: true,
        inbox_committed_at: "2026-07-27T11:00:01.000Z",
      },
      {
        id: "game-start-1",
        state: "delivered",
        event_type: "game_started",
        recipient_user_id: "recipient",
        inbox_kind: "game_started",
        inbox_importance: "important",
        inbox_title_en: "Mission started",
        inbox_body_en: "Your SpyClash game is now live.",
        inbox_published_at: "2026-07-27T11:30:00.000Z",
        inbox_projection_version: 1,
        inbox_visible: true,
        inbox_committed_at: "2026-07-27T11:30:01.000Z",
      },
    ]),
    NotificationReadReceipt: new Store(),
    Friendship: new Store([{
      request_event_id: "friend-source-1",
      requester_id: "actor",
      addressee_id: "recipient",
      status: "pending",
    }]),
    RoomInvite: new Store(),
    GameRoom: new Store(),
    User: new Store([{ id: "actor", display_name: "Red Raven" }]),
  };
  const app = base44(entities);
  const items = await buildInbox({
    base44: app,
    userID: "recipient",
    locale: "en",
    now: new Date("2026-07-28T00:00:00.000Z"),
  });
  assertEquals(items.map((item) => item.id), [
    "global:announcement-1",
    "personal:event-1",
  ]);
  assertEquals(items[1].body, "Red Raven wants to connect.");
  assertEquals(JSON.stringify(items).includes("actor_user_id"), false);
  assertEquals(unreadCounts(items), { global: 1, personal: 1, total: 2 });

  const ukrainianItems = await buildInbox({
    base44: app,
    userID: "recipient",
    locale: "uk-UA",
    now: new Date("2026-07-28T00:00:00.000Z"),
  });
  assertEquals(ukrainianItems[0].title, "Збірка 29");
  assertEquals(ukrainianItems[1].body, "Red Raven хоче додати вас у друзі.");

  // Materialized rows do not perform source N+1 reads. Source cancellation is
  // performed atomically by communityAction when a request is blocked.
  entities.Friendship.records[0].status = "blocked";
  const afterBlock = await buildInbox({
    base44: app,
    userID: "recipient",
    locale: "en",
    now: new Date("2026-07-28T00:00:00.000Z"),
  });
  assertEquals(afterBlock.map((item) => item.id), [
    "global:announcement-1",
    "personal:event-1",
  ]);
  assertEquals(entities.Friendship.filterCalls.length, 0);
  assertEquals(entities.User.filterCalls.length, 0);
});

Deno.test("irrelevant and uncommitted rows cannot evict visible personal inbox items", async () => {
  const irrelevantEvents = Array.from({ length: 260 }, (_, index) => ({
    id: `irrelevant-${index}`,
    state: index % 2 ? "cancelled" : "failed",
    event_type: index % 3 ? "friend_request" : "global_announcement",
    recipient_user_id: "recipient",
    inbox_visible: false,
    created_at: `2026-07-27T10:${String(index % 60).padStart(2, "0")}:00.000Z`,
  }));
  const visibleEvents = Array.from({ length: 3 }, (_, index) => ({
    id: `visible-${index}`,
    state: "failed",
    event_type: "friend_request",
    recipient_user_id: "recipient",
    inbox_kind: "friend_request",
    inbox_importance: "important",
    inbox_title_en: `Visible ${index}`,
    inbox_body_en: "Committed",
    inbox_action_deep_link: "spyclash://community/requests",
    inbox_published_at: `2026-07-27T11:0${index}:00.000Z`,
    inbox_projection_version: 1,
    inbox_visible: true,
    inbox_committed_at: `2026-07-27T11:0${index}:01.000Z`,
    created_at: `2026-07-27T11:0${index}:00.000Z`,
  }));
  const entities = {
    NotificationAnnouncement: new Store(),
    PushNotificationEvent: new Store([...irrelevantEvents, ...visibleEvents]),
    NotificationReadReceipt: new Store(),
    Friendship: new Store(),
    RoomInvite: new Store(),
    GameRoom: new Store(),
    User: new Store([{ id: "actor", display_name: "Red Raven" }]),
  };
  const items = await buildInbox({
    base44: base44(entities),
    userID: "recipient",
    locale: "en",
    now: new Date("2026-07-28T00:00:00.000Z"),
  });
  assertEquals(items.map((item) => item.id), [
    "personal:visible-2",
    "personal:visible-1",
    "personal:visible-0",
  ]);
  assertEquals(entities.Friendship.filterCalls.length, 0);
  assertEquals(
    entities.PushNotificationEvent.filterCalls.every((call) =>
      call.limit <= INBOX_SCOPE_WINDOW_LIMIT + 2
    ),
    true,
  );
});

Deno.test("receipt watermark and cursor pagination are deterministic", async () => {
  const receiptStore = new Store();
  await upsertReceipt({
    store: receiptStore,
    userID: "recipient",
    key: "__all__:global",
    readAt: "2026-07-27T13:00:00.000Z",
    persist: async (writer) => await writer(),
  });
  const entities = {
    NotificationAnnouncement: new Store([{
      id: "one",
      status: "published",
      topic: "developer",
      importance: "quiet",
      title_en: "One",
      body_en: "Body",
      published_at: "2026-07-27T12:00:00.000Z",
      expires_at: "2026-08-27T12:00:00.000Z",
    }, {
      id: "two",
      status: "published",
      topic: "developer",
      importance: "quiet",
      title_en: "Two",
      body_en: "Body",
      published_at: "2026-07-27T11:00:00.000Z",
      expires_at: "2026-08-27T12:00:00.000Z",
    }]),
    PushNotificationEvent: new Store(),
    NotificationReadReceipt: receiptStore,
    Friendship: new Store(),
    RoomInvite: new Store(),
    GameRoom: new Store(),
    User: new Store(),
  };
  const items = await buildInbox({
    base44: base44(entities),
    userID: "recipient",
    locale: "en",
    now: new Date("2026-07-28T00:00:00.000Z"),
  });
  assertEquals(items.every((item) => Boolean(item.read_at)), true);
  const first = pageInbox({ items, scope: "global", limit: 1, cursor: null });
  const second = pageInbox({
    items,
    scope: "global",
    limit: 1,
    cursor: first.next_cursor,
  });
  assertEquals(first.items[0].id, "global:one");
  assertEquals(second.items[0].id, "global:two");
});

Deno.test("bounded snapshot pagination preserves keyset order under churn", async () => {
  const publishedBase = Date.parse("2026-07-27T12:00:00.000Z");
  const announcements = Array.from({ length: 240 }, (_, index) => ({
    id: `announcement-${String(index).padStart(3, "0")}`,
    status: "published",
    topic: "developer",
    importance: "quiet",
    title_en: `Announcement ${index}`,
    body_en: "Body",
    published_at: new Date(publishedBase + index * 1_000).toISOString(),
    expires_at: "2026-08-27T12:00:00.000Z",
  }));
  const announcementStore = new Store(announcements);
  const receiptStore = new Store();
  const entities = {
    NotificationAnnouncement: announcementStore,
    PushNotificationEvent: new Store(),
    NotificationReadReceipt: receiptStore,
  };
  const app = base44(entities);
  const seen: string[] = [];
  let cursor: string | null = null;
  let pageNumber = 0;
  do {
    const page = await queryInboxPage({
      base44: app,
      userID: "recipient",
      locale: "en",
      scope: "global",
      cursor,
      limit: 37,
      now: new Date("2026-07-28T00:00:00.000Z"),
    });
    seen.push(...page.items.map((item) => item.id));
    cursor = page.next_cursor;
    if (pageNumber === 0) {
      // A row published after the first page's boundary must not shift the
      // continuation or duplicate/evict any row already in the snapshot tail.
      announcementStore.records.push({
        id: "announcement-churn",
        status: "published",
        topic: "developer",
        importance: "quiet",
        title_en: "Inserted during pagination",
        body_en: "Body",
        published_at: "2026-07-27T23:59:59.000Z",
        expires_at: "2026-08-27T12:00:00.000Z",
      });
    }
    pageNumber += 1;
  } while (cursor);

  assertEquals(seen.length, 240);
  assertEquals(new Set(seen).size, 240);
  assertEquals(seen.includes("global:announcement-churn"), false);
  assertEquals(
    announcementStore.filterCalls.some((call) =>
      JSON.stringify(call.filter).includes('"$lte"')
    ),
    true,
  );
  assertEquals(
    announcementStore.filterCalls.every((call) =>
      call.limit <= INBOX_SCOPE_WINDOW_LIMIT + 2 && call.skip === 0
    ),
    true,
  );
});

Deno.test("timestamp ties continue by ascending id keyset", async () => {
  const announcements = Array.from({ length: 120 }, (_, index) => ({
    id: `tie-${String(index).padStart(3, "0")}`,
    status: "published",
    topic: "developer",
    importance: "quiet",
    title_en: `Tie ${index}`,
    body_en: "Body",
    published_at: "2026-07-27T12:00:00.000Z",
    expires_at: "2026-08-27T12:00:00.000Z",
  }));
  const app = base44({
    NotificationAnnouncement: new Store(announcements.reverse()),
    PushNotificationEvent: new Store(),
    NotificationReadReceipt: new Store(),
  });
  const seen: string[] = [];
  let cursor: string | null = null;
  do {
    const page = await queryInboxPage({
      base44: app,
      userID: "recipient",
      locale: "en",
      scope: "global",
      cursor,
      limit: 17,
      now: new Date("2026-07-28T00:00:00.000Z"),
    });
    seen.push(...page.items.map((item) => item.id));
    cursor = page.next_cursor;
  } while (cursor);
  assertEquals(seen.length, 120);
  assertEquals(new Set(seen).size, 120);
  assertEquals(seen[0], "global:tie-000");
  assertEquals(seen.at(-1), "global:tie-119");
});

Deno.test("page-scoped receipt query cannot be evicted by 301 stale receipts", async () => {
  const itemID = "announcement-read";
  const stale = Array.from({ length: 301 }, (_, index) => ({
    id: `stale-${index}`,
    user_id: "recipient",
    notification_key: `global:stale-${index}`,
    read_at: new Date(
      Date.parse("2026-07-27T14:00:00.000Z") + index,
    ).toISOString(),
  }));
  const relevant = {
    id: "relevant-old-receipt",
    user_id: "recipient",
    notification_key: `global:${itemID}`,
    read_at: "2026-07-27T13:00:00.000Z",
  };
  const receiptStore = new Store([...stale, relevant]);
  const entities = {
    NotificationAnnouncement: new Store([{
      id: itemID,
      status: "published",
      topic: "developer",
      importance: "quiet",
      title_en: "Read item",
      body_en: "Body",
      published_at: "2026-07-27T12:00:00.000Z",
      expires_at: "2026-08-27T12:00:00.000Z",
    }]),
    PushNotificationEvent: new Store(),
    NotificationReadReceipt: receiptStore,
  };
  const app = base44(entities);
  const page = await queryInboxPage({
    base44: app,
    userID: "recipient",
    locale: "en",
    scope: "global",
    cursor: null,
    limit: 30,
    now: new Date("2026-07-28T00:00:00.000Z"),
  });
  assertEquals(page.items[0].read_at, relevant.read_at);
  assertEquals(
    await inboxUnreadCounts({
      base44: app,
      userID: "recipient",
      locale: "en",
      now: new Date("2026-07-28T00:00:00.000Z"),
    }),
    { global: 0, personal: 0, total: 0 },
  );
  assertEquals(
    receiptStore.filterCalls.every((call) =>
      "$in" in (call.filter.notification_key || {})
    ),
    true,
  );
  assertEquals(
    receiptStore.filterCalls.some((call) =>
      (call.filter.notification_key.$in as string[]).includes(
        `global:${itemID}`,
      )
    ),
    true,
  );
});

Deno.test("unread scan counts every retained row beyond source page size", async () => {
  const base = Date.parse("2026-07-27T12:00:00.000Z");
  const globals = Array.from({ length: 135 }, (_, index) => ({
    id: `global-${String(index).padStart(3, "0")}`,
    status: "published",
    topic: "developer",
    importance: "quiet",
    title_en: `Global ${index}`,
    body_en: "Body",
    published_at: new Date(base + index * 1_000).toISOString(),
    expires_at: "2026-08-27T12:00:00.000Z",
  }));
  const personal = Array.from({ length: 145 }, (_, index) => ({
    id: `personal-${String(index).padStart(3, "0")}`,
    state: "failed",
    event_type: "friend_request",
    recipient_user_id: "recipient",
    inbox_kind: "friend_request",
    inbox_importance: "important",
    inbox_title_en: `Personal ${index}`,
    inbox_body_en: "Body",
    inbox_published_at: new Date(base + index * 1_000 + 500).toISOString(),
    inbox_projection_version: 1,
    inbox_visible: true,
    inbox_committed_at: "2026-07-27T13:00:00.000Z",
  }));
  const counts = await inboxUnreadCounts({
    base44: base44({
      NotificationAnnouncement: new Store(globals),
      PushNotificationEvent: new Store(personal),
      NotificationReadReceipt: new Store(),
    }),
    userID: "recipient",
    locale: "en",
    now: new Date("2026-07-28T00:00:00.000Z"),
  });
  assertEquals(counts, { global: 135, personal: 145, total: 280 });
});

Deno.test("global and personal windows are independently capped at 500", async () => {
  const base = Date.parse("2026-07-27T01:00:00.000Z");
  const globals = Array.from({ length: 620 }, (_, index) => ({
    id: `global-${String(index).padStart(3, "0")}`,
    status: "published",
    topic: "developer",
    importance: "quiet",
    title_en: `Global ${index}`,
    body_en: "Body",
    published_at: new Date(base + index * 1_000).toISOString(),
    expires_at: "2026-08-27T12:00:00.000Z",
  }));
  const personal = Array.from({ length: 640 }, (_, index) => ({
    id: `personal-${String(index).padStart(3, "0")}`,
    state: "failed",
    event_type: "friend_request",
    recipient_user_id: "recipient",
    inbox_kind: "friend_request",
    inbox_importance: "important",
    inbox_title_en: `Personal ${index}`,
    inbox_body_en: "Body",
    inbox_published_at: new Date(base + index * 1_000 + 500).toISOString(),
    inbox_projection_version: 1,
    inbox_visible: true,
    inbox_committed_at: "2026-07-27T12:00:00.000Z",
  }));
  const announcementStore = new Store(globals);
  const personalStore = new Store(personal);
  const app = base44({
    NotificationAnnouncement: announcementStore,
    PushNotificationEvent: personalStore,
    NotificationReadReceipt: new Store(),
  });

  const items = await buildInbox({
    base44: app,
    userID: "recipient",
    locale: "en",
    now: new Date("2026-07-28T00:00:00.000Z"),
  });
  assertEquals(items.filter((item) => item.scope === "global").length, 500);
  assertEquals(items.filter((item) => item.scope === "personal").length, 500);
  assertEquals(items.some((item) => item.id === "global:global-119"), false);
  assertEquals(items.some((item) => item.id === "global:global-120"), true);
  assertEquals(
    items.some((item) => item.id === "personal:personal-139"),
    false,
  );
  assertEquals(
    items.some((item) => item.id === "personal:personal-140"),
    true,
  );
  assertEquals(unreadCounts(items), {
    global: 500,
    personal: 500,
    total: 1_000,
  });
  assertEquals(
    [...announcementStore.filterCalls, ...personalStore.filterCalls].every(
      (call) => call.limit <= INBOX_SCOPE_WINDOW_LIMIT + 2 && call.skip === 0,
    ),
    true,
  );
});

Deno.test("opaque pagination cursor stops at the 500-item scope window", async () => {
  const base = Date.parse("2026-07-27T01:00:00.000Z");
  const announcementStore = new Store(
    Array.from({ length: 620 }, (_, index) => ({
      id: `announcement-${String(index).padStart(3, "0")}`,
      status: "published",
      topic: "developer",
      importance: "quiet",
      title_en: `Announcement ${index}`,
      body_en: "Body",
      published_at: new Date(base + index * 1_000).toISOString(),
      expires_at: "2026-08-27T12:00:00.000Z",
    })),
  );
  const app = base44({
    NotificationAnnouncement: announcementStore,
    PushNotificationEvent: new Store(),
    NotificationReadReceipt: new Store(),
  });
  const seen: string[] = [];
  let cursor: string | null = null;
  do {
    const page = await queryInboxPage({
      base44: app,
      userID: "recipient",
      locale: "en",
      scope: "global",
      cursor,
      limit: 73,
      now: new Date("2026-07-28T00:00:00.000Z"),
    });
    seen.push(...page.items.map((item) => item.id));
    assertEquals(page.unread, { global: 500, personal: 0, total: 500 });
    cursor = page.next_cursor;
  } while (cursor);

  assertEquals(seen.length, INBOX_SCOPE_WINDOW_LIMIT);
  assertEquals(new Set(seen).size, INBOX_SCOPE_WINDOW_LIMIT);
  assertEquals(seen[0], "global:announcement-619");
  assertEquals(seen.at(-1), "global:announcement-120");
  assertEquals(seen.includes("global:announcement-119"), false);
});

Deno.test("receipt cardinality overflow fails closed with bounded queries", async () => {
  const key = "global:announcement";
  const receiptStore = new Store(
    Array.from(
      { length: INBOX_QUERY_LIMITS.receiptDuplicatesPerKey + 1 },
      (_, index) => ({
        id: `receipt-${index}`,
        user_id: "recipient",
        notification_key: key,
        read_at: `2026-07-27T12:00:0${index}.000Z`,
      }),
    ),
  );
  const app = base44({
    NotificationAnnouncement: new Store([{
      id: "announcement",
      status: "published",
      topic: "developer",
      importance: "quiet",
      title_en: "Announcement",
      body_en: "Body",
      published_at: "2026-07-27T12:00:00.000Z",
      expires_at: "2026-08-27T12:00:00.000Z",
    }]),
    PushNotificationEvent: new Store(),
    NotificationReadReceipt: receiptStore,
  });
  await assertRejects(
    () =>
      queryInboxPage({
        base44: app,
        userID: "recipient",
        locale: "en",
        scope: "global",
        cursor: null,
        limit: 30,
        now: new Date("2026-07-28T00:00:00.000Z"),
      }),
    Error,
    "Notification receipts require repair.",
  );
  assertEquals(receiptStore.filterCalls.length <= 2, true);
  assertEquals(
    receiptStore.filterCalls.every((call) =>
      call.limit <= INBOX_QUERY_LIMITS.receiptKeys *
              INBOX_QUERY_LIMITS.receiptDuplicatesPerKey + 1 && call.skip === 0
    ),
    true,
  );
});

Deno.test("draft and publish transitions are idempotent and importance controls fanout", async () => {
  const store = new Store();
  const body = {
    request_id: "123e4567-e89b-42d3-a456-426614174000",
    topic: "release",
    importance: "important",
    title_en: "Build 29",
    body_en: "Ready",
  };
  const draft = await createDraft({
    store,
    body,
    now: new Date("2026-07-27T12:00:00.000Z"),
    randomUUID: () => "revision-one",
  });
  assertEquals(
    (await createDraft({
      store,
      body,
      now: new Date("2026-07-27T12:00:00.000Z"),
    })).id,
    draft.id,
  );
  await assertRejects(() =>
    createDraft({
      store,
      body: { ...body, body_en: "Different" },
      now: new Date("2026-07-27T12:00:00.000Z"),
    })
  );
  const published = await publishDraft({
    store,
    announcementID: draft.id,
    expectedRevision: "revision-one",
    now: new Date("2026-07-27T12:01:00.000Z"),
    randomUUID: () => "revision-two",
  });
  assertEquals(published.status, "published");
  assertEquals(published.fanout_state, "pending");

  const quiet = await publishGlobal({
    store,
    body: {
      request_id: "123e4567-e89b-42d3-a456-426614174001",
      title: "Quiet",
      body: "Inbox only",
      importance: "quiet",
    },
    now: new Date("2026-07-27T12:02:00.000Z"),
  });
  assertEquals(quiet.fanout_state, "not_requested");
  const quietRetry = await publishGlobal({
    store,
    body: {
      request_id: "123e4567-e89b-42d3-a456-426614174001",
      title: "Quiet",
      body: "Inbox only",
      importance: "quiet",
    },
    now: new Date("2026-07-27T12:03:00.000Z"),
  });
  assertEquals(quietRetry.id, quiet.id);
  assertEquals(
    store.records.filter((row) =>
      row.dedupe_key ===
        "notification:123e4567-e89b-42d3-a456-426614174001"
    ).length,
    1,
  );
});

Deno.test("draft create converges when the committed response is lost", async () => {
  class LostResponseStore extends Store {
    override async create(row: Row): Promise<{ id: string }> {
      await super.create(row);
      throw new Error("transport_lost_after_commit");
    }
  }
  const store = new LostResponseStore();
  const draft = await createDraft({
    store,
    body: {
      request_id: "123e4567-e89b-42d3-a456-426614174099",
      title_en: "Committed",
      body_en: "Recovered",
      importance: "quiet",
    },
    now: new Date("2026-07-27T12:00:00.000Z"),
    randomUUID: () => "lost-response-revision",
  });
  assertEquals(draft.status, "draft");
  assertEquals(store.records.length, 1);
});
