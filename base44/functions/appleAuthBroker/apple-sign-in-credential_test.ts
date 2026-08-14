import {
  AppleSignInCredentialError,
  type AppleSignInCredentialRecord,
  type AppleSignInCredentialStore,
  assertTrackedAppleSignInCredential,
  bindPendingAppleSignInCredentials,
  deleteAppleSignInCredentialRecords,
  persistPendingAppleSignInCredential,
  revokeAppleSignInCredentials,
  withAppleCredentialIdentityWriter,
  withAppleCredentialIssuanceBoundary,
  withPendingAppleCredentialBindingIdentityWriter,
} from "./apple-sign-in-credential.ts";
import { releaseBillingDeletionMarker } from "./billing-identity-lifecycle.ts";

const PSEUDONYM_SECRET = "p".repeat(32);
const ENCRYPTION_SECRET = "11".repeat(32);
const NOW = new Date("2026-07-25T12:00:00.000Z");

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

class MemoryStore implements AppleSignInCredentialStore {
  records: AppleSignInCredentialRecord[] = [];
  nextID = 1;
  throwDeleteBeforeApply = false;
  throwDeleteAfterApply = false;
  deleteReturnsFailure = false;
  forceNextCASMiss = false;
  beforeNextUpdateMany: (() => void) | undefined;

  async filter(
    query: Record<string, unknown>,
    _sort?: string,
    limit = 100,
    skip = 0,
  ) {
    return this.records
      .filter((record) =>
        Object.entries(query).every(([key, value]) =>
          (record as Record<string, unknown>)[key] === value
        )
      )
      .slice(skip, skip + limit)
      .map((record) => ({ ...record }));
  }

  async create(data: Record<string, unknown>) {
    const record = {
      id: `credential-${this.nextID++}`,
      created_date: new Date().toISOString(),
      ...data,
    } as AppleSignInCredentialRecord;
    this.records.push(record);
    return { ...record };
  }

  async updateMany(
    query: Record<string, unknown>,
    update: { $set: Record<string, unknown> },
  ) {
    const beforeUpdate = this.beforeNextUpdateMany;
    this.beforeNextUpdateMany = undefined;
    beforeUpdate?.();
    if (this.forceNextCASMiss) {
      this.forceNextCASMiss = false;
      return { success: true, updated: 0, has_more: false };
    }
    let updated = 0;
    this.records = this.records.map((record) => {
      const matches = Object.entries(query).every(([key, value]) =>
        (record as Record<string, unknown>)[key] === value
      );
      if (!matches) return record;
      updated += 1;
      return { ...record, ...update.$set };
    });
    return { success: true, updated, has_more: false };
  }

  async delete(id: string) {
    if (this.throwDeleteBeforeApply) throw new Error("delete unavailable");
    if (this.deleteReturnsFailure) return { success: false };
    const index = this.records.findIndex((record) => record.id === id);
    if (index < 0) throw new Error("missing credential");
    this.records.splice(index, 1);
    if (this.throwDeleteAfterApply) throw new Error("response lost");
    return { success: true };
  }
}

const lifecycleStores = new WeakMap<MemoryStore, MemoryStore>();

function lifecycleStoreFor(store: MemoryStore): MemoryStore {
  let lifecycleStore = lifecycleStores.get(store);
  if (!lifecycleStore) {
    lifecycleStore = new MemoryStore();
    lifecycleStores.set(store, lifecycleStore);
  }
  return lifecycleStore;
}

async function storedCredential(
  store: MemoryStore,
  input: {
    email?: string;
    subject?: string;
    clientID?: string;
    token?: string;
  } = {},
) {
  return await persistPendingAppleSignInCredential({
    store,
    lifecycleStore: lifecycleStoreFor(store),
    email: input.email || "operative@privaterelay.appleid.com",
    subject: input.subject || "apple-subject-1",
    clientID: input.clientID || "com.spyclash.ios",
    refreshToken: input.token || "private-refresh-token",
    now: () => NOW,
    pseudonymSecret: PSEUDONYM_SECRET,
    encryptionSecret: ENCRYPTION_SECRET,
    randomTicket: () => "one-time-binding-ticket",
  });
}

async function bindCredential(
  store: MemoryStore,
  ticket: string,
  userID = "base44-user-1",
  now = NOW,
) {
  return await bindPendingAppleSignInCredentials({
    store,
    lifecycleStore: lifecycleStoreFor(store),
    email: "operative@privaterelay.appleid.com",
    userID,
    bindingTicket: ticket,
    now: () => now,
    pseudonymSecret: PSEUDONYM_SECRET,
  });
}

