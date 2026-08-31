import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  BillingIdentityLifecycleError,
  billingIdentitySubjectKey,
} from "./billing-identity-lifecycle.ts";
import { withGenerationWriterLease } from "./generation-write-lifecycle.ts";

type RecordValue = Record<string, any>;
const START = new Date("2026-07-14T12:00:00.000Z");

function sequence(prefix: string) {
  let value = 0;
  return () => `${prefix}-${++value}`;
}

class MockLifecycleStore {
  records: RecordValue[] = [];
  nextID = 1;

  async filter(
    filter: RecordValue,
    _sort: string,
    limit: number,
    skip: number,
  ) {
    return this.records
      .filter((record) =>
        Object.entries(filter).every(([key, value]) => record[key] === value)
      )
      .slice(skip, skip + limit)
      .map((record) => structuredClone(record));
  }

  async create(value: RecordValue) {
    const created = {
      ...structuredClone(value),
      id: `lifecycle-${this.nextID++}`,
      created_date: START.toISOString(),
      updated_date: START.toISOString(),
    };
    this.records.push(created);
    return structuredClone(created);
  }

  async delete(id: string) {
    this.records = this.records.filter((record) => record.id !== id);
  }

  async updateMany(filter: RecordValue, update: RecordValue) {
    let updated = 0;
    for (const record of this.records) {
      if (
        Object.entries(filter).every(([key, value]) => record[key] === value)
      ) {
        Object.assign(record, update.$set || {});
        record.updated_date = START.toISOString();
        updated += 1;
      }
    }
    return { updated };
  }
}

function fakeLease() {
  return {
    recordID: "lifecycle-1",
    subjectKey: "billing:user-1",
    state: "active" as const,
    leaseToken: "generation-lease",
    leaseUntil: new Date(START.getTime() + 10 * 60 * 1_000).toISOString(),
    revision: "generation-revision",
  };
}

for (const code of ["active_lease", "cas_contention"] as const) {
  Deno.test(`generation retries transient ${code} before running its action`, async () => {
    const delays: number[] = [];
    let acquireCalls = 0;
    let actionCalls = 0;
    let releaseCalls = 0;

    const result = await withGenerationWriterLease({
      lifecycleStore: new MockLifecycleStore(),
      userID: "user-1",
      nowFactory: () => START,
      randomUUID: sequence("generation"),
      acquire: () => {
        acquireCalls += 1;
        if (acquireCalls === 1) {
          throw new BillingIdentityLifecycleError(
            code,
            "temporary identity contention",
          );
        }
        return Promise.resolve(fakeLease());
      },
      release: () => {
        releaseCalls += 1;
        return Promise.resolve();
      },
      delay: (milliseconds) => {
        delays.push(milliseconds);
        return Promise.resolve();
      },
      action: () => {
        actionCalls += 1;
        return Promise.resolve("generated");
      },
    });

    assertEquals(result, "generated");
    assertEquals(acquireCalls, 2);
    assertEquals(actionCalls, 1);
    assertEquals(releaseCalls, 1);
    assertEquals(delays, [180]);
  });
}

Deno.test("generation stops after bounded transient lease retries", async () => {
  const delays: number[] = [];
  let acquireCalls = 0;
  let actionCalls = 0;
  let releaseCalls = 0;

  const error = await assertRejects(
    () =>
      withGenerationWriterLease({
        lifecycleStore: new MockLifecycleStore(),
        userID: "user-1",
        nowFactory: () => START,
        randomUUID: sequence("generation"),
        acquire: () => {
          acquireCalls += 1;
          throw new BillingIdentityLifecycleError(
            "active_lease",
            "Account identity is being updated.",
          );
        },
        release: () => {
          releaseCalls += 1;
          return Promise.resolve();
        },
        delay: (milliseconds) => {
          delays.push(milliseconds);
          return Promise.resolve();
        },
        action: () => {
          actionCalls += 1;
          return Promise.resolve("generated");
        },
      }),
    BillingIdentityLifecycleError,
  );

  assertEquals(error.code, "active_lease");
  assertEquals(acquireCalls, 4);
  assertEquals(actionCalls, 0);
  assertEquals(releaseCalls, 0);
  assertEquals(delays, [180, 520, 1_300]);
});

