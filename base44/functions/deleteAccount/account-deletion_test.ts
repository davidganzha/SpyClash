import {
  entitlementRetentionPatch,
  REDACTED_ENTITLEMENT_EMAIL,
} from "./account-deletion.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("retained entitlement identity is replaced with a stable tombstone", async () => {
  const first = await entitlementRetentionPatch(" user-123 ");
  const repeated = await entitlementRetentionPatch("user-123");
  const anotherUser = await entitlementRetentionPatch("user-456");

  assert(first.user_id === repeated.user_id, "tombstone was not stable");
  assert(first.user_id !== anotherUser.user_id, "accounts shared a tombstone");
  assert(!first.user_id.includes("user-123"), "raw user id was retained");
  assert(
    first.user_email === REDACTED_ENTITLEMENT_EMAIL,
    "email was not redacted",
  );
});

Deno.test("retention patch does not overwrite provider or billing identifiers", async () => {
  const record = {
    source_key: "apple:original-transaction-1",
    provider: "apple",
    original_transaction_id: "original-transaction-1",
    transaction_id: "transaction-2",
    app_account_token: "00000000-0000-4000-8000-000000000001",
    user_id: "user-123",
    user_email: "operative@example.com",
  };
  const retained = {
    ...record,
    ...await entitlementRetentionPatch(record.user_id),
  };

  assert(retained.source_key === record.source_key, "source key was changed");
  assert(retained.provider === record.provider, "provider was changed");
  assert(
    retained.original_transaction_id === record.original_transaction_id,
    "original transaction id was changed",
  );
  assert(
    retained.transaction_id === record.transaction_id,
    "transaction id was changed",
  );
  assert(
    retained.app_account_token === record.app_account_token,
    "billing account token was changed",
  );
  assert(
    Object.keys(await entitlementRetentionPatch(record.user_id)).sort().join(
      ",",
    ) ===
      "user_email,user_id",
    "retention patch touched fields outside direct account identity",
  );
});

Deno.test("the Apple account reservation can keep its token without the Base44 user id", async () => {
  const record = {
    user_id: "user-123",
    app_account_token: "00000000-0000-4000-8000-000000000001",
    created_at: "2026-07-14T00:00:00.000Z",
    last_used_at: "2026-07-14T01:00:00.000Z",
  };
  const retainedIdentity = await entitlementRetentionPatch(record.user_id);
  const retained = {
    ...record,
    user_id: retainedIdentity.user_id,
  };

  assert(
    retained.user_id !== record.user_id,
    "raw Base44 user id was retained",
  );
  assert(
    retained.app_account_token === record.app_account_token,
    "Apple token needed for future provider notifications was changed",
  );
  assert(
    retained.created_at === record.created_at,
    "creation audit date was changed",
  );
  assert(
    retained.last_used_at === record.last_used_at,
    "usage audit date was changed",
  );
});

Deno.test("retention patch rejects an empty account id", async () => {
  let rejected = false;
  try {
    await entitlementRetentionPatch("   ");
  } catch {
    rejected = true;
  }
  assert(rejected, "empty account id produced a shared tombstone");
});