Deno.test("Apple refresh token is encrypted, ticket-bound, revoked, and scrubbed", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  assert(
    saved.bindingTicket === "one-time-binding-ticket",
    "binding ticket changed",
  );
  assert(store.records.length === 1, "credential was not stored");
  const serialized = JSON.stringify(store.records[0]);
  assert(
    !serialized.includes("private-refresh-token"),
    "refresh token was stored in plaintext",
  );
  assert(!serialized.includes("operative@"), "raw email was stored");
  assert(
    !serialized.includes("apple-subject-1"),
    "raw Apple subject was stored",
  );

  let invalidTicketRejected = false;
  try {
    await bindCredential(store, "wrong-ticket");
  } catch (error) {
    invalidTicketRejected = error instanceof AppleSignInCredentialError &&
      error.code === "apple_credential_binding_invalid";
  }
  assert(invalidTicketRejected, "an invalid binding ticket was accepted");

  const bound = await bindCredential(store, saved.bindingTicket);
  assert(bound.bound === 1, "pending credential was not bound");
  assert(
    store.records[0].user_id === "base44-user-1",
    "owner was not server-bound",
  );
  assert(
    cleanForTest(store.records[0].binding_ticket_hash).length > 20,
    "idempotency ticket hash was not retained until expiry",
  );
  const repeatedBind = await bindCredential(store, saved.bindingTicket);
  assert(repeatedBind.bound === 0, "repeated bind was not idempotent");
  assert(
    store.records[0].user_id === "base44-user-1",
    "repeated bind changed the owner",
  );
  const delayedRepeatedBind = await bindCredential(
    store,
    saved.bindingTicket,
    "base44-user-1",
    new Date(NOW.getTime() + 6 * 60 * 1_000),
  );
  assert(
    delayedRepeatedBind.bound === 0,
    "same-owner binding replay stopped being idempotent after ticket expiry",
  );

  let requestCount = 0;
  const result = await revokeAppleSignInCredentials({
    store,
    lifecycleStore: lifecycleStoreFor(store),
    email: "operative@privaterelay.appleid.com",
    userID: "base44-user-1",
    pseudonymSecret: PSEUDONYM_SECRET,
    encryptionSecret: ENCRYPTION_SECRET,
    createClientSecret: async (clientID) => {
      assert(clientID === "com.spyclash.ios", "wrong client id was signed");
      return "signed-client-secret";
    },
    fetcher: async (url, init) => {
      requestCount += 1;
      assert(
        url === "https://appleid.apple.com/auth/revoke",
        "wrong revoke URL",
      );
      assert(init?.method === "POST", "revoke was not POST");
      assert(init?.redirect === "error", "redirects were not rejected");
      const body = init?.body as URLSearchParams;
      assert(body.get("client_id") === "com.spyclash.ios", "wrong client_id");
      assert(
        body.get("client_secret") === "signed-client-secret",
        "wrong client_secret",
      );
      assert(
        body.get("token") === "private-refresh-token",
        "wrong refresh token",
      );
      assert(
        body.get("token_type_hint") === "refresh_token",
        "wrong token hint",
      );
      return new Response(null, { status: 200 });
    },
  });
  assert(result.revoked === 1, "credential was not revoked");
  assert(
    !result.manualRevocationRequired,
    "manual revoke was incorrectly requested",
  );
  assert(requestCount === 1, "unexpected revoke request count");
  assert(
    store.records[0].state === "revoked",
    "revoked state was not persisted",
  );
  assert(
    store.records[0].refresh_token_ciphertext === "",
    "ciphertext was not scrubbed",
  );

  await releaseBillingDeletionMarker(
    lifecycleStoreFor(store),
    result.identityDeletionMarker,
    NOW,
  );

  const replay = await revokeAppleSignInCredentials({
    store,
    lifecycleStore: lifecycleStoreFor(store),
    email: "operative@privaterelay.appleid.com",
    userID: "base44-user-1",
    pseudonymSecret: PSEUDONYM_SECRET,
    encryptionSecret: ENCRYPTION_SECRET,
    createClientSecret: async () => "unused",
    fetcher: async () => {
      requestCount += 1;
      return new Response(null, { status: 500 });
    },
  });
  assert(replay.revoked === 0, "revoked credential was sent again");
  assert(requestCount === 1, "retry sent a scrubbed credential");

  await deleteAppleSignInCredentialRecords(store, replay.recordIDs);
  assert(
    Number(store.records.length) === 0,
    "credential cleanup failed",
  );
});

Deno.test("expired binding ticket cannot claim a pending Apple credential", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  let rejected = false;
  try {
    await bindCredential(
      store,
      saved.bindingTicket,
      "base44-user-1",
      new Date(NOW.getTime() + 6 * 60 * 1_000),
    );
  } catch (error) {
    rejected = error instanceof AppleSignInCredentialError &&
      error.code === "apple_credential_binding_invalid";
  }
  assert(rejected, "expired binding ticket was accepted");
  assert(!store.records[0].user_id, "expired ticket changed ownership");
});

Deno.test("credential ownership cannot move to another Base44 account", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  await bindCredential(store, saved.bindingTicket, "owner-a");

  const refreshed = await persistPendingAppleSignInCredential({
    store,
    lifecycleStore: lifecycleStoreFor(store),
    email: "operative@privaterelay.appleid.com",
    subject: "apple-subject-1",
    clientID: "com.spyclash.ios",
    refreshToken: "replacement-token",
    now: () => NOW,
    pseudonymSecret: PSEUDONYM_SECRET,
    encryptionSecret: ENCRYPTION_SECRET,
    randomTicket: () => "replacement-ticket",
  });
  let rejected = false;
  try {
    await bindCredential(store, refreshed.bindingTicket, "owner-b");
  } catch (error) {
    rejected = error instanceof AppleSignInCredentialError &&
      error.code === "apple_credential_owner_conflict";
  }
  assert(rejected, "credential ownership moved between accounts");
  assert(
    store.records[0].user_id === "owner-a",
    "existing owner was overwritten",
  );
});

Deno.test("lost Apple response retains encrypted credential for idempotent retry", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  await bindCredential(store, saved.bindingTicket);
  let requestStarted = false;
  let requests = 0;
  let failed = false;
  try {
    await revokeAppleSignInCredentials({
      store,
      lifecycleStore: lifecycleStoreFor(store),
      email: "operative@privaterelay.appleid.com",
      userID: "base44-user-1",
      pseudonymSecret: PSEUDONYM_SECRET,
      encryptionSecret: ENCRYPTION_SECRET,
      createClientSecret: async () => "signed-client-secret",
      beforeRevokeRequest: () => {
        requestStarted = true;
      },
      sleepBeforeRetry: async () => {},
      fetcher: async () => {
        requests += 1;
        throw new TypeError("network lost after send");
      },
    });
  } catch (error) {
    failed = error instanceof AppleSignInCredentialError &&
      error.code === "apple_revocation_unavailable";
  }
  assert(requestStarted && failed, "lost response was not retryable");
  assert(requests === 3, "lost Apple response did not exhaust bounded retries");
  assert(store.records[0].state === "revoking", "retry state was not retained");
  assert(
    cleanForTest(store.records[0].refresh_token_ciphertext).length > 20,
    "credential was destroyed before confirmed revocation",
  );

  let loginBlocked = false;
  try {
    await storedCredential(store);
  } catch (error) {
    loginBlocked = error instanceof AppleSignInCredentialError &&
      error.code === "apple_credential_deletion_in_progress";
  }
  assert(loginBlocked, "partial revocation reopened credential persistence");
});

