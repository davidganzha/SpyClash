import { isAppleAccountLeaseActive } from "./apple-account-binding.ts";

const PAGE_SIZE = 100;

export type AppleAccountLeaseGuard = {
  accountID: string;
  ownerUserID: string;
  leaseUntil: string;
};

export class AppleAccountLeaseGuardError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AppleAccountLeaseGuardError";
  }
}

/** Reasserts exact ownership and nonexpiry immediately before a retained write. */
export async function assertAppleAccountLease(
  store: any,
  lease: AppleAccountLeaseGuard,
  now = new Date(),
): Promise<void> {
  if (!isAppleAccountLeaseActive(lease.leaseUntil, now)) {
    throw new AppleAccountLeaseGuardError(
      "Apple account coordination lease expired before persistence.",
    );
  }
  const records: Array<Record<string, unknown>> = [];
  for (let skip = 0;; skip += PAGE_SIZE) {
    const page = await store.filter(
      {
        id: lease.accountID,
        user_id: lease.ownerUserID,
        last_used_at: lease.leaseUntil,
      },
      "created_date",
      PAGE_SIZE,
      skip,
    ) || [];
    records.push(...page);
    if (page.length < PAGE_SIZE) break;
  }
  if (records.length !== 1) {
    throw new AppleAccountLeaseGuardError(
      "Apple account coordination lease changed before persistence.",
    );
  }
}
