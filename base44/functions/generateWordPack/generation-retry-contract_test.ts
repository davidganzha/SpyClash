import {
  assert,
  assertEquals,
  assertRejects,
  assertStringIncludes,
} from "jsr:@std/assert@1";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import { prepareWordPackCacheRequest } from "./generation-cache.ts";
import {
  InvalidWordPackIdempotencyInputError,
  lookupIdempotentWordPackResult,
  persistIdempotentWordPackResult,
  prepareWordPackIdempotency,
  WordPackIdempotencyConflictError,
  WordPackIdempotencyUnavailableError,
} from "./generation-idempotency.ts";
import { createGenerationRetryTracker } from "./generation-retry-contract.ts";
import {
  type GenerationWriteGuard,
  withGenerationWriterLease,
} from "./generation-write-lifecycle.ts";

const NOW = new Date("2026-09-06T12:00:00.000Z");
const SAFE = {
  retryable: true,
  retry_phase: "before_effects",
  effects_started: false,
} as const;
const UNSAFE = {
  retryable: false,
  retry_phase: "effects_may_have_started",
  effects_started: true,
} as const;
const RESULT = {
  category: "Cinema",
  words: ["Arrival", "Moon", "Jaws", "Alien", "Heat"],
  exhausted: false,
};
const OPEN_GUARD: GenerationWriteGuard = {
  boundary: (operation) => operation(),
  assertAvailable: () => Promise.resolve(),
};

function conflict(code: "active_lease" | "cas_contention" = "active_lease") {
  return new BillingIdentityLifecycleError(
    code,
    "Account identity is being updated.",
  );
}

async function identity(requestID = "request-1") {
  return await prepareWordPackIdempotency({
    userID: "user-1",
    requestID,
    request: await prepareWordPackCacheRequest({
      userID: "user-1",
      theme: "Cinema",
      language: "und",
      promptVersion: "retry-contract-test",
      requestedCount: 5,
    }),
  });
}

async function tracker() {
  const result = createGenerationRetryTracker();
  result.bindValidatedRequest(await identity());
  return result;
}

function gate() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => resolve = done);
  return { promise, resolve };
}

for (const code of ["active_lease", "cas_contention"] as const) {
  Deno.test(`only validated pre-effect ${code} gets an automatic retry proof`, async () => {
    const subject = await tracker();
    assertEquals(subject.errorMetadata(conflict(code), 409), SAFE);
    assertEquals(subject.errorMetadata(conflict(code), 503), {
      retryable: false,
    });
    assertEquals(
      createGenerationRetryTracker().errorMetadata(conflict(code), 409),
      { retryable: false },
    );
    subject.bindValidatedRequest(null);
    assertEquals(subject.errorMetadata(conflict(code), 409), {
      retryable: false,
    });
  });
}

Deno.test("deletion, forged codes and unrelated errors cannot acquire a pre-effect proof", async () => {
  const subject = await tracker();
  assertEquals(
    subject.errorMetadata(
      new BillingIdentityLifecycleError(
        "deletion_in_progress",
        "deleting",
      ),
      409,
    ),
    { retryable: false },
  );
  assertEquals(
    subject.errorMetadata(new WordPackIdempotencyConflictError(), 409),
    {
      retryable: false,
    },
  );
  assertEquals(
    subject.errorMetadata({ code: "active_lease", retryable: true }, 409),
    {
      retryable: true,
    },
  );
  assertEquals(
    subject.errorMetadata(new WordPackIdempotencyUnavailableError(), 503),
    {
      retryable: true,
    },
  );
  assertEquals(subject.errorMetadata(new Error("network response lost"), 500), {
    retryable: false,
  });
});

Deno.test("invalid request IDs cannot bind the server retry proof", async () => {
  for (const requestID of ["", "\u0001bad", "x".repeat(129)]) {
    const subject = createGenerationRetryTracker();
    await assertRejects(async () => {
      subject.bindValidatedRequest(await identity(requestID));
    }, InvalidWordPackIdempotencyInputError);
    assertEquals(subject.errorMetadata(conflict(), 409), { retryable: false });
  }
});