Deno.test("tampered client binding falls back to manual revocation and scrubs", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  await bindCredential(store, saved.bindingTicket);
  store.records[0].client_id = "com.attacker.app";
  let fetchCalled = false;
  const result = await revokeAppleSignInCredentials({
    store,
    lifecycleStore: lifecycleStoreFor(store),
    email: "operative@privaterelay.appleid.com",
    userID: "base44-user-1",
    pseudonymSecret: PSEUDONYM_SECRET,
    encryptionSecret: ENCRYPTION_SECRET,
    createClientSecret: async () => "must-not-run",
    fetcher: async () => {
      fetchCalled = true;
      return new Response(null, { status: 200 });
    },
  });
  assert(result.manualRevocationRequired, "manual fallback was not reported");
  assert(!fetchCalled, "tampered credential reached Apple");
  assert(store.records[0].state === "revoked", "credential was not terminal");
  assert(
    store.records[0].refresh_token_ciphertext === "",
    "tampered ciphertext was not scrubbed",
  );
});

Deno.test("legacy account without a stored Apple token is not blocked", async () => {
  const store = new MemoryStore();
  const result = await revokeAppleSignInCredentials({
    store,
    lifecycleStore: lifecycleStoreFor(store),
    email: "legacy@example.com",
    userID: "legacy-user",
    pseudonymSecret: PSEUDONYM_SECRET,
    encryptionSecret: ENCRYPTION_SECRET,
    createClientSecret: async () => "unused",
    fetcher: async () => {
      throw new Error("must not call Apple");
    },
  });
  assert(
    result.manualRevocationRequired,
    "legacy account lacked manual guidance",
  );
  assert(
    result.recordIDs.length === 0,
    "legacy account fabricated a credential",
  );
});

Deno.test("same-email credential owned by another account is ignored", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  await bindCredential(store, saved.bindingTicket, "apple-owner");
  let fetchCalled = false;
  const result = await revokeAppleSignInCredentials({
    store,
    lifecycleStore: lifecycleStoreFor(store),
    email: "operative@privaterelay.appleid.com",
    userID: "google-owner",
    pseudonymSecret: PSEUDONYM_SECRET,
    encryptionSecret: ENCRYPTION_SECRET,
    createClientSecret: async () => "unused",
    fetcher: async () => {
      fetchCalled = true;
      return new Response(null, { status: 200 });
    },
  });
  assert(
    result.manualRevocationRequired,
    "unrelated provider account was treated as Apple",
  );
  assert(!fetchCalled, "another account's credential was revoked");
  assert(
    store.records[0].state === "bound",
    "another account's record was changed",
  );
});

Deno.test("zero-row deletion marker blocks a concurrent Apple credential create", async () => {
  const store = new MemoryStore();
  const deletion = await revokeAppleSignInCredentials({
    store,
    lifecycleStore: lifecycleStoreFor(store),
    email: "operative@privaterelay.appleid.com",
    userID: "base44-user-1",
    pseudonymSecret: PSEUDONYM_SECRET,
    encryptionSecret: ENCRYPTION_SECRET,
    createClientSecret: async () => "unused",
    fetcher: async () => new Response(null, { status: 500 }),
  });
  assert(deletion.recordIDs.length === 0, "empty deletion found a token");

  let blocked = false;
  try {
    await storedCredential(store);
  } catch (error) {
    blocked = error instanceof AppleSignInCredentialError &&
      error.code === "apple_credential_deletion_in_progress";
  }
  assert(blocked, "credential create crossed the deletion marker");
  assert(store.records.length === 0, "credential was created after deletion");
});

Deno.test("pre-exchange identity writer blocks deletion and persists under the same lease", async () => {
  const store = new MemoryStore();
  const lifecycleStore = lifecycleStoreFor(store);
  let deletionBlocked = false;
  let bindingBlocked = false;

  await withAppleCredentialIssuanceBoundary({
    lifecycleStore,
    email: "operative@privaterelay.appleid.com",
    now: () => NOW,
    pseudonymSecret: PSEUDONYM_SECRET,
    onOperationError: async () => "retain",
    operation: async (issuanceBoundary) => {
      try {
        await revokeAppleSignInCredentials({
          store,
          lifecycleStore,
          email: "operative@privaterelay.appleid.com",
          userID: "base44-user-1",
          now: () => NOW,
          pseudonymSecret: PSEUDONYM_SECRET,
          encryptionSecret: ENCRYPTION_SECRET,
          createClientSecret: async () => "unused",
          fetcher: async () => new Response(null, { status: 200 }),
        });
      } catch (error) {
        deletionBlocked = error instanceof AppleSignInCredentialError &&
          error.code === "apple_credential_lifecycle_unavailable";
      }

      await persistPendingAppleSignInCredential({
        store,
        lifecycleStore,
        email: "operative@privaterelay.appleid.com",
        subject: "apple-subject-1",
        clientID: "com.spyclash.ios",
        refreshToken: "private-refresh-token",
        now: () => NOW,
        pseudonymSecret: PSEUDONYM_SECRET,
        encryptionSecret: ENCRYPTION_SECRET,
        randomTicket: () => "pre-exchange-ticket",
        issuanceBoundary,
      });

      try {
        await bindCredential(store, "pre-exchange-ticket");
      } catch (error) {
        bindingBlocked = error instanceof AppleSignInCredentialError &&
          error.code === "apple_credential_deletion_in_progress";
      }
    },
  });

  assert(deletionBlocked, "deletion crossed a pre-exchange writer lease");
  assert(bindingBlocked, "binding crossed a pre-exchange writer lease");
  assert(store.records.length === 1, "credential was not durably tracked");
  const bound = await bindCredential(store, "pre-exchange-ticket");
  assert(bound.bound === 1, "credential did not bind after lease release");
});