Deno.test("generation does not retry account deletion in progress", async () => {
  const delays: number[] = [];
  let acquireCalls = 0;
  let actionCalls = 0;

  const error = await assertRejects(
    () =>
      withGenerationWriterLease({
        lifecycleStore: new MockLifecycleStore(),
        userID: "user-1",
        nowFactory: () => START,
        randomUUID: sequence("generation"),
        acquire: () => {
          acquireCalls += 1;
          throw new BillingIdentityLifecycleError(
            "deletion_in_progress",
            "Account deletion is in progress or already completed.",
          );
        },
        delay: (milliseconds) => {
          delays.push(milliseconds);
          return Promise.resolve();
        },
        action: () => {
          actionCalls += 1;
          return Promise.resolve("generated");
        },
      }),
    BillingIdentityLifecycleError,
  );

  assertEquals(error.code, "deletion_in_progress");
  assertEquals(acquireCalls, 1);
  assertEquals(actionCalls, 0);
  assertEquals(delays, []);
});

Deno.test("provider work does not retain the shared account writer lease", async () => {
  const store = new MockLifecycleStore();
  const accountSubjectKey = await billingIdentitySubjectKey("user-1");
  let accountLeaseActiveDuringProvider = true;
  let accountLeaseActiveDuringWrite = false;

  await withGenerationWriterLease({
    lifecycleStore: store,
    userID: "user-1",
    nowFactory: () => START,
    randomUUID: sequence("generation"),
    action: async (guard) => {
      await guard.assertAvailable();
      const releasedAccount = store.records.find((record) =>
        record.subject_key === accountSubjectKey
      );
      accountLeaseActiveDuringProvider =
        Date.parse(String(releasedAccount?.lease_until || "")) >
          START.getTime();

      await guard.boundary(async () => {
        const activeAccount = store.records.find((record) =>
          record.subject_key === accountSubjectKey
        );
        accountLeaseActiveDuringWrite =
          Date.parse(String(activeAccount?.lease_until || "")) >
            START.getTime();
      });
    },
  });

  assertEquals(accountLeaseActiveDuringProvider, false);
  assertEquals(accountLeaseActiveDuringWrite, true);
  assertEquals(store.records.length, 2);
});

Deno.test("committed generation survives transient lease release failures", async () => {
  const store = new MockLifecycleStore();
  const delays: number[] = [];
  let releaseCalls = 0;

  const result = await withGenerationWriterLease({
    lifecycleStore: store,
    userID: "user-1",
    nowFactory: () => START,
    randomUUID: sequence("generation"),
    release: async () => {
      releaseCalls += 1;
      if (releaseCalls < 3) throw new Error("transient release failure");
    },
    delay: (milliseconds) => {
      delays.push(milliseconds);
      return Promise.resolve();
    },
    action: () => Promise.resolve("generated"),
  });

  assertEquals(result, "generated");
  assertEquals(releaseCalls, 3);
  assertEquals(delays, [50, 150]);
});

Deno.test("exhausted lease release never replaces a committed result", async () => {
  const store = new MockLifecycleStore();
  const delays: number[] = [];
  let releaseCalls = 0;

  const originalConsoleError = console.error;
  console.error = () => {};
  try {
    const result = await withGenerationWriterLease({
      lifecycleStore: store,
      userID: "user-1",
      nowFactory: () => START,
      randomUUID: sequence("generation"),
      release: () => {
        releaseCalls += 1;
        return Promise.reject(new Error("release unavailable"));
      },
      delay: (milliseconds) => {
        delays.push(milliseconds);
        return Promise.resolve();
      },
      action: () => Promise.resolve("generated"),
    });

    assertEquals(result, "generated");
  } finally {
    console.error = originalConsoleError;
  }

  assertEquals(releaseCalls, 3);
  assertEquals(delays, [50, 150]);
});

Deno.test("action error remains authoritative when lease release also fails", async () => {
  const store = new MockLifecycleStore();
  const actionError = new Error("provider failed");

  const originalConsoleError = console.error;
  console.error = () => {};
  try {
    const error = await assertRejects(
      () =>
        withGenerationWriterLease({
          lifecycleStore: store,
          userID: "user-1",
          nowFactory: () => START,
          randomUUID: sequence("generation"),
          release: () => Promise.reject(new Error("release unavailable")),
          delay: () => Promise.resolve(),
          action: () => Promise.reject(actionError),
        }),
      Error,
      "provider failed",
    );
    assertEquals(error, actionError);
  } finally {
    console.error = originalConsoleError;
  }
});
