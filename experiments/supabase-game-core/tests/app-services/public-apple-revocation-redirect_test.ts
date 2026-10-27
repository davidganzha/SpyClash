import {
  type AppleSignInCredentialRecord,
  type AppleSignInCredentialStore,
  bindPendingAppleSignInCredentials,
  deleteAppleSignInCredentialRecords,
  persistPendingAppleSignInCredential,
  revokeAppleSignInCredentials,
} from "../../base44-prepared/deleteAccount/apple-sign-in-credential.ts";
import {
  completeDeletionReceipt,
  deletionReceiptStatus,
  markDeletionReceiptReady,
  prepareDeletionReceipt,
} from "../../base44-prepared/deleteAccount/deletion-receipt.ts";
import { deleteUserRecord } from "../../base44-prepared/deleteAccount/user-deletion.ts";

function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

class MemoryStore implements AppleSignInCredentialStore {
  records: AppleSignInCredentialRecord[] = [];
  async filter(query: Record<string, unknown>, _sort?: string, limit = 100, skip = 0) {
    return this.records.filter((row) => Object.entries(query).every(([key, value]) =>
      (row as Record<string, unknown>)[key] === value
    )).slice(skip, skip + limit).map((row) => ({ ...row }));
  }
  async create(data: Record<string, unknown>) {
    const row = { id: `fixture-${this.records.length + 1}`, ...data };
    this.records.push(row);
    return { ...row };
  }
  async updateMany(query: Record<string, unknown>, update: Record<string, unknown>) {
    assert(update.$set && typeof update.$set === "object", "test store requires a set update");
    const changes = update.$set as Record<string, unknown>;
    let updated = 0;
    this.records = this.records.map((row) => {
      if (!Object.entries(query).every(([key, value]) => (row as Record<string, unknown>)[key] === value)) return row;
      updated += 1;
      return { ...row, ...changes };
    });
    return { success: true, updated, has_more: false };
  }
  async delete(id: string) {
    this.records = this.records.filter((row) => row.id !== id);
    return { success: true };
  }
}

async function fixture() {
  const store = new MemoryStore(), lifecycleStore = new MemoryStore();
  const identity = { store, lifecycleStore, email: "fixture@example.test", userID: "fixture-user",
    pseudonymSecret: "p".repeat(32), encryptionSecret: "11".repeat(32) };
  const saved = await persistPendingAppleSignInCredential({ ...identity, subject: "fixture-subject",
    clientID: "com.spyclash.ios", refreshToken: "private-refresh-fixture", randomTicket: () => "fixture-ticket" });
  await bindPendingAppleSignInCredentials({ ...identity, bindingTicket: saved.bindingTicket });
  return { ...identity, createClientSecret: async () => "private-client-secret-fixture" };
}

for (const status of [200, 301, 302, 303, 307, 308]) {
  Deno.test(`public Apple revocation handles ${status} without forwarding credentials`, async () => {
    const input = await fixture();
    const urls: string[] = [];
    let retries = 0;
    const result = await revokeAppleSignInCredentials({ ...input,
      sleepBeforeRetry: async () => { retries += 1; },
      fetcher: async (url, init) => {
        // Model Workers' request construction, which rejects error mode even
        // for a successful endpoint. Also prohibit its default follow mode.
        if (init?.redirect === "error") throw new TypeError("Unsupported redirect mode");
        assert(init?.redirect === "manual", "credentials could follow a redirect");
        urls.push(String(url));
        assert(init?.method === "POST", "revocation method changed");
        assert(init.signal instanceof AbortSignal, "request lost its timeout");
        const body = init.body as URLSearchParams;
        assert(body.get("client_secret") === "private-client-secret-fixture", "client secret missing");
        assert(body.get("token") === "private-refresh-fixture", "refresh token missing");
        return new Response(null, { status, headers: status === 200 ? {} : {
          Location: "https://must-not-receive-credentials.example/revoke",
        } });
      },
    });
    assert(JSON.stringify(urls) === JSON.stringify(["https://appleid.apple.com/auth/revoke"]),
      "a redirect or retry sent an additional request");
    assert(retries === 0, "redirect unexpectedly entered retry loop");
    assert(result.revoked === (status === 200 ? 1 : 0), "unconfirmed redirect counted as revoked");
    assert(result.manualRevocationRequired === (status !== 200), "manual revocation status is incorrect");
    const row = input.store.records[0];
    assert(row.state === "revoked", "existing terminal cleanup changed");
    assert(row.manual_revocation_required === (status !== 200), "manual receipt lost");
    assert(row.refresh_token_ciphertext === "" && row.refresh_token_iv === "",
      "terminal cleanup retained encrypted bearer material");
  });
}