Deno.test("pending binding is validated before provisioning and binds under one identity writer", async () => {
  const store = new MemoryStore();
  const lifecycleStore = lifecycleStoreFor(store);
  const saved = await storedCredential(store);
  let provisionCalled = false;

  const result = await withPendingAppleCredentialBindingIdentityWriter({
    store,
    lifecycleStore,
    email: "operative@privaterelay.appleid.com",
    bindingTicket: saved.bindingTicket,
    now: () => NOW,
    pseudonymSecret: PSEUDONYM_SECRET,
    operation: async (identityWriter) => {
      provisionCalled = true;
      return await bindPendingAppleSignInCredentials({
        store,
        lifecycleStore,
        email: "operative@privaterelay.appleid.com",
        userID: "base44-user-1",
        bindingTicket: saved.bindingTicket,
        now: () => NOW,
        pseudonymSecret: PSEUDONYM_SECRET,
        identityWriter,
      });
    },
  });
  assert(provisionCalled, "valid binding did not reach provisioning");
  assert(result.bound === 1, "validated binding was not committed");

  const invalidStore = new MemoryStore();
  await storedCredential(invalidStore);
  let invalidProvisionCalled = false;
  let rejected = false;
  try {
    await withPendingAppleCredentialBindingIdentityWriter({
      store: invalidStore,
      lifecycleStore: lifecycleStoreFor(invalidStore),
      email: "operative@privaterelay.appleid.com",
      bindingTicket: "wrong-ticket",
      now: () => NOW,
      pseudonymSecret: PSEUDONYM_SECRET,
      operation: async () => {
        invalidProvisionCalled = true;
      },
    });
  } catch (error) {
    rejected = error instanceof AppleSignInCredentialError &&
      error.code === "apple_credential_binding_invalid";
  }
  assert(rejected, "invalid binding ticket passed the provisioning guard");
  assert(
    !invalidProvisionCalled,
    "invalid binding ticket reached user provisioning",
  );
});

Deno.test("OIDC token guard accepts only a live tracked Apple credential", async () => {
  const store = new MemoryStore();
  const lifecycleStore = lifecycleStoreFor(store);
  await storedCredential(store);

  await withAppleCredentialIdentityWriter({
    lifecycleStore,
    email: "operative@privaterelay.appleid.com",
    now: () => NOW,
    pseudonymSecret: PSEUDONYM_SECRET,
    operation: async (identityWriter) => {
      await assertTrackedAppleSignInCredential({
        store,
        lifecycleStore,
        email: "operative@privaterelay.appleid.com",
        subject: "apple-subject-1",
        clientID: "com.spyclash.ios",
        identityWriter,
        now: () => NOW,
        pseudonymSecret: PSEUDONYM_SECRET,
      });
    },
  });

  store.records[0] = {
    ...store.records[0],
    state: "revoking",
    revision: "deletion-started",
  };
  let rejected = false;
  try {
    await withAppleCredentialIdentityWriter({
      lifecycleStore,
      email: "operative@privaterelay.appleid.com",
      now: () => NOW,
      pseudonymSecret: PSEUDONYM_SECRET,
      operation: async (identityWriter) => {
        await assertTrackedAppleSignInCredential({
          store,
          lifecycleStore,
          email: "operative@privaterelay.appleid.com",
          subject: "apple-subject-1",
          clientID: "com.spyclash.ios",
          identityWriter,
          now: () => NOW,
          pseudonymSecret: PSEUDONYM_SECRET,
        });
      },
    });
  } catch (error) {
    rejected = error instanceof AppleSignInCredentialError &&
      error.code === "apple_credential_untracked";
  }
  assert(rejected, "revoking Apple credential still authorized OIDC tokens");
});

Deno.test("post-exchange failure releases only after compensation or retains the precommitted boundary", async () => {
  for (const disposition of ["release", "retain"] as const) {
    const store = new MemoryStore();
    const lifecycleStore = lifecycleStoreFor(store);
    let compensationCalls = 0;
    let originalFailureObserved = false;
    try {
      await withAppleCredentialIssuanceBoundary({
        lifecycleStore,
        email: "operative@privaterelay.appleid.com",
        now: () => NOW,
        pseudonymSecret: PSEUDONYM_SECRET,
        onOperationError: async (error) => {
          compensationCalls += 1;
          assert(
            error instanceof Error && error.message === "post-exchange failure",
            "compensation received the wrong failure",
          );
          return disposition;
        },
        operation: async () => {
          throw new Error("post-exchange failure");
        },
      });
    } catch (error) {
      originalFailureObserved = error instanceof Error &&
        error.message === "post-exchange failure";
    }
    assert(originalFailureObserved, "post-exchange failure was replaced");
    assert(compensationCalls === 1, "compensation did not run exactly once");

    let nextWriterSucceeded = false;
    let nextWriterBlocked = false;
    try {
      await withAppleCredentialIdentityWriter({
        lifecycleStore,
        email: "operative@privaterelay.appleid.com",
        now: () => NOW,
        pseudonymSecret: PSEUDONYM_SECRET,
        operation: async () => {
          nextWriterSucceeded = true;
        },
      });
    } catch (error) {
      nextWriterBlocked = error instanceof AppleSignInCredentialError &&
        error.code === "apple_credential_deletion_in_progress";
    }

    assert(
      disposition === "release"
        ? nextWriterSucceeded && !nextWriterBlocked
        : nextWriterBlocked && !nextWriterSucceeded,
      `identity boundary did not honor ${disposition} compensation`,
    );
  }
});

Deno.test("retained issuance boundary remains closed after its lease expires", async () => {
  const store = new MemoryStore();
  const lifecycleStore = lifecycleStoreFor(store);
  try {
    await withAppleCredentialIssuanceBoundary({
      lifecycleStore,
      email: "operative@privaterelay.appleid.com",
      now: () => NOW,
      pseudonymSecret: PSEUDONYM_SECRET,
      onOperationError: async () => "retain",
      operation: async () => {
        throw new Error("ambiguous Apple exchange");
      },
    });
  } catch {
    // The original exchange failure is expected; the durable marker is the
    // state under test.
  }

  let reopened = false;
  let blocked = false;
  try {
    await withAppleCredentialIssuanceBoundary({
      lifecycleStore,
      email: "operative@privaterelay.appleid.com",
      now: () => new Date(NOW.getTime() + 11 * 60 * 1_000),
      pseudonymSecret: PSEUDONYM_SECRET,
      onOperationError: async () => "release",
      operation: async () => {
        reopened = true;
      },
    });
  } catch (error) {
    blocked = error instanceof AppleSignInCredentialError &&
      error.code === "apple_credential_deletion_in_progress";
  }
  assert(blocked, "expired quarantine marker allowed another Apple exchange");
  assert(!reopened, "ambiguous Apple issuance boundary reopened after expiry");
});