Deno.test("failed write acquisition is safe but a failed write response is ambiguous", async () => {
  const subject = await tracker();
  let writes = 0;
  const blocked = subject.trackWrites({
    ...OPEN_GUARD,
    boundary: () => Promise.reject(conflict()),
  });
  const acquisitionError = await assertRejects(
    () =>
      blocked.boundary(async () => {
        writes += 1;
      }),
    BillingIdentityLifecycleError,
  );
  assertEquals(writes, 0);
  assertEquals(subject.errorMetadata(acquisitionError, 409), SAFE);

  const open = subject.trackWrites(OPEN_GUARD);
  const writeError = await assertRejects(() =>
    open.boundary(() => {
      writes += 1;
      return Promise.reject(conflict());
    }), BillingIdentityLifecycleError);
  assertEquals(writes, 1);
  assertEquals(subject.errorMetadata(writeError, 409), UNSAFE);
});

Deno.test("provider acquisition failure is safe before any provider or quota work", async () => {
  const subject = await tracker();
  let providerCalls = 0;
  const error = await assertRejects(() =>
    subject.runProvider({
      ...OPEN_GUARD,
      assertAvailable: () => Promise.reject(conflict()),
    }, async () => {
      providerCalls += 1;
    }), BillingIdentityLifecycleError);
  assertEquals(providerCalls, 0);
  assertEquals(subject.errorMetadata(error, 409), SAFE);
});

Deno.test("reserved quota and failed rollback cannot become safe to retry", async () => {
  const subject = await tracker();
  let quotaUsed = 0;
  const guard = subject.trackWrites(OPEN_GUARD);
  await guard.boundary(async () => {
    quotaUsed += 1;
  });
  const blocked = subject.trackWrites({
    boundary: () => Promise.reject(conflict()),
    assertAvailable: () => Promise.reject(conflict()),
  });
  const error = await assertRejects(
    () => subject.runProvider(blocked, () => Promise.resolve(RESULT)),
    BillingIdentityLifecycleError,
  );
  await assertRejects(() =>
    blocked.boundary(async () => {
      quotaUsed -= 1;
    }), BillingIdentityLifecycleError);
  assertEquals(quotaUsed, 1);
  assertEquals(subject.errorMetadata(error, 409), UNSAFE);
});

Deno.test("second AI pass conflict does not authorize replaying the first provider call", async () => {
  const subject = await tracker();
  let providerCalls = 0;
  await subject.runProvider(OPEN_GUARD, async () => {
    providerCalls += 1;
    return RESULT;
  });
  const error = await assertRejects(() =>
    subject.runProvider({
      ...OPEN_GUARD,
      assertAvailable: () => Promise.reject(conflict("cas_contention")),
    }, async () => {
      providerCalls += 1;
    }), BillingIdentityLifecycleError);
  assertEquals(providerCalls, 1);
  assertEquals(subject.errorMetadata(error, 409), UNSAFE);
});

Deno.test("unknown provider outcome and a crash before result persistence remain non-retryable", async () => {
  const subject = await tracker();
  let providerCalls = 0;
  const error = await assertRejects(
    () =>
      subject.runProvider(OPEN_GUARD, async () => {
        providerCalls += 1;
        throw new Error("provider response lost after accepting generation");
      }),
    Error,
  );
  assertEquals(providerCalls, 1);
  assertEquals(subject.errorMetadata(error, 500), UNSAFE);
  // Binding the same request ID again must not clear evidence of effects.
  subject.bindValidatedRequest(await identity());
  assertEquals(subject.errorMetadata(conflict(), 409), UNSAFE);
});

type Row = Record<string, any>;

class Store {
  records: Row[] = [];
  nextID = 0;

  async filter(query: Row, _sort = "created_date", limit = 20, skip = 0) {
    return this.records.filter((row) =>
      Object.entries(query).every(([key, value]) => row[key] === value)
    ).slice(skip, skip + limit).map((row) => structuredClone(row));
  }

  async create(value: Row) {
    const row = {
      ...structuredClone(value),
      id: `row-${++this.nextID}`,
      created_date: NOW.toISOString(),
      updated_date: NOW.toISOString(),
    };
    this.records.push(row);
    return structuredClone(row);
  }

  async updateMany(query: Row, update: Row) {
    let updated = 0;
    for (const row of this.records) {
      if (Object.entries(query).every(([key, value]) => row[key] === value)) {
        Object.assign(row, update.$set || {});
        updated += 1;
      }
    }
    return { updated };
  }

  async delete(id: string) {
    this.records = this.records.filter((row) => row.id !== id);
  }
}

