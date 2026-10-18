import {
  AuthStoreDependencyError,
  createAuthStoreRecovery,
} from "./auth-store-recovery.ts";

function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw new Error(message);
}

function equal(actual: unknown, expected: unknown) {
  assert(JSON.stringify(actual) === JSON.stringify(expected), "Values differ");
}

async function failure(operation: () => Promise<unknown>): Promise<unknown> {
  try {
    await operation();
  } catch (error) {
    return error;
  }
  throw new Error("Expected failure");
}

const supportDenial = () => ({
  status: 403,
  message:
    "You need to access this app through the support panel first. Please go to the support panel and click on a ticket for this app to grant temporary access.",
});

function clock() {
  let milliseconds = 0;
  const delays: number[] = [];
  return {
    now: () => milliseconds,
    sleep: (delay: number) => {
      delays.push(delay);
      milliseconds += delay;
      return Promise.resolve();
    },
    advance: (delay: number) => milliseconds += delay,
    delays,
  };
}

Deno.test("service filter retries the exact support denial with the same arguments and receiver", async () => {
  const time = clock();
  const query = { revision: "synthetic-revision" };
  const store = {
    calls: 0,
    async filter(received: unknown, sort: string, limit: number, skip: number) {
      assert(this === store);
      assert(received === query);
      equal([sort, limit, skip], ["created_date", 100, 0]);
      if (++this.calls === 1) throw supportDenial();
      return [{ state: "pending" }];
    },
  };
  const recovered = createAuthStoreRecovery(time).wrap(
    store,
    "apple_credential",
  );
  equal(await recovered.filter(query, "created_date", 100, 0), [{
    state: "pending",
  }]);
  equal(store.calls, 2);
  equal(time.delays, [150]);
});

Deno.test("allowlisted transient service statuses recover within three attempts", async (t) => {
  for (const status of [408, 429, 500, 502, 503, 504]) {
    await t.step(String(status), async () => {
      const time = clock();
      let calls = 0;
      const store = createAuthStoreRecovery(time).wrap({
        async filter() {
          if (++calls < 3) throw { status };
          return [];
        },
      }, "identity_lifecycle");
      equal(await store.filter(), []);
      equal(calls, 3);
      equal(time.delays, [150, 400]);
    });
  }
});

Deno.test("persistent service denial is bounded and retains no upstream secrets", async () => {
  const time = clock();
  let calls = 0;
  const upstream = {
    ...supportDenial(),
    data: { token: "do-not-retain-token" },
    request: { headers: { Authorization: "do-not-retain-bearer" } },
  };
  const store = createAuthStoreRecovery(time).wrap({
    filter() {
      calls++;
      return Promise.reject(upstream);
    },
  }, "identity_lifecycle");
  const error = await failure(() => store.filter());
  assert(error instanceof AuthStoreDependencyError);
  equal([
    error.status,
    error.upstreamStatus,
    error.reason,
    error.scope,
    error.operation,
  ], [503, 403, "support_panel_context", "identity_lifecycle", "filter"]);
  equal(calls, 3);
  equal(time.delays, [150, 400]);
  equal(error.retryable, true);
  equal(
    Object.keys(error).sort(),
    [
      "name",
      "operation",
      "reason",
      "retryable",
      "scope",
      "status",
      "upstreamStatus",
    ].sort(),
  );
  assert(!JSON.stringify(error).includes("do-not-retain"));
  assert(!String(error).includes("support panel"));
  assert(!("cause" in error));
});

Deno.test("ordinary service 401 and 403 are classified without retry", async (t) => {
  for (const status of [401, 403]) {
    await t.step(String(status), async () => {
      const time = clock();
      let calls = 0;
      const store = createAuthStoreRecovery(time).wrap({
        filter() {
          calls++;
          return Promise.reject({ status, message: "Access denied" });
        },
      }, "apple_credential");
      const error = await failure(() => store.filter());
      assert(error instanceof AuthStoreDependencyError);
      equal(error.reason, status === 401 ? "unauthorized" : "forbidden");
      equal(error.retryable, false);
      equal(calls, 1);
      equal(time.delays, []);
    });
  }
});

Deno.test("near matches and nested support messages cannot authorize a retry", async () => {
  for (
    const upstream of [
      { status: 403, message: supportDenial().message + " " },
      {
        status: 403,
        message: "Access denied",
        data: { detail: supportDenial().message },
      },
    ]
  ) {
    const time = clock();
    let calls = 0;
    const store = createAuthStoreRecovery(time).wrap({
      filter() {
        calls++;
        return Promise.reject(upstream);
      },
    }, "apple_credential");
    const error = await failure(() => store.filter());
    assert(error instanceof AuthStoreDependencyError);
    equal(error.reason, "forbidden");
    equal(calls, 1);
    equal(time.delays, []);
  }
});

Deno.test("unknown errors and statuses propagate unchanged without retry", async () => {
  for (
    const upstream of [new Error("Synthetic failure"), { status: 400 }, {
      status: 501,
    }, { status: "503" }]
  ) {
    const time = clock();
    let calls = 0;
    const store = createAuthStoreRecovery(time).wrap({
      filter() {
        calls++;
        return Promise.reject(upstream);
      },
    }, "apple_credential");
    assert(await failure(() => store.filter()) === upstream);
    equal(calls, 1);
    equal(time.delays, []);
  }
});