Deno.test("stale bind CAS cannot overwrite a revoking credential", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  store.beforeNextUpdateMany = () => {
    store.records[0] = {
      ...store.records[0],
      state: "revoking",
      revision: "concurrent-revocation",
    };
  };

  let blocked = false;
  try {
    await bindCredential(store, saved.bindingTicket);
  } catch (error) {
    blocked = error instanceof AppleSignInCredentialError &&
      error.code === "apple_credential_deletion_in_progress";
  }
  assert(blocked, "stale bind was not rejected");
  assert(store.records[0].state === "revoking", "bind regressed state");
  assert(!store.records[0].user_id, "stale bind changed ownership");
});

Deno.test("deterministic Apple 4xx becomes manual terminal cleanup", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  await bindCredential(store, saved.bindingTicket);
  let requests = 0;
  const result = await revokeAppleSignInCredentials({
    store,
    lifecycleStore: lifecycleStoreFor(store),
    email: "operative@privaterelay.appleid.com",
    userID: "base44-user-1",
    pseudonymSecret: PSEUDONYM_SECRET,
    encryptionSecret: ENCRYPTION_SECRET,
    createClientSecret: async () => "signed-client-secret",
    fetcher: async () => {
      requests += 1;
      return new Response(null, { status: 400 });
    },
  });
  assert(requests === 1, "Apple 4xx was retried unexpectedly");
  assert(result.manualRevocationRequired, "manual fallback was not reported");
  assert(store.records[0].state === "revoked", "4xx was not terminal");
  assert(
    store.records[0].refresh_token_ciphertext === "",
    "4xx retained encrypted bearer material",
  );
});

Deno.test("Apple 5xx remains retryable and retains encrypted credential", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  await bindCredential(store, saved.bindingTicket);
  let requests = 0;
  let retryable = false;
  try {
    await revokeAppleSignInCredentials({
      store,
      lifecycleStore: lifecycleStoreFor(store),
      email: "operative@privaterelay.appleid.com",
      userID: "base44-user-1",
      pseudonymSecret: PSEUDONYM_SECRET,
      encryptionSecret: ENCRYPTION_SECRET,
      createClientSecret: async () => "signed-client-secret",
      sleepBeforeRetry: async () => {},
      fetcher: async () => {
        requests += 1;
        return new Response(null, { status: 503 });
      },
    });
  } catch (error) {
    retryable = error instanceof AppleSignInCredentialError &&
      error.code === "apple_revocation_unavailable";
  }
  assert(retryable, "Apple 5xx was not surfaced as retryable");
  assert(requests === 3, "Apple 5xx did not exhaust bounded retries");
  assert(store.records[0].state === "revoking", "retry state was lost");
  assert(
    cleanForTest(store.records[0].refresh_token_ciphertext).length > 20,
    "retryable Apple failure destroyed the credential",
  );
});

Deno.test("Apple revocation retry resumes after the retained deletion marker expires", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  await bindCredential(store, saved.bindingTicket);
  let now = NOW;
  let requests = 0;

  try {
    await revokeAppleSignInCredentials({
      store,
      lifecycleStore: lifecycleStoreFor(store),
      email: "operative@privaterelay.appleid.com",
      userID: "base44-user-1",
      now: () => now,
      pseudonymSecret: PSEUDONYM_SECRET,
      encryptionSecret: ENCRYPTION_SECRET,
      createClientSecret: async () => "signed-client-secret",
      sleepBeforeRetry: async () => {},
      fetcher: async () => {
        requests += 1;
        return new Response(null, { status: 503 });
      },
    });
  } catch (error) {
    assert(
      error instanceof AppleSignInCredentialError &&
        error.code === "apple_revocation_unavailable",
      "first Apple failure was not retryable",
    );
  }

  let immediateRetryBlocked = false;
  try {
    await revokeAppleSignInCredentials({
      store,
      lifecycleStore: lifecycleStoreFor(store),
      email: "operative@privaterelay.appleid.com",
      userID: "base44-user-1",
      now: () => now,
      pseudonymSecret: PSEUDONYM_SECRET,
      encryptionSecret: ENCRYPTION_SECRET,
      createClientSecret: async () => "unused",
      fetcher: async () => new Response(null, { status: 200 }),
    });
  } catch (error) {
    immediateRetryBlocked = error instanceof AppleSignInCredentialError &&
      error.code === "apple_credential_lifecycle_unavailable";
  }
  assert(immediateRetryBlocked, "live deletion marker was bypassed");

  now = new Date(NOW.getTime() + 11 * 60 * 1_000);
  const resumed = await revokeAppleSignInCredentials({
    store,
    lifecycleStore: lifecycleStoreFor(store),
    email: "operative@privaterelay.appleid.com",
    userID: "base44-user-1",
    now: () => now,
    pseudonymSecret: PSEUDONYM_SECRET,
    encryptionSecret: ENCRYPTION_SECRET,
    createClientSecret: async () => "signed-client-secret",
    fetcher: async () => {
      requests += 1;
      return new Response(null, { status: 200 });
    },
  });
  assert(resumed.revoked === 1, "expired-marker retry did not revoke");
  assert(requests === 4, "revocation retry sent an unexpected request count");
  assert(store.records[0].state === "revoked", "retry was not terminal");
  await releaseBillingDeletionMarker(
    lifecycleStoreFor(store),
    resumed.identityDeletionMarker,
    now,
  );
});