Deno.test("result commit followed by unreadable receipt does not issue a retry proof", async () => {
  const subject = await tracker();
  const guard = subject.trackWrites(OPEN_GUARD);
  const store = new Store();
  const requestIdentity = await identity();
  const error = await assertRejects(async () => {
    try {
      await guard.boundary(() =>
        persistIdempotentWordPackResult({
          store: {
            create: (value) => store.create(value),
            filter: () => Promise.resolve([]),
          },
          identity: requestIdentity,
          result: RESULT,
          now: NOW,
        })
      );
    } catch {
      // The handler sanitizes persistence errors into this HTTP 503 error.
      throw new WordPackIdempotencyUnavailableError();
    }
  }, WordPackIdempotencyUnavailableError);
  assertEquals(store.records.length, 1);
  assertEquals(subject.errorMetadata(error, error.status), UNSAFE);
});

Deno.test("concurrent same-ID generation replays its receipt with one quota reservation and provider call", async () => {
  const lifecycleStore = new Store();
  const receiptStore = new Store();
  const requestIdentity = await identity();
  const providerStarted = gate();
  const providerFinished = gate();
  const contenderBlocked = gate();
  const releaseContender = gate();
  let quotaUsed = 0;
  let providerCalls = 0;
  let sequence = 0;

  const generate = async () => {
    const subject = await tracker();
    return await withGenerationWriterLease({
      lifecycleStore,
      userID: "user-1",
      nowFactory: () => NOW,
      randomUUID: () => `lease-${++sequence}`,
      delay: () => {
        contenderBlocked.resolve();
        return releaseContender.promise;
      },
      action: async (untrackedGuard) => {
        const guard = subject.trackWrites(untrackedGuard);
        const replay = await lookupIdempotentWordPackResult({
          store: receiptStore,
          identity: requestIdentity,
          now: NOW,
        });
        if (replay) return replay;
        await guard.boundary(async () => {
          quotaUsed += 1;
        });
        const result = await subject.runProvider(guard, async () => {
          providerCalls += 1;
          providerStarted.resolve();
          await providerFinished.promise;
          return RESULT;
        });
        return await guard.boundary(() =>
          persistIdempotentWordPackResult({
            store: receiptStore,
            identity: requestIdentity,
            result,
            now: NOW,
          })
        );
      },
    });
  };

  const first = generate();
  await providerStarted.promise;
  const second = generate();
  await contenderBlocked.promise;
  assertEquals(providerCalls, 1);
  providerFinished.resolve();
  const firstResult = await first;
  releaseContender.resolve();
  const secondResult = await second;
  assertEquals(secondResult, firstResult);
  assertEquals(providerCalls, 1);
  assertEquals(quotaUsed, 1);
  assertEquals(receiptStore.records.length, 1);
  assert(
    lifecycleStore.records.every((row) =>
      Date.parse(row.lease_until) <= NOW.getTime()
    ),
  );
});

Deno.test("simultaneous invocation trackers do not share effect state", async () => {
  const first = await tracker();
  const second = await tracker();
  const provider = gate();
  const started = gate();
  const inFlight = first.runProvider(OPEN_GUARD, async () => {
    started.resolve();
    await provider.promise;
  });
  await started.promise;
  assertEquals(first.errorMetadata(conflict(), 409), UNSAFE);
  assertEquals(second.errorMetadata(conflict(), 409), SAFE);
  provider.resolve();
  await inFlight;
});

Deno.test("handler binds validated identity and tracks both providers and all guarded writes", async () => {
  const main = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  assertStringIncludes(
    main,
    "Deno.serve(async (req) => {\n  const retryTracker = createGenerationRetryTracker();",
  );
  assert(
    main.indexOf("retryTracker.bindValidatedRequest(idempotency)") >
      main.indexOf("await prepareWordPackIdempotency("),
  );
  assertStringIncludes(
    main,
    "const guard = retryTracker.trackWrites(untrackedGuard)",
  );
  assertEquals(main.split("retryTracker.runProvider(").length - 1, 2);
  assertEquals(main.split("await guard.assertAvailable()").length - 1, 0);
  assertStringIncludes(main, "retryTracker.errorMetadata(error, 503)");
  assertStringIncludes(
    main,
    "retryTracker.errorMetadata(error, normalizedStatus)",
  );
  assertStringIncludes(main, "status: normalizedStatus");
});
