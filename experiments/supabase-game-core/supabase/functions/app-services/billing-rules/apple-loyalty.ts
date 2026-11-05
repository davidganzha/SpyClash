/** A complete, server-verified view of paid transactions in one owned chain.
 * No amounts, receipts or account tokens are exposed by profile projections. */
export type AppleLoyaltySnapshot = {
  original_transaction_id: string;
  environment: 'production' | 'sandbox';
  transaction_ids: string[];
  verified_at: string;
};

type Transaction = {
  transactionId?: string; originalTransactionId?: string; appAccountToken?: string;
  bundleId?: string; productId?: string; environment?: string; type?: string;
  inAppOwnershipType?: string; price?: number; offerDiscountType?: string;
  purchaseDate?: number; signedDate?: number; revocationDate?: number;
  revocationReason?: number; revocationPercentage?: number; revocationType?: string;
};
type HistoryPage = {
  bundleId?: string; environment?: string; appAppleId?: number;
  hasMore?: boolean; revision?: string; signedTransactions?: string[];
};
const validID = (value: unknown): value is string =>
  typeof value === 'string' && /^[A-Za-z0-9._:-]{1,128}$/.test(value);
const positive = (value: unknown): value is number =>
  typeof value === 'number' && Number.isFinite(value) && value > 0;

/** Caller must first verify the current subscription and its account binding.
 * Failed/incomplete reads throw; callers retain the previous complete snapshot.
 * History includes revoked records so a later refund can remove a paid period. */
export async function readAppleLoyaltyHistory(input: {
  transactionID: string;
  originalTransactionID: string;
  appAccountToken: string;
  expectedBundleID: string;
  expectedProducts: readonly string[];
  expectedEnvironment: string;
  expectedAppAppleID: number;
  getHistory: (transactionID: string, revision: string | null) => Promise<HistoryPage>;
  verifyTransaction: (jws: string) => Promise<Transaction>;
  now?: () => number;
  deadlineMilliseconds?: number;
}): Promise<AppleLoyaltySnapshot> {
  const now = (input.now || Date.now)();
  const deadline = input.deadlineMilliseconds ?? Date.now() + 8000;
  const requireTime = () => {
    if (!Number.isFinite(deadline) || Date.now() >= deadline) throw new Error('Apple Loyalty history timed out.');
  };
  const token = input.appAccountToken.toLowerCase();
  if (!validID(input.transactionID) || !validID(input.originalTransactionID) || !token
      || !['Production', 'Sandbox'].includes(input.expectedEnvironment)
      || !positive(now)) throw new Error('Invalid verified Loyalty binding.');
  const records = new Map<string, { signedAt: number; eligible: boolean }>();
  const revisions = new Set<string>();
  let revision: string | null = null;
  for (let pageNumber = 0; pageNumber < 100; pageNumber++) {
    requireTime();
    const page = await input.getHistory(input.transactionID, revision);
    requireTime();
    if (page.bundleId !== input.expectedBundleID || page.environment !== input.expectedEnvironment
        || (input.expectedEnvironment === 'Production' && page.appAppleId !== input.expectedAppAppleID)
        || typeof page.hasMore !== 'boolean' || !Array.isArray(page.signedTransactions)
        || page.signedTransactions.length > 20) throw new Error('Invalid Apple Loyalty history response.');
    for (const signed of page.signedTransactions) {
      requireTime();
      if (typeof signed !== 'string' || !signed || signed.length > 250_000)
        throw new Error('Invalid signed Loyalty transaction.');
      const transaction = await input.verifyTransaction(signed);
      requireTime();
      if (transaction.bundleId !== input.expectedBundleID || transaction.environment !== input.expectedEnvironment)
        throw new Error('Apple Loyalty transaction identity mismatch.');
      // Apple's history is app-wide. A different chain is never evidence for this binding.
      if (transaction.originalTransactionId !== input.originalTransactionID) continue;
      const suppliedToken = transaction.appAccountToken?.toLowerCase();
      if (suppliedToken && suppliedToken !== token) throw new Error('Apple Loyalty account binding mismatch.');
      const id = transaction.transactionId;
      if (!validID(id) || !positive(transaction.signedDate)) throw new Error('Invalid Apple Loyalty transaction identity.');
      const eligible = input.expectedEnvironment === 'Production'
        && input.expectedProducts.includes(transaction.productId || '')
        && transaction.type === 'Auto-Renewable Subscription'
        && transaction.inAppOwnershipType === 'PURCHASED'
        && positive(transaction.price) && transaction.offerDiscountType !== 'FREE_TRIAL'
        && positive(transaction.purchaseDate) && transaction.purchaseDate <= now
        && transaction.revocationDate == null && transaction.revocationReason == null
        && transaction.revocationType == null && transaction.revocationPercentage == null;
      const prior = records.get(id);
      // Updated transactions can recur during pagination; newest signed state wins.
      // For equal timestamps, a revocation/ineligible representation wins safely.
      if (!prior || transaction.signedDate > prior.signedAt
          || (transaction.signedDate === prior.signedAt && !eligible))
        records.set(id, { signedAt: transaction.signedDate, eligible });
    }
    if (!page.hasMore) {
      // The verified current transaction must still be visible in a complete
      // unfiltered history. A missing chain is an incomplete observation, not
      // evidence that all previously earned paid periods disappeared.
      if (!records.has(input.transactionID)) throw new Error('Apple Loyalty history omitted the verified transaction.');
      return {
      original_transaction_id: input.originalTransactionID,
      environment: input.expectedEnvironment === 'Production' ? 'production' : 'sandbox',
      transaction_ids: [...records].filter(([, record]) => record.eligible).map(([id]) => id).sort(),
      verified_at: new Date(now).toISOString(),
      };
    }
    if (typeof page.revision !== 'string' || !page.revision || page.revision.length > 4096 || revisions.has(page.revision))
      throw new Error('Incomplete Apple Loyalty history.');
    revisions.add(page.revision);
    revision = page.revision;
  }
  throw new Error('Apple Loyalty history exceeded the bounded page limit.');
}

/** Only call with private server evidence, never with a client request object. */
export function mergeAppleLoyaltySnapshot<T extends Record<string, any>>(
  current: T, prior: Record<string, any> | undefined, snapshot?: AppleLoyaltySnapshot,
): T & { loyalty_transaction_ids?: string[]; loyalty_verified_at?: string } {
  const sameChain = prior?.original_transaction_id === current.original_transaction_id
    && prior?.environment === current.environment;
  const previousIDs = sameChain && Array.isArray(prior?.loyalty_transaction_ids)
    ? prior.loyalty_transaction_ids.filter(validID) : undefined;
  const previousTime = sameChain ? Date.parse(prior?.loyalty_verified_at || '') : NaN;
  const nextTime = Date.parse(snapshot?.verified_at || '');
  const valid = snapshot && snapshot.original_transaction_id === current.original_transaction_id
    && snapshot.environment === current.environment && Number.isFinite(nextTime)
    && (!Number.isFinite(previousTime) || nextTime >= previousTime)
    && Array.isArray(snapshot.transaction_ids) && snapshot.transaction_ids.length <= 2000
    && snapshot.transaction_ids.every(validID);
  if (valid) return {...current, loyalty_transaction_ids: [...new Set(snapshot.transaction_ids)], loyalty_verified_at: snapshot.verified_at};
  return previousIDs ? {...current, loyalty_transaction_ids: previousIDs, loyalty_verified_at: prior!.loyalty_verified_at} : current;
}