Deno.test("persistent Apple 5xx becomes manual cleanup on the resumed cycle", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  await bindCredential(store, saved.bindingTicket);
  let now = NOW;
  let requests = 0;
  let firstRetryable = false;

  try {
    await revokeAppleSignInCredentials({
      store,
      lifecycleStore: lifecycleStoreFor(store),
      email: "operative@privaterelay.appleid.com",
      userID: "base44-user-1",
      now: () => now,
      pseudonymSecret: PSEUDONYM_SECRET,
      encryptionSecret: ENCRYPTION_SECRET,
      createClientSecret: async () => "signed-client-secret",
      sleepBeforeRetry: async () => {},
      fetcher: async () => {
        requests += 1;
        return new Response(null, { status: 503 });
      },
    });
  } catch (error) {
    firstRetryable = error instanceof AppleSignInCredentialError &&
      error.code === "apple_revocation_unavailable";
  }

  assert(firstRetryable, "first Apple 5xx cycle was not retryable");
  assert(requests === 3, "first Apple 5xx cycle used unexpected retries");
  assert(store.records[0].state === "revoking", "first cycle lost retry state");
  assert(
    cleanForTest(store.records[0].refresh_token_ciphertext).length > 20,
    "first cycle destroyed the encrypted credential",
  );

  now = new Date(NOW.getTime() + 11 * 60 * 1_000);
  const resumed = await revokeAppleSignInCredentials({
    store,
    lifecycleStore: lifecycleStoreFor(store),
    email: "operative@privaterelay.appleid.com",
    userID: "base44-user-1",
    now: () => now,
    pseudonymSecret: PSEUDONYM_SECRET,
    encryptionSecret: ENCRYPTION_SECRET,
    createClientSecret: async () => "signed-client-secret",
    sleepBeforeRetry: async () => {},
    fetcher: async () => {
      requests += 1;
      return new Response(null, { status: 503 });
    },
  });

  assert(
    Number(requests) === 6,
    "resumed Apple 5xx cycle used unexpected retries",
  );
  assert(resumed.revoked === 0, "unconfirmed Apple revocation was counted");
  assert(resumed.manualRevocationRequired, "manual fallback was not reported");
  assert(
    cleanForTest(store.records[0].state) === "revoked",
    "manual fallback was not terminal",
  );
  assert(
    store.records[0].refresh_token_ciphertext === "",
    "manual fallback retained encrypted bearer material",
  );
});

Deno.test("persistent Apple transport failure becomes manual cleanup on the resumed cycle", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  await bindCredential(store, saved.bindingTicket);
  let now = NOW;
  let requests = 0;
  let firstRetryable = false;

  try {
    await revokeAppleSignInCredentials({
      store,
      lifecycleStore: lifecycleStoreFor(store),
      email: "operative@privaterelay.appleid.com",
      userID: "base44-user-1",
      now: () => now,
      pseudonymSecret: PSEUDONYM_SECRET,
      encryptionSecret: ENCRYPTION_SECRET,
      createClientSecret: async () => "signed-client-secret",
      sleepBeforeRetry: async () => {},
      fetcher: async () => {
        requests += 1;
        throw new TypeError("network lost after send");
      },
    });
  } catch (error) {
    firstRetryable = error instanceof AppleSignInCredentialError &&
      error.code === "apple_revocation_unavailable";
  }

  assert(firstRetryable, "first transport-failure cycle was not retryable");
  assert(
    requests === 3,
    "first transport-failure cycle used unexpected retries",
  );
  assert(store.records[0].state === "revoking", "first cycle lost retry state");
  assert(
    cleanForTest(store.records[0].refresh_token_ciphertext).length > 20,
    "first cycle destroyed the encrypted credential",
  );

  now = new Date(NOW.getTime() + 11 * 60 * 1_000);
  const resumed = await revokeAppleSignInCredentials({
    store,
    lifecycleStore: lifecycleStoreFor(store),
    email: "operative@privaterelay.appleid.com",
    userID: "base44-user-1",
    now: () => now,
    pseudonymSecret: PSEUDONYM_SECRET,
    encryptionSecret: ENCRYPTION_SECRET,
    createClientSecret: async () => "signed-client-secret",
    sleepBeforeRetry: async () => {},
    fetcher: async () => {
      requests += 1;
      throw new TypeError("network lost after send");
    },
  });

  assert(
    Number(requests) === 6,
    "resumed transport cycle used unexpected retries",
  );
  assert(resumed.revoked === 0, "unconfirmed Apple revocation was counted");
  assert(resumed.manualRevocationRequired, "manual fallback was not reported");
  assert(
    cleanForTest(store.records[0].state) === "revoked",
    "manual fallback was not terminal",
  );
  assert(
    store.records[0].refresh_token_ciphertext === "",
    "manual fallback retained encrypted bearer material",
  );
});

