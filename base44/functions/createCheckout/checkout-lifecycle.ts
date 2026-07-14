import {
  acquireBillingWriterLease,
  assertBillingWriterLease,
  releaseBillingWriterLease,
} from "./billing-identity-lifecycle.ts";

/** Acquires, then reasserts the exact nonexpired lease at session creation. */
export async function withCheckoutBillingLease<T>(input: {
  lifecycleStore: any;
  userID: string;
  createSession: () => Promise<T>;
  nowFactory?: () => Date;
  randomUUID?: () => string;
}): Promise<T> {
  const nowFactory = input.nowFactory || (() => new Date());
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  const lease = await acquireBillingWriterLease(
    input.lifecycleStore,
    input.userID,
    nowFactory,
    randomUUID,
  );
  try {
    await assertBillingWriterLease(
      input.lifecycleStore,
      lease,
      nowFactory(),
    );
    return await input.createSession();
  } finally {
    await releaseBillingWriterLease(
      input.lifecycleStore,
      lease,
      nowFactory(),
      randomUUID,
    );
  }
}
