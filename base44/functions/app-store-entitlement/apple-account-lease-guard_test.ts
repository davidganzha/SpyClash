import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  AppleAccountLeaseGuardError,
  assertAppleAccountLease,
} from "./apple-account-lease-guard.ts";

const LEASE_UNTIL = "2026-07-14T12:05:00.000Z";

Deno.test("suspended Apple writer cannot persist after deletion takes the lease", async () => {
  const records = [{
    id: "account-1",
    user_id: "user-1",
    last_used_at: LEASE_UNTIL,
  }];
  const store = {
    filter: (
      filter: Record<string, unknown>,
      _sort: string,
      limit: number,
      skip: number,
    ) =>
      Promise.resolve(
        records.filter((record) =>
          Object.entries(filter).every(([key, value]) =>
            record[key as keyof typeof record] === value
          )
        ).slice(skip, skip + limit),
      ),
  };
  const lease = {
    accountID: "account-1",
    ownerUserID: "user-1",
    leaseUntil: LEASE_UNTIL,
  };
  await assertAppleAccountLease(
    store,
    lease,
    new Date("2026-07-14T12:00:00.000Z"),
  );

  records[0].user_id = `deleted:${"a".repeat(40)}`;
  records[0].last_used_at = "2026-07-14T12:16:00.000Z";
  let writes = 0;
  const error = await assertRejects(
    async () => {
      await assertAppleAccountLease(
        store,
        lease,
        new Date("2026-07-14T12:11:00.000Z"),
      );
      writes += 1;
    },
    AppleAccountLeaseGuardError,
  );
  assertEquals(error.message.includes("expired"), true);
  assertEquals(writes, 0);
});