Deno.test("multi-record resumed fallback keeps each fresh credential fail-closed for one lease window", async () => {
  const store = new MemoryStore();
  const firstSaved = await storedCredential(store, {
    token: "first-private-refresh-token",
  });
  const secondSaved = await storedCredential(store, {
    subject: "apple-subject-2",
    token: "second-private-refresh-token",
  });
  const bound = await bindCredential(store, firstSaved.bindingTicket);
  assert(
    bound.bound === 2,
    "multi-record fixture did not bind both credentials",
  );

  const firstID = firstSaved.recordIDs[0];
  const secondID = secondSaved.recordIDs[0];
  const credential = (id: string) => {
    const record = store.records.find((candidate) => candidate.id === id);
    assert(record, `credential ${id} is missing`);
    return record;
  };
  let now = NOW;
  let requests = 0;
  const attempt = () =>
    revokeAppleSignInCredentials({
      store,
      lifecycleStore: lifecycleStoreFor(store),
      email: "operative@privaterelay.appleid.com",
      userID: "base44-user-1",
      now: () => now,
      pseudonymSecret: PSEUDONYM_SECRET,
      encryptionSecret: ENCRYPTION_SECRET,
      createClientSecret: async () => "signed-client-secret",
      sleepBeforeRetry: async () => {},
      fetcher: async () => {
        requests += 1;
        return new Response(null, { status: 503 });
      },
    });

  let firstRetryable = false;
  try {
    await attempt();
  } catch (error) {
    firstRetryable = error instanceof AppleSignInCredentialError &&
      error.code === "apple_revocation_unavailable";
  }
  assert(firstRetryable, "first multi-record cycle was not retryable");
  assert(requests === 3, "first multi-record cycle used unexpected retries");
  assert(
    credential(firstID).state === "revoking",
    "first credential did not retain retry state",
  );
  assert(
    cleanForTest(credential(firstID).refresh_token_ciphertext).length > 20,
    "first credential was scrubbed during its initial cycle",
  );
  assert(
    credential(secondID).state === "bound",
    "unvisited second credential changed during the first cycle",
  );

  let immediateRetryBlocked = false;
  try {
    await attempt();
  } catch (error) {
    immediateRetryBlocked = error instanceof AppleSignInCredentialError &&
      error.code === "apple_credential_lifecycle_unavailable";
  }
  assert(immediateRetryBlocked, "live first-cycle marker was bypassed");
  assert(requests === 3, "blocked retry reached Apple");

  now = new Date(NOW.getTime() + 11 * 60 * 1_000);
  let resumedRetryable = false;
  try {
    await attempt();
  } catch (error) {
    resumedRetryable = error instanceof AppleSignInCredentialError &&
      error.code === "apple_revocation_unavailable";
  }
  assert(
    resumedRetryable,
    "resumed cycle did not fail closed on the fresh second credential",
  );
  assert(
    Number(requests) === 9,
    "resumed multi-record cycle used unexpected retries",
  );
  assert(
    cleanForTest(credential(firstID).state) === "revoked",
    "previously revoking credential was not terminal",
  );
  assert(
    credential(firstID).manual_revocation_required === true,
    "first credential lost its manual fallback receipt",
  );
  assert(
    credential(firstID).refresh_token_ciphertext === "",
    "first credential retained bearer material after terminal fallback",
  );
  assert(
    credential(secondID).state === "revoking",
    "fresh second credential did not enter retry state",
  );
  assert(
    cleanForTest(credential(secondID).refresh_token_ciphertext).length > 20,
    "fresh second credential was scrubbed before its resumed cycle",
  );

  let secondImmediateRetryBlocked = false;
  try {
    await attempt();
  } catch (error) {
    secondImmediateRetryBlocked = error instanceof AppleSignInCredentialError &&
      error.code === "apple_credential_lifecycle_unavailable";
  }
  assert(
    secondImmediateRetryBlocked,
    "live second-cycle marker was bypassed",
  );
  assert(Number(requests) === 9, "blocked second-cycle retry reached Apple");

  now = new Date(NOW.getTime() + 22 * 60 * 1_000);
  const completed = await attempt();
  assert(
    Number(requests) === 12,
    "final multi-record cycle used unexpected retries",
  );
  assert(completed.revoked === 0, "unconfirmed revocations were counted");
  assert(
    completed.manualRevocationRequired,
    "manual fallback receipt did not survive the partial prior cycle",
  );
  assert(
    cleanForTest(credential(firstID).state) === "revoked" &&
      cleanForTest(credential(secondID).state) === "revoked",
    "multi-record fallback did not finish terminally",
  );
  assert(
    credential(firstID).refresh_token_ciphertext === "" &&
      credential(secondID).refresh_token_ciphertext === "",
    "multi-record fallback retained bearer material",
  );

  await releaseBillingDeletionMarker(
    lifecycleStoreFor(store),
    completed.identityDeletionMarker,
    now,
  );
});

Deno.test("transient Apple 503 recovers within one deletion attempt", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  await bindCredential(store, saved.bindingTicket);
  const delays: number[] = [];
  let requests = 0;

  const result = await revokeAppleSignInCredentials({
    store,
    lifecycleStore: lifecycleStoreFor(store),
    email: "operative@privaterelay.appleid.com",
    userID: "base44-user-1",
    pseudonymSecret: PSEUDONYM_SECRET,
    encryptionSecret: ENCRYPTION_SECRET,
    createClientSecret: async () => "signed-client-secret",
    sleepBeforeRetry: async (milliseconds) => {
      delays.push(milliseconds);
    },
    fetcher: async () => {
      requests += 1;
      return new Response(null, { status: requests === 1 ? 503 : 200 });
    },
  });

  assert(result.revoked === 1, "transient Apple failure did not recover");
  assert(requests === 2, "transient Apple failure used unexpected retries");
  assert(
    JSON.stringify(delays) === JSON.stringify([250]),
    "transient Apple retry used an unexpected backoff",
  );
  assert(store.records[0].state === "revoked", "retry was not committed");
});

Deno.test("transient Apple transport failure recovers within one deletion attempt", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  await bindCredential(store, saved.bindingTicket);
  const delays: number[] = [];
  let requests = 0;

  const result = await revokeAppleSignInCredentials({
    store,
    lifecycleStore: lifecycleStoreFor(store),
    email: "operative@privaterelay.appleid.com",
    userID: "base44-user-1",
    pseudonymSecret: PSEUDONYM_SECRET,
    encryptionSecret: ENCRYPTION_SECRET,
    createClientSecret: async () => "signed-client-secret",
    sleepBeforeRetry: async (milliseconds) => {
      delays.push(milliseconds);
    },
    fetcher: async () => {
      requests += 1;
      if (requests === 1) throw new TypeError("temporary network failure");
      return new Response(null, { status: 200 });
    },
  });

  assert(result.revoked === 1, "transport failure did not recover");
  assert(requests === 2, "transport failure used unexpected retries");
  assert(
    JSON.stringify(delays) === JSON.stringify([250]),
    "transport retry used an unexpected backoff",
  );
  assert(store.records[0].state === "revoked", "retry was not committed");
});

