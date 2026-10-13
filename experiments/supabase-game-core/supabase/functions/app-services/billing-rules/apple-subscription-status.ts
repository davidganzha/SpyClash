import type {
  JWSRenewalInfoDecodedPayload,
  JWSTransactionDecodedPayload,
  StatusResponse,
} from "npm:@apple/app-store-server-library@3.1.0";

export class AppleSubscriptionStatusError extends Error {
  constructor(message: string, readonly status = 503) {
    super(message);
    this.name = "AppleSubscriptionStatusError";
  }
}

// Call while holding the account's write lease. A notification is a hint to
// reconcile, not necessarily the latest transaction in a subscription chain.
export async function readCanonicalAppleSubscriptionStatus(input: {
  transaction: JWSTransactionDecodedPayload;
  expectedBundleID: string;
  expectedProductID: string;
  expectedEnvironment: string;
  expectedAppAppleID: number;
  getStatuses: (transactionID: string) => Promise<StatusResponse>;
  verifyTransaction: (jws: string) => Promise<JWSTransactionDecodedPayload>;
  verifyRenewal: (jws: string) => Promise<JWSRenewalInfoDecodedPayload>;
  now?: () => number;
}) {
  if (
    !input.transaction.transactionId || !input.transaction.originalTransactionId
  ) {
    throw new AppleSubscriptionStatusError(
      "Apple transaction ID is missing.",
      422,
    );
  }
  const response = await input.getStatuses(input.transaction.transactionId);
  if (
    response.bundleId !== input.expectedBundleID ||
    response.environment !== input.expectedEnvironment ||
    (input.expectedEnvironment === "Production" &&
      response.appAppleId !== input.expectedAppAppleID)
  ) {
    throw new AppleSubscriptionStatusError(
      "App Store status response identity does not match SpyClash.",
    );
  }
  const candidates = (response.data || []).flatMap((group) =>
    group.lastTransactions || []
  );
  const candidate = candidates.find((item) =>
    item.originalTransactionId === input.transaction.originalTransactionId
  );
  if (!candidate?.signedTransactionInfo) {
    throw new AppleSubscriptionStatusError(
      "App Store did not return a current matching subscription.",
      409,
    );
  }
  const transaction = await input.verifyTransaction(
    candidate.signedTransactionInfo,
  );
  const renewal = candidate.signedRenewalInfo
    ? await input.verifyRenewal(candidate.signedRenewalInfo)
    : undefined;
  if (
    transaction.originalTransactionId !==
      input.transaction.originalTransactionId ||
    transaction.productId !== input.expectedProductID ||
    transaction.bundleId !== input.expectedBundleID ||
    transaction.environment !== input.expectedEnvironment ||
    (renewal && (
      renewal.originalTransactionId !== transaction.originalTransactionId ||
      renewal.productId !== transaction.productId ||
      renewal.environment !== transaction.environment
    ))
  ) {
    throw new AppleSubscriptionStatusError(
      "App Store status response did not match the submitted subscription.",
      409,
    );
  }
  const submittedToken = String(input.transaction.appAccountToken || "")
    .toLowerCase();
  const tokens = [transaction.appAccountToken, renewal?.appAccountToken]
    .filter((token): token is string => Boolean(token))
    .map((token) => token.toLowerCase());
  if (!submittedToken || tokens.some((token) => token !== submittedToken)) {
    throw new AppleSubscriptionStatusError(
      "Apple subscription account token changed unexpectedly.",
      409,
    );
  }
  const status = Number(candidate.status);
  if (!Number.isInteger(status) || status < 1 || status > 5) {
    throw new AppleSubscriptionStatusError(
      "App Store returned an unsupported subscription status.",
    );
  }
  return {
    // A verified original transaction can carry the binding when Apple's
    // current transaction omits the optional token; never invent a new owner.
    transaction: { ...transaction, appAccountToken: submittedToken },
    renewal,
    status,
    checkedAtMilliseconds: (input.now || Date.now)(),
  };
}
