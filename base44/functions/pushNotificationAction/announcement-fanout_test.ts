import { assertEquals } from "jsr:@std/assert@1";
import {
  announcementFanoutDue,
  drainAnnouncementFanout,
  FANOUT_MAX_FAILED_VERIFY_SWEEPS,
  fanoutAnnouncement,
} from "./announcement-fanout.ts";

type Row = Record<string, any>;

function matches(row: Row, filter: Row): boolean {
  return Object.entries(filter).every(([key, value]) => {
    if (key === "$or") {
      return (value as Row[]).some((branch) => matches(row, branch));
    }
    if (value && typeof value === "object" && !Array.isArray(value)) {
      const operators = value as Row;
      return Object.entries(operators).every(([operator, expected]) => {
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
  filterCalls: Array<
    { filter: Row; sort: string; limit: number; skip: number }
  > = [];
  constructor(public records: Row[] = []) {
    this.records = structuredClone(records);
  }
  async filter(filter: Row, sort = "created_date", limit = 100, skip = 0) {
    this.filterCalls.push({
      filter: structuredClone(filter),
      sort,
      limit,
      skip,
    });
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

type EventFaultOptions = {
  shouldFailFilter?: (dedupeKey: string, attempt: number) => boolean;
  shouldLoseCreateResponse?: (row: Row, attempt: number) => boolean;
  onFault?: () => void;
};

class FaultingEventStore extends Store {
  dedupeFilterAttempts = 0;
  createAttempts = 0;

  constructor(
    records: Row[] = [],
    private readonly faults: EventFaultOptions = {},
  ) {
    super(records);
  }

  override async filter(
    filter: Row,
    sort = "created_date",
    limit = 100,
    skip = 0,
  ) {
    const dedupeKey = String(filter.dedupe_key ?? "");
    if (dedupeKey) {
      const attempt = this.dedupeFilterAttempts;
      this.dedupeFilterAttempts += 1;
      if (this.faults.shouldFailFilter?.(dedupeKey, attempt)) {
        this.faults.onFault?.();
        throw new Error("injected_dedupe_filter_failure");
      }
    }
    return await super.filter(filter, sort, limit, skip);
  }

  override async create(row: Row) {
    const saved = await super.create(row);
    const attempt = this.createAttempts;
    this.createAttempts += 1;
    if (this.faults.shouldLoseCreateResponse?.(row, attempt)) {
      this.faults.onFault?.();
      throw new Error("injected_lost_create_response");
    }
    return saved;
  }
}

const FIXED_NOW = new Date("2026-07-27T12:00:00.000Z");

function announcementFixture(id: string, overrides: Row = {}): Row {
  return {
    id,
    status: "published",
    importance: "important",
    published_at: FIXED_NOW.toISOString(),
    expires_at: "2099-01-01T00:00:00.000Z",
    fanout_state: "pending",
    fanout_attempt_count: 0,
    fanout_phase: "enqueue",
    fanout_cursor_registration_id: "",
    fanout_cutoff_at: FIXED_NOW.toISOString(),
    fanout_enqueued_count: 0,
    fanout_sweep_failed: false,
    fanout_verify_failure_passes: 0,
    fanout_last_failed_registration_id: "",
    fanout_lease_token: "",
    fanout_lease_until: FIXED_NOW.toISOString(),
    fanout_revision: `revision-${id}`,
    updated_at: FIXED_NOW.toISOString(),
    ...overrides,
  };
}

function registrationFixture(
  id: string,
  userID: string,
  overrides: Row = {},
): Row {
  return {
    id,
    user_id: userID,
    status: "active",
    alert_authorized: true,
    announcements_enabled: true,
    created_date: "2026-07-27T11:00:00.000Z",
    ...overrides,
  };
}

function fanoutApp(input: {
  announcements: Row[];
  registrations: Row[];
  events?: Store;
}) {
  return {
    announcementStore: new Store(input.announcements),
    registrationStore: new Store(input.registrations),
    eventStore: input.events || new Store(),
  };
}

function base44For(stores: ReturnType<typeof fanoutApp>) {
  return {
    asServiceRole: {
      entities: {
        NotificationAnnouncement: stores.announcementStore,
        PushDeviceRegistration: stores.registrationStore,
        PushNotificationEvent: stores.eventStore,
        BillingIdentityLifecycle: new Store(),
      },
    },
  };
}

async function fanoutPass(
  base44: ReturnType<typeof base44For>,
  announcementStore: Store,
  pass: number,
) {
  return await fanoutAnnouncement({
    base44,
    announcement: structuredClone(announcementStore.records[0]),
    deadlineEpochMs: Date.now() + 30_000,
    now: new Date(FIXED_NOW.getTime() + pass * 120_000),
  });
}

Deno.test("important announcement fanout is one event per user and retry-idempotent", async () => {
  const announcement = {
    id: "announcement-1",
    status: "published",
    importance: "important",
    published_at: new Date().toISOString(),
    expires_at: "2099-01-01T00:00:00.000Z",
    fanout_state: "pending",
    fanout_attempt_count: 0,
    fanout_lease_token: "",
    fanout_lease_until: new Date().toISOString(),
    fanout_revision: "revision-1",
  };
  const announcementStore = new Store([announcement]);
  const eventStore = new Store();
  const app = {
    asServiceRole: {
      entities: {
        NotificationAnnouncement: announcementStore,
        PushDeviceRegistration: new Store([{
          id: "device-1",
          user_id: "user-1",
          status: "active",
          alert_authorized: true,
          announcements_enabled: true,
          created_date: "2026-01-01T00:00:00.000Z",
        }, {
          id: "device-2",
          user_id: "user-1",
          status: "active",
          alert_authorized: true,
          announcements_enabled: true,
          created_date: "2026-01-01T00:00:00.000Z",
        }, {
          id: "device-disabled",
          user_id: "user-2",
          status: "active",
          alert_authorized: true,
          announcements_enabled: false,
          created_date: "2026-01-01T00:00:00.000Z",
        }]),
        PushNotificationEvent: eventStore,
        BillingIdentityLifecycle: new Store(),
      },
    },
  };
  const first = await fanoutAnnouncement({
    base44: app,
    announcement,
    deadlineEpochMs: Date.now() + 10_000,
  });
  assertEquals(first.state, "retry");
  assertEquals(first.phase, "verify");
  assertEquals(first.created, 1);
  assertEquals(eventStore.records.length, 1);
  assertEquals(eventStore.records[0].event_type, "global_announcement");

  const second = await fanoutAnnouncement({
    base44: app,
    announcement: structuredClone(announcementStore.records[0]),
    deadlineEpochMs: Date.now() + 10_000,
    now: new Date(Date.now() + 60_000),
  });
  assertEquals(second.state, "complete");
  assertEquals(second.created, 0);
  assertEquals(second.existing, 1);
  assertEquals(eventStore.records.length, 1);
  assertEquals(
    announcementFanoutDue({ ...announcement, importance: "quiet" }),
    false,
  );
});

Deno.test("durable cursor and verification reach the tail beyond one batch", async () => {
  const now = new Date("2026-07-27T12:00:00.000Z");
  const announcement = {
    id: "announcement-tail",
    status: "published",
    importance: "important",
    published_at: now.toISOString(),
    expires_at: "2099-01-01T00:00:00.000Z",
    fanout_state: "pending",
    fanout_attempt_count: 0,
    fanout_phase: "enqueue",
    fanout_cursor_registration_id: "",
    fanout_cutoff_at: now.toISOString(),
    fanout_enqueued_count: 0,
    fanout_lease_token: "",
    fanout_lease_until: now.toISOString(),
    fanout_revision: "revision-tail",
  };
  const announcementStore = new Store([announcement]);
  const registrations = Array.from({ length: 130 }, (_, index) => ({
    id: `device-${String(index).padStart(3, "0")}`,
    user_id: `user-${String(index).padStart(3, "0")}`,
    status: "active",
    alert_authorized: true,
    announcements_enabled: true,
    created_date: "2026-07-27T11:00:00.000Z",
  }));
  const eventStore = new Store();
  const app = {
    asServiceRole: {
      entities: {
        NotificationAnnouncement: announcementStore,
        PushDeviceRegistration: new Store(registrations),
        PushNotificationEvent: eventStore,
        BillingIdentityLifecycle: new Store(),
      },
    },
  };
  let result: Row = {};
  for (let pass = 0; pass < 8; pass += 1) {
    result = await fanoutAnnouncement({
      base44: app,
      announcement: structuredClone(announcementStore.records[0]),
      deadlineEpochMs: Date.now() + 30_000,
      now: new Date(now.getTime() + pass * 60_000),
    });
    if (pass === 0) {
      assertEquals(
        announcementStore.records[0].fanout_cursor_registration_id,
        "device-063",
      );
      assertEquals(eventStore.records.length, 64);
    }
    if (result.state === "complete") break;
  }
  assertEquals(result.state, "complete");
  assertEquals(announcementStore.records[0].fanout_phase, "verify");
  assertEquals(
    announcementStore.records[0].fanout_cursor_registration_id,
    "device-129",
  );
  assertEquals(eventStore.records.length, 130);
  assertEquals(
    new Set(eventStore.records.map((row) => row.dedupe_key)).size,
    130,
  );
  const registrationQueries = app.asServiceRole.entities.PushDeviceRegistration
    .filterCalls.filter((call) => call.limit === 65);
  assertEquals(registrationQueries.length, 6);
  assertEquals(
    registrationQueries.every((call) => call.skip === 0),
    true,
  );
});

Deno.test("expired deadline checkpoints without scanning the audience", async () => {
  const now = new Date("2026-07-27T12:00:00.000Z");
  const announcement = {
    id: "announcement-deadline",
    status: "published",
    importance: "important",
    published_at: now.toISOString(),
    expires_at: "2099-01-01T00:00:00.000Z",
    fanout_state: "pending",
    fanout_attempt_count: 0,
    fanout_phase: "enqueue",
    fanout_cursor_registration_id: "",
    fanout_cutoff_at: now.toISOString(),
    fanout_lease_token: "",
    fanout_lease_until: now.toISOString(),
    fanout_revision: "deadline-revision",
  };
  const announcementStore = new Store([announcement]);
  const registrationStore = new Store(
    Array.from({ length: 5_000 }, (_, index) => ({
      id: `device-${String(index).padStart(5, "0")}`,
      user_id: `user-${index}`,
      status: "active",
      alert_authorized: true,
      announcements_enabled: true,
      created_date: "2026-07-27T11:00:00.000Z",
    })),
  );
  const app = {
    asServiceRole: {
      entities: {
        NotificationAnnouncement: announcementStore,
        PushDeviceRegistration: registrationStore,
        PushNotificationEvent: new Store(),
        BillingIdentityLifecycle: new Store(),
      },
    },
  };
  const result = await fanoutAnnouncement({
    base44: app,
    announcement,
    deadlineEpochMs: Date.now() - 1,
    now,
  });
  assertEquals(result.state, "retry");
  assertEquals(result.cursor_registration_id, "");
  assertEquals(registrationStore.filterCalls.length, 0);
});

Deno.test("one drain fairly advances multiple important announcements", async () => {
  const now = new Date("2026-07-27T12:00:00.000Z");
  const announcements = Array.from({ length: 6 }, (_, index) => ({
    id: `announcement-${index}`,
    status: "published",
    importance: "important",
    published_at: new Date(now.getTime() + index * 1_000).toISOString(),
    expires_at: "2099-01-01T00:00:00.000Z",
    fanout_state: "pending",
    fanout_attempt_count: 0,
    fanout_phase: "enqueue",
    fanout_cursor_registration_id: "",
    fanout_cutoff_at: new Date(now.getTime() + index * 1_000).toISOString(),
    fanout_lease_token: "",
    fanout_lease_until: now.toISOString(),
    fanout_revision: `revision-${index}`,
    updated_at: new Date(now.getTime() + index * 1_000).toISOString(),
  }));
  const announcementStore = new Store(announcements);
  const eventStore = new Store();
  const app = {
    asServiceRole: {
      entities: {
        NotificationAnnouncement: announcementStore,
        PushDeviceRegistration: new Store([{
          id: "device-1",
          user_id: "user-1",
          status: "active",
          alert_authorized: true,
          announcements_enabled: true,
          created_date: "2026-07-27T11:00:00.000Z",
        }]),
        PushNotificationEvent: eventStore,
        BillingIdentityLifecycle: new Store(),
      },
    },
  };
  const first = await drainAnnouncementFanout({
    base44: app,
    deadlineEpochMs: Date.now() + 10_000,
  });
  const second = await drainAnnouncementFanout({
    base44: app,
    deadlineEpochMs: Date.now() + 10_000,
  });
  assertEquals(first.length, 4);
  assertEquals(second.length, 2);
  assertEquals(
    new Set(eventStore.records.map((row) => row.announcement_id)),
    new Set(announcements.map((announcement) => announcement.id)),
  );
});

Deno.test("a permanent first registration failure cannot starve later recipients", async () => {
  const announcement = announcementFixture("announcement-poison-audience");
  const registrations = Array.from(
    { length: 130 },
    (_, index) =>
      registrationFixture(
        `device-${String(index).padStart(3, "0")}`,
        `user-${String(index).padStart(3, "0")}`,
      ),
  );
  const eventStore = new FaultingEventStore([], {
    shouldFailFilter: (dedupeKey) => dedupeKey.endsWith(":user-000"),
  });
  const stores = fanoutApp({
    announcements: [announcement],
    registrations,
    events: eventStore,
  });
  const base44 = base44For(stores);

  let result: Row = {};
  for (let pass = 0; pass < 24; pass += 1) {
    result = await fanoutPass(base44, stores.announcementStore, pass);
    if (result.state === "failed") break;
  }

  assertEquals(result.state, "failed");
  assertEquals(
    result.verify_failure_passes,
    FANOUT_MAX_FAILED_VERIFY_SWEEPS,
  );
  assertEquals(result.cursor_registration_id, "device-129");
  assertEquals(result.last_failed_registration_id, "device-000");
  assertEquals(result.sweep_failed, true);
  assertEquals(eventStore.records.length, 129);
  assertEquals(
    eventStore.records.some((row) => row.recipient_user_id === "user-129"),
    true,
  );
  assertEquals(
    eventStore.records.some((row) => row.recipient_user_id === "user-000"),
    false,
  );
});

Deno.test("lost create response is reconciled by the verification sweep", async () => {
  const announcement = announcementFixture("announcement-lost-response");
  const eventStore = new FaultingEventStore([], {
    shouldLoseCreateResponse: (_row, attempt) => attempt === 0,
  });
  const stores = fanoutApp({
    announcements: [announcement],
    registrations: [registrationFixture("device-000", "user-000")],
    events: eventStore,
  });
  const base44 = base44For(stores);

  const first = await fanoutPass(base44, stores.announcementStore, 0);
  assertEquals(first.state, "retry");
  assertEquals(first.phase, "verify");
  assertEquals(first.failures, 1);
  assertEquals(first.created, 0);
  assertEquals(eventStore.records.length, 1);

  const second = await fanoutPass(base44, stores.announcementStore, 1);
  assertEquals(second.state, "complete");
  assertEquals(second.existing, 1);
  assertEquals(second.verify_failure_passes, 0);
  assertEquals(eventStore.records.length, 1);
});

Deno.test("a transient poison row recovers only after a clean verification sweep", async () => {
  const announcement = announcementFixture("announcement-transient");
  const eventStore = new FaultingEventStore([], {
    shouldFailFilter: (_dedupeKey, attempt) => attempt < 2,
  });
  const stores = fanoutApp({
    announcements: [announcement],
    registrations: [registrationFixture("device-000", "user-000")],
    events: eventStore,
  });
  const base44 = base44For(stores);

  const enqueue = await fanoutPass(base44, stores.announcementStore, 0);
  assertEquals(enqueue.state, "retry");
  assertEquals(enqueue.phase, "verify");

  const failedVerify = await fanoutPass(
    base44,
    stores.announcementStore,
    1,
  );
  assertEquals(failedVerify.state, "retry");
  assertEquals(failedVerify.verify_failure_passes, 1);
  assertEquals(failedVerify.cursor_registration_id, "");

  const recovered = await fanoutPass(base44, stores.announcementStore, 2);
  assertEquals(recovered.state, "complete");
  assertEquals(recovered.created, 1);
  assertEquals(recovered.verify_failure_passes, 1);
  assertEquals(eventStore.records.length, 1);
});

Deno.test("a permanent poison row terminalizes after bounded full verify sweeps", async () => {
  const announcement = announcementFixture("announcement-terminal");
  const eventStore = new FaultingEventStore([], {
    shouldFailFilter: () => true,
  });
  const stores = fanoutApp({
    announcements: [announcement],
    registrations: [registrationFixture("device-000", "user-000")],
    events: eventStore,
  });
  const base44 = base44For(stores);

  const enqueue = await fanoutPass(base44, stores.announcementStore, 0);
  assertEquals(enqueue.phase, "verify");
  assertEquals(enqueue.verify_failure_passes, 0);

  let result: Row = {};
  for (
    let sweep = 1;
    sweep <= FANOUT_MAX_FAILED_VERIFY_SWEEPS;
    sweep += 1
  ) {
    result = await fanoutPass(base44, stores.announcementStore, sweep);
    assertEquals(result.verify_failure_passes, sweep);
    assertEquals(
      result.state,
      sweep === FANOUT_MAX_FAILED_VERIFY_SWEEPS ? "failed" : "retry",
    );
  }
  assertEquals(stores.announcementStore.records[0].fanout_state, "failed");
  assertEquals(
    stores.announcementStore.records[0].fanout_last_error_code,
    "fanout_verification_failed",
  );
  assertEquals(eventStore.records.length, 0);
});

Deno.test("deadline inside a user group never checkpoints unstarted devices", async () => {
  const announcement = announcementFixture("announcement-inner-deadline");
  let epoch = 0;
  const eventStore = new FaultingEventStore([], {
    shouldFailFilter: (_dedupeKey, attempt) => attempt === 0,
    onFault: () => {
      epoch = 501;
    },
  });
  const stores = fanoutApp({
    announcements: [announcement],
    registrations: [
      registrationFixture("device-000", "user-000"),
      registrationFixture("device-001", "user-000"),
      registrationFixture("device-002", "user-000"),
    ],
    events: eventStore,
  });
  const base44 = base44For(stores);

  const first = await fanoutAnnouncement({
    base44,
    announcement,
    deadlineEpochMs: 500,
    nowEpochMs: () => epoch,
    now: FIXED_NOW,
  });
  assertEquals(first.state, "retry");
  assertEquals(first.cursor_registration_id, "device-000");
  assertEquals(first.deferred, 2);

  epoch = 0;
  const second = await fanoutAnnouncement({
    base44,
    announcement: structuredClone(stores.announcementStore.records[0]),
    deadlineEpochMs: 500,
    nowEpochMs: () => epoch,
    now: new Date(FIXED_NOW.getTime() + 120_000),
  });
  assertEquals(second.phase, "verify");
  assertEquals(second.created, 1);
  assertEquals(second.cursor_registration_id, "");

  const third = await fanoutAnnouncement({
    base44,
    announcement: structuredClone(stores.announcementStore.records[0]),
    deadlineEpochMs: 500,
    nowEpochMs: () => epoch,
    now: new Date(FIXED_NOW.getTime() + 240_000),
  });
  assertEquals(third.state, "complete");
  assertEquals(third.existing, 1);
  assertEquals(eventStore.records.length, 1);
});

Deno.test("verify failure threshold advances only at a full sweep tail", async () => {
  const announcement = announcementFixture("announcement-full-sweep");
  const registrations = Array.from(
    { length: 130 },
    (_, index) =>
      registrationFixture(
        `device-${String(index).padStart(3, "0")}`,
        `user-${String(index).padStart(3, "0")}`,
      ),
  );
  const eventStore = new FaultingEventStore([], {
    shouldFailFilter: (dedupeKey) => dedupeKey.endsWith(":user-000"),
  });
  const stores = fanoutApp({
    announcements: [announcement],
    registrations,
    events: eventStore,
  });
  const base44 = base44For(stores);

  for (let pass = 0; pass < 3; pass += 1) {
    await fanoutPass(base44, stores.announcementStore, pass);
  }
  assertEquals(stores.announcementStore.records[0].fanout_phase, "verify");
  assertEquals(
    stores.announcementStore.records[0].fanout_verify_failure_passes,
    0,
  );

  const firstVerifyPage = await fanoutPass(
    base44,
    stores.announcementStore,
    3,
  );
  assertEquals(firstVerifyPage.cursor_registration_id, "device-063");
  assertEquals(firstVerifyPage.sweep_failed, true);
  assertEquals(firstVerifyPage.verify_failure_passes, 0);

  const secondVerifyPage = await fanoutPass(
    base44,
    stores.announcementStore,
    4,
  );
  assertEquals(secondVerifyPage.cursor_registration_id, "device-127");
  assertEquals(secondVerifyPage.sweep_failed, true);
  assertEquals(secondVerifyPage.verify_failure_passes, 0);

  const verifyTail = await fanoutPass(base44, stores.announcementStore, 5);
  assertEquals(verifyTail.cursor_registration_id, "");
  assertEquals(verifyTail.sweep_failed, false);
  assertEquals(verifyTail.verify_failure_passes, 1);
});

Deno.test("multi-device users share one durable announcement event", async () => {
  const announcement = announcementFixture("announcement-multi-device");
  const stores = fanoutApp({
    announcements: [announcement],
    registrations: [
      registrationFixture("device-000", "user-000"),
      registrationFixture("device-001", "user-000"),
      registrationFixture("device-002", "user-000"),
    ],
  });
  const base44 = base44For(stores);

  const enqueue = await fanoutPass(base44, stores.announcementStore, 0);
  assertEquals(enqueue.created, 1);
  assertEquals(stores.eventStore.records.length, 1);

  const verify = await fanoutPass(base44, stores.announcementStore, 1);
  assertEquals(verify.state, "complete");
  assertEquals(verify.existing, 1);
  assertEquals(stores.eventStore.records.length, 1);
  assertEquals(
    stores.eventStore.records[0].dedupe_key,
    "global_announcement:announcement-multi-device:user-000",
  );
});

Deno.test("a slow poison announcement does not consume the whole drain", async () => {
  const announcements = Array.from(
    { length: 4 },
    (_, index) =>
      announcementFixture(`announcement-${index}`, {
        published_at: new Date(FIXED_NOW.getTime() + index * 1_000)
          .toISOString(),
        updated_at: new Date(FIXED_NOW.getTime() + index * 1_000).toISOString(),
      }),
  );
  let epoch = 0;
  const eventStore = new FaultingEventStore([], {
    shouldFailFilter: (dedupeKey) => dedupeKey.includes(":announcement-0:"),
    onFault: () => {
      epoch = 501;
    },
  });
  const stores = fanoutApp({
    announcements,
    registrations: [registrationFixture("device-000", "user-000")],
    events: eventStore,
  });
  const base44 = base44For(stores);

  const results = await drainAnnouncementFanout({
    base44,
    deadlineEpochMs: 2_000,
    nowEpochMs: () => epoch,
  });

  assertEquals(results.length, 4);
  assertEquals(results[0].failures, 1);
  assertEquals(
    new Set(eventStore.records.map((row) => row.announcement_id)),
    new Set(["announcement-1", "announcement-2", "announcement-3"]),
  );
});

Deno.test("fanout uses exact Base44 keyset and revalidation query shapes", async () => {
  const announcement = announcementFixture("announcement-query-shape");
  const stores = fanoutApp({
    announcements: [announcement],
    registrations: [registrationFixture("device-000", "user-000")],
  });
  const base44 = base44For(stores);

  await fanoutPass(base44, stores.announcementStore, 0);

  assertEquals(stores.registrationStore.filterCalls, [{
    filter: {
      status: "active",
      alert_authorized: true,
      created_date: { $lte: FIXED_NOW.toISOString() },
      $or: [
        { announcements_enabled: true },
        { announcements_enabled: { $exists: false } },
      ],
    },
    sort: "id",
    limit: 65,
    skip: 0,
  }, {
    filter: {
      id: "device-000",
      user_id: "user-000",
      status: "active",
      alert_authorized: true,
      created_date: { $lte: FIXED_NOW.toISOString() },
      $or: [
        { announcements_enabled: true },
        { announcements_enabled: { $exists: false } },
      ],
    },
    sort: "id",
    limit: 2,
    skip: 0,
  }]);
  assertEquals(stores.eventStore.filterCalls, [{
    filter: {
      dedupe_key: "global_announcement:announcement-query-shape:user-000",
    },
    sort: "created_date",
    limit: 2,
    skip: 0,
  }]);
});

Deno.test("announcement schema stores bounded verification state additively", async () => {
  const schema = JSON.parse(
    await Deno.readTextFile(
      new URL(
        "../../entities/notification-announcement.jsonc",
        import.meta.url,
      ),
    ),
  );
  assertEquals(schema.properties.fanout_sweep_failed, {
    type: "boolean",
    default: false,
  });
  assertEquals(schema.properties.fanout_verify_failure_passes, {
    type: "number",
    default: 0,
  });
  assertEquals(schema.properties.fanout_last_failed_registration_id, {
    type: "string",
  });
  assertEquals(
    [
      "fanout_sweep_failed",
      "fanout_verify_failure_passes",
      "fanout_last_failed_registration_id",
    ].some((field) => schema.required.includes(field)),
    false,
  );
});