Deno.test("unexpected Apple signer failure remains retryable and retains encrypted credential", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  await bindCredential(store, saved.bindingTicket);
  let retryable = false;
  let fetchCalled = false;
  try {
    await revokeAppleSignInCredentials({
      store,
      lifecycleStore: lifecycleStoreFor(store),
      email: "operative@privaterelay.appleid.com",
      userID: "base44-user-1",
      pseudonymSecret: PSEUDONYM_SECRET,
      encryptionSecret: ENCRYPTION_SECRET,
      createClientSecret: async () => {
        throw new Error("signer temporarily unavailable");
      },
      fetcher: async () => {
        fetchCalled = true;
        return new Response(null, { status: 200 });
      },
    });
  } catch (error) {
    retryable = error instanceof AppleSignInCredentialError &&
      error.code === "apple_revocation_unavailable";
  }
  assert(retryable, "unexpected signer failure was not retryable");
  assert(!fetchCalled, "unsigned credential reached Apple");
  assert(store.records[0].state === "revoking", "retry state was lost");
  assert(
    cleanForTest(store.records[0].refresh_token_ciphertext).length > 20,
    "signer failure destroyed the credential",
  );
});

Deno.test("persistent Apple signer failure becomes manual cleanup on the resumed cycle", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  await bindCredential(store, saved.bindingTicket);
  let now = NOW;
  let signerAttempts = 0;
  let firstRetryable = false;

  try {
    await revokeAppleSignInCredentials({
      store,
      lifecycleStore: lifecycleStoreFor(store),
      email: "operative@privaterelay.appleid.com",
      userID: "base44-user-1",
      now: () => now,
      pseudonymSecret: PSEUDONYM_SECRET,
      encryptionSecret: ENCRYPTION_SECRET,
      createClientSecret: async () => {
        signerAttempts += 1;
        throw new Error("signer temporarily unavailable");
      },
      fetcher: async () => {
        throw new Error("must not call Apple without a client secret");
      },
    });
  } catch (error) {
    firstRetryable = error instanceof AppleSignInCredentialError &&
      error.code === "apple_revocation_unavailable";
  }

  assert(firstRetryable, "first signer-failure cycle was not retryable");
  assert(
    signerAttempts === 1,
    "first signer-failure cycle retried unexpectedly",
  );
  assert(store.records[0].state === "revoking", "first cycle lost retry state");
  assert(
    cleanForTest(store.records[0].refresh_token_ciphertext).length > 20,
    "first cycle destroyed the encrypted credential",
  );

  now = new Date(NOW.getTime() + 11 * 60 * 1_000);
  const resumed = await revokeAppleSignInCredentials({
    store,
    lifecycleStore: lifecycleStoreFor(store),
    email: "operative@privaterelay.appleid.com",
    userID: "base44-user-1",
    now: () => now,
    pseudonymSecret: PSEUDONYM_SECRET,
    encryptionSecret: ENCRYPTION_SECRET,
    createClientSecret: async () => {
      signerAttempts += 1;
      throw new Error("signer temporarily unavailable");
    },
    fetcher: async () => {
      throw new Error("must not call Apple without a client secret");
    },
  });

  assert(
    Number(signerAttempts) === 2,
    "resumed signer cycle retried unexpectedly",
  );
  assert(resumed.revoked === 0, "unconfirmed Apple revocation was counted");
  assert(resumed.manualRevocationRequired, "manual fallback was not reported");
  assert(
    cleanForTest(store.records[0].state) === "revoked",
    "manual fallback was not terminal",
  );
  assert(
    store.records[0].refresh_token_ciphertext === "",
    "manual fallback retained encrypted bearer material",
  );
});

Deno.test("typed unavailable revocation configuration falls back to manual cleanup", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  await bindCredential(store, saved.bindingTicket);
  let fetchCalled = false;
  const result = await revokeAppleSignInCredentials({
    store,
    lifecycleStore: lifecycleStoreFor(store),
    email: "operative@privaterelay.appleid.com",
    userID: "base44-user-1",
    pseudonymSecret: PSEUDONYM_SECRET,
    encryptionSecret: ENCRYPTION_SECRET,
    createClientSecret: async () => {
      throw new AppleSignInCredentialError(
        "apple_revocation_configuration_unavailable",
        503,
        "configured Apple key is unavailable",
      );
    },
    fetcher: async () => {
      fetchCalled = true;
      return new Response(null, { status: 200 });
    },
  });
  assert(result.manualRevocationRequired, "manual fallback was not reported");
  assert(!fetchCalled, "credential reached Apple without a client secret");
  assert(store.records[0].state === "revoked", "credential was not terminal");
  assert(
    store.records[0].refresh_token_ciphertext === "",
    "manual fallback retained the credential",
  );
});

Deno.test("strict cleanup reconciles a lost delete response", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  store.throwDeleteAfterApply = true;
  await deleteAppleSignInCredentialRecords(store, saved.recordIDs);
  assert(store.records.length === 0, "lost response was not reconciled");
});

Deno.test("strict cleanup rejects a credential that remains present", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  store.throwDeleteBeforeApply = true;
  let rejected = false;
  try {
    await deleteAppleSignInCredentialRecords(store, saved.recordIDs);
  } catch (error) {
    rejected = error instanceof AppleSignInCredentialError &&
      error.code === "apple_credential_cleanup_failed";
  }
  assert(rejected, "surviving credential was treated as deleted");
  assert(store.records.length === 1, "failing delete mutated the credential");
});

Deno.test("strict cleanup rejects an explicit unsuccessful delete result", async () => {
  const store = new MemoryStore();
  const saved = await storedCredential(store);
  store.deleteReturnsFailure = true;
  let rejected = false;
  try {
    await deleteAppleSignInCredentialRecords(store, saved.recordIDs);
  } catch (error) {
    rejected = error instanceof AppleSignInCredentialError &&
      error.code === "apple_credential_cleanup_failed";
  }
  assert(rejected, "success=false was treated as a committed delete");
  assert(store.records.length === 1, "unsuccessful delete removed the row");
});

function cleanForTest(value: unknown): string {
  return String(value ?? "").trim();
}