Deno.test("public deletion removes owned and exact-selector tokens while preserving unrelated pending credentials", async () => {
  const input = await fixture();
  const matchingPending = await persistPendingAppleSignInCredential({ ...input,
    subject: "fixture-second-subject", clientID: "com.spyclash.ios",
    refreshToken: "private-matching-pending-token", randomTicket: () => "matching-ticket" });
  const unrelatedPending = await persistPendingAppleSignInCredential({ ...input,
    email: "unrelated@example.test", subject: "fixture-unrelated-subject", clientID: "com.spyclash.ios",
    refreshToken: "private-unrelated-token", randomTicket: () => "unrelated-ticket",
    now: () => new Date(Date.now() - 3_600_000) });
  const unrelated = input.store.records.find((row) => row.id === unrelatedPending.recordIDs[0])!;
  assert(unrelated.state === "pending" && !unrelated.user_id, "unrelated fixture must have no bound owner");
  assert(Date.parse(String(unrelated.binding_ticket_expires_at)) < Date.now(), "fixture ticket must be expired");
  const before = JSON.stringify(unrelated);
  let revocations = 0;
  const result = await revokeAppleSignInCredentials({ ...input, fetcher: async (_url, init) => {
    const token = (init?.body as URLSearchParams).get("token");
    assert(token !== "private-unrelated-token", "unrelated credential reached Apple");
    revocations += 1;
    return new Response(null, { status: 200 });
  } });
  assert(revocations === 2 && result.revoked === 2, "own bound and matching pending credentials must be revoked");
  assert(result.recordIDs.includes(matchingPending.recordIDs[0]), "exact owned selector was not cleaned");
  assert(!result.recordIDs.includes(unrelated.id!), "unrelated record entered deletion scope");
  await deleteAppleSignInCredentialRecords(input.store, result.recordIDs);
  assert(input.store.records.length === 1 && JSON.stringify(input.store.records[0]) === before,
    "unrelated encrypted pending credential must remain byte-for-byte unchanged");
});

Deno.test("public deletion without an owned Apple token completes its receipt with manual revocation guidance", async () => {
  const store = new MemoryStore(), lifecycleStore = new MemoryStore(), users = new MemoryStore(), receipts = new MemoryStore();
  const userID = "fixture-missing-token-user", body = { request_id: crypto.randomUUID(), recovery_token: "23".repeat(32) };
  await users.create({ id: userID, email: "missing-token@example.test" });
  const receipt = await prepareDeletionReceipt(receipts, userID, body);
  const result = await revokeAppleSignInCredentials({ store, lifecycleStore, userID,
    email: "missing-token@example.test", pseudonymSecret: "p".repeat(32), encryptionSecret: "11".repeat(32),
    createClientSecret: async () => { throw new Error("missing token must not request Apple credentials"); },
    fetcher: async () => { throw new Error("missing token must not call Apple"); },
  });
  assert(result.manualRevocationRequired && result.recordIDs.length === 0, "missing token lost manual fallback");
  await deleteAppleSignInCredentialRecords(store, result.recordIDs);
  await markDeletionReceiptReady(receipts, receipt, result.manualRevocationRequired);
  assert(!(await deletionReceiptStatus(receipts, users, body)).complete, "live user was prematurely reported deleted");
  await deleteUserRecord(users, userID);
  await completeDeletionReceipt(receipts, receipt, result.manualRevocationRequired);
  const completed = await deletionReceiptStatus(receipts, users, body);
  assert(completed.complete && completed.manual_apple_revocation_required,
    "completed deletion must retain the existing client manual-revocation signal");
  assert(users.records.length === 0 && store.records.length === 0, "missing-token account was not deleted");
  assert(receipts.records[0].user_id === "", "completed receipt retained the account identifier");
});