Deno.test("create updateMany and delete preserve their exact one-call failure boundary", async () => {
  const time = clock();
  const upstream = supportDenial();
  const calls = { create: 0, updateMany: 0, delete: 0 };
  const store = {
    filter: () => Promise.resolve([]),
    create() {
      assert(this === store);
      calls.create++;
      return Promise.reject(upstream);
    },
    updateMany() {
      assert(this === store);
      calls.updateMany++;
      return Promise.reject(upstream);
    },
    delete() {
      assert(this === store);
      calls.delete++;
      return Promise.reject(upstream);
    },
  };
  const wrapped = createAuthStoreRecovery(time).wrap(
    store,
    "identity_lifecycle",
  );
  for (const method of ["create", "updateMany", "delete"] as const) {
    assert(await failure(() => wrapped[method]()) === upstream);
  }
  equal(calls, { create: 1, updateMany: 1, delete: 1 });
  equal(time.delays, []);
});

Deno.test("two store scopes share a maximum of four retries for one request", async () => {
  const time = clock();
  const recovery = createAuthStoreRecovery(time);
  const calls = [0, 0, 0];
  for (let index = 0; index < 3; index++) {
    const wrapped = recovery.wrap({
      filter() {
        calls[index]++;
        return Promise.reject(supportDenial());
      },
    }, index === 0 ? "apple_credential" : "identity_lifecycle");
    assert(
      await failure(() => wrapped.filter()) instanceof AuthStoreDependencyError,
    );
  }
  equal(calls, [3, 3, 1]);
  equal(time.delays, [150, 400, 150, 400]);
});

Deno.test("concurrent service reads cannot over-reserve the shared retry budget", async () => {
  const time = clock();
  const recovery = createAuthStoreRecovery(time);
  const calls = [0, 0, 0];
  await Promise.all(calls.map((_, index) => {
    const wrapped = recovery.wrap({
      filter() {
        calls[index]++;
        return Promise.reject(supportDenial());
      },
    }, "identity_lifecycle");
    return failure(() => wrapped.filter());
  }));
  equal(calls.reduce((total, count) => total + count, 0), 7);
  assert(calls.every((count) => count <= 3));
  equal(time.delays.length, 4);
});

Deno.test("a delayed timer cannot issue a request beyond the shared recovery deadline", async () => {
  const time = clock();
  let calls = 0;
  const recovery = createAuthStoreRecovery({
    now: time.now,
    sleep: async (delay) => {
      await time.sleep(delay);
      time.advance(3_000);
    },
  });
  const wrapped = recovery.wrap({
    filter() {
      calls++;
      return Promise.reject({ status: 503 });
    },
  }, "identity_lifecycle");
  assert(
    await failure(() => wrapped.filter()) instanceof AuthStoreDependencyError,
  );
  equal(calls, 1);
  equal(time.delays, [150]);
});

Deno.test("a successful retry completing after the deadline retains the last sanitized dependency failure", async () => {
  const time = clock();
  let calls = 0;
  const wrapped = createAuthStoreRecovery(time).wrap({
    async filter() {
      if (++calls === 1) {
        throw {
          ...supportDenial(),
          data: { token: "do-not-retain-late-read-token" },
        };
      }
      time.advance(3_000);
      return [{ state: "bound" }];
    },
  }, "apple_credential");
  const error = await failure(() => wrapped.filter());
  assert(error instanceof AuthStoreDependencyError);
  equal([error.status, error.upstreamStatus, error.reason, error.scope], [
    503,
    403,
    "support_panel_context",
    "apple_credential",
  ]);
  equal(error.retryable, true);
  equal(calls, 2);
  equal(time.delays, [150]);
  assert(!JSON.stringify(error).includes("do-not-retain"));
  assert(!("cause" in error));
});

Deno.test("a slow first successful read remains unaffected by the recovery deadline", async () => {
  const time = clock();
  const recovery = createAuthStoreRecovery(time);
  let calls = 0;
  const recovered = recovery.wrap({
    async filter() {
      if (++calls === 1) throw supportDenial();
      return [];
    },
  }, "apple_credential");
  await recovered.filter();
  let slowCalls = 0;
  const slow = recovery.wrap({
    async filter() {
      slowCalls++;
      time.advance(5_000);
      return [{ state: "pending" }];
    },
  }, "identity_lifecycle");
  equal(await slow.filter(), [{ state: "pending" }]);
  equal(slowCalls, 1);
  equal(time.delays, [150]);
});

Deno.test("later failures cannot reset the recovery window but initial successful reads still work", async () => {
  const time = clock();
  const recovery = createAuthStoreRecovery(time);
  let firstCalls = 0;
  const first = recovery.wrap({
    filter() {
      if (++firstCalls === 1) return Promise.reject(supportDenial());
      return Promise.resolve([]);
    },
  }, "apple_credential");
  time.advance(10_000); // Time before the first failure does not consume recovery.
  await first.filter();
  time.advance(3_000);
  let laterCalls = 0;
  const later = recovery.wrap({
    filter() {
      laterCalls++;
      return Promise.reject({ status: 503 });
    },
  }, "identity_lifecycle");
  assert(
    await failure(() => later.filter()) instanceof AuthStoreDependencyError,
  );
  equal(laterCalls, 1);
  equal(time.delays, [150]);
  equal(await first.filter(), []);
});
