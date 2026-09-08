import {
  Environment,
  type JWSRenewalInfoDecodedPayload,
  type JWSTransactionDecodedPayload,
  type StatusResponse,
} from "npm:@apple/app-store-server-library@3.1.0";
import { normalizeAppleEntitlement } from "./apple-entitlement.ts";
import { hasActiveMembership } from "./membership-guard.ts";
import { readCanonicalAppleSubscriptionStatus } from "./apple-subscription-status.ts";

const NOW = Date.parse("2026-09-09T12:00:00Z");
const TOKEN = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
const PRODUCT = "com.spyclash.ios.limitless.weekly";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

async function rejects(work: () => Promise<unknown>, expected: string) {
  try {
    await work();
  } catch (error) {
    assert(
      String(error).includes(expected),
      `Unexpected error: ${String(error)}`,
    );
    return;
  }
  throw new Error(`Expected rejection containing ${expected}`);
}

function fixture() {
  const submitted: JWSTransactionDecodedPayload = {
    originalTransactionId: "original-1",
    transactionId: "old-period",
    bundleId: "com.spyclash.ios",
    productId: PRODUCT,
    appAccountToken: TOKEN,
    environment: Environment.SANDBOX,
    expiresDate: NOW - 1_000,
    revocationDate: NOW - 2_000,
  };
  const current: JWSTransactionDecodedPayload = {
    ...submitted,
    transactionId: "current-period",
    expiresDate: NOW + 3_600_000,
    revocationDate: undefined,
  };
  const renewal: JWSRenewalInfoDecodedPayload = {
    originalTransactionId: "original-1",
    productId: PRODUCT,
    appAccountToken: TOKEN,
    environment: Environment.SANDBOX,
    autoRenewStatus: 1,
  };
  const candidate = {
    originalTransactionId: "original-1",
    signedTransactionInfo: "signed-current-transaction",
    signedRenewalInfo: "signed-current-renewal",
    status: 1,
  };
  const response: StatusResponse = {
    bundleId: "com.spyclash.ios",
    environment: Environment.SANDBOX,
    data: [{ lastTransactions: [candidate] }],
  };
  const input = {
    transaction: submitted,
    expectedBundleID: "com.spyclash.ios",
    expectedProductID: PRODUCT,
    expectedEnvironment: Environment.SANDBOX,
    expectedAppAppleID: 6793534085,
    getStatuses: async (transactionID: string) => {
      assert(
        transactionID === submitted.transactionId,
        "wrong customer lookup",
      );
      return response;
    },
    verifyTransaction: async (jws: string) => {
      assert(
        jws === candidate.signedTransactionInfo,
        "unverified current transaction",
      );
      return current;
    },
    verifyRenewal: async (jws: string) => {
      assert(jws === candidate.signedRenewalInfo, "unverified current renewal");
      return renewal;
    },
    now: () => NOW,
  };
  return { input, current, renewal, candidate, response };
}

Deno.test("refunded old period reconciles to the current paid renewal", async () => {
  const { input } = fixture();
  const result = await readCanonicalAppleSubscriptionStatus(input);
  const entitlement = normalizeAppleEntitlement({
    userID: "user-1",
    transaction: result.transaction,
    renewal: result.renewal,
    appleStatus: result.status,
    eventAtMilliseconds: result.checkedAtMilliseconds,
    now: new Date(NOW),
  });
  assert(
    entitlement.transaction_id === "current-period",
    "historical refund became current",
  );
  assert(
    hasActiveMembership([entitlement], new Date(NOW)),
    "current renewal lost access",
  );
});

Deno.test("current canonical expiry, billing retry and revocation remove access", async () => {
  for (const status of [2, 3, 5]) {
    const { input, candidate } = fixture();
    candidate.status = status;
    const result = await readCanonicalAppleSubscriptionStatus(input);
    const entitlement = normalizeAppleEntitlement({
      userID: "user-1",
      transaction: result.transaction,
      renewal: result.renewal,
      appleStatus: result.status,
      now: new Date(NOW),
    });
    assert(
      !hasActiveMembership([entitlement], new Date(NOW)),
      `status ${status} granted access`,
    );
  }
});

Deno.test("cancellation retains the paid period and grace uses the verified grace expiry", async () => {
  const { input, candidate, current, renewal } = fixture();
  renewal.autoRenewStatus = 0;
  let result = await readCanonicalAppleSubscriptionStatus(input);
  let entitlement = normalizeAppleEntitlement({
    userID: "user-1",
    transaction: result.transaction,
    renewal: result.renewal,
    appleStatus: result.status,
    now: new Date(NOW),
  });
  assert(entitlement.cancel_at_period_end, "cancellation was not recorded");
  assert(
    hasActiveMembership([entitlement], new Date(NOW)),
    "cancellation ended paid access early",
  );
  candidate.status = 4;
  current.expiresDate = NOW - 1_000;
  renewal.gracePeriodExpiresDate = NOW + 60_000;
  result = await readCanonicalAppleSubscriptionStatus(input);
  entitlement = normalizeAppleEntitlement({
    userID: "user-1",
    transaction: result.transaction,
    renewal: result.renewal,
    appleStatus: result.status,
    now: new Date(NOW),
  });
  assert(
    hasActiveMembership([entitlement], new Date(NOW)),
    "verified grace lost access",
  );
  assert(
    !hasActiveMembership([entitlement], new Date(NOW + 60_000)),
    "grace never expired",
  );
});

Deno.test("renewal proof must belong to the same transaction chain, product and environment", async () => {
  for (
    const patch of [
      { originalTransactionId: "another-subscription" },
      { productId: "another-product" },
      { environment: Environment.PRODUCTION },
    ]
  ) {
    const { input, renewal } = fixture();
    Object.assign(renewal, patch);
    await rejects(
      () => readCanonicalAppleSubscriptionStatus(input),
      "did not match",
    );
  }
});

Deno.test("current transaction and renewal cannot transfer the app account binding", async () => {
  for (const source of ["current", "renewal"] as const) {
    const test = fixture();
    test[source].appAccountToken = "ffffffff-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    await rejects(
      () => readCanonicalAppleSubscriptionStatus(test.input),
      "token changed",
    );
  }
});

Deno.test("missing optional current token retains only the verified submitted binding", async () => {
  const { input, current, renewal } = fixture();
  delete current.appAccountToken;
  delete renewal.appAccountToken;
  const result = await readCanonicalAppleSubscriptionStatus(input);
  assert(
    result.transaction.appAccountToken === TOKEN,
    "verified restore binding was lost",
  );
  delete input.transaction.appAccountToken;
  await rejects(
    () => readCanonicalAppleSubscriptionStatus(input),
    "token changed",
  );
});

Deno.test("status response identity and subscription status fail closed", async () => {
  for (
    const patch of [
      { bundleId: "another.bundle" },
      { environment: Environment.PRODUCTION },
    ]
  ) {
    const { input, response } = fixture();
    Object.assign(response, patch);
    await rejects(
      () => readCanonicalAppleSubscriptionStatus(input),
      "identity",
    );
  }
  const { input, candidate } = fixture();
  candidate.status = 99;
  await rejects(
    () => readCanonicalAppleSubscriptionStatus(input),
    "unsupported subscription status",
  );
  candidate.originalTransactionId = "unrelated";
  await rejects(
    () => readCanonicalAppleSubscriptionStatus(input),
    "current matching subscription",
  );
});

Deno.test("failed provider or JWS verification can be retried without an unverified grant", async () => {
  const { input } = fixture();
  const getStatuses = input.getStatuses;
  input.getStatuses = () => Promise.reject(new Error("provider unavailable"));
  await rejects(
    () => readCanonicalAppleSubscriptionStatus(input),
    "provider unavailable",
  );
  input.getStatuses = getStatuses;
  const verifyTransaction = input.verifyTransaction;
  input.verifyTransaction = () => Promise.reject(new Error("bad signature"));
  await rejects(
    () => readCanonicalAppleSubscriptionStatus(input),
    "bad signature",
  );
  input.verifyTransaction = verifyTransaction;
  assert(
    (await readCanonicalAppleSubscriptionStatus(input)).status === 1,
    "retry did not recover",
  );
});

Deno.test("production status must identify the exact App Store Connect app", async () => {
  const { input, response, current, renewal } = fixture();
  input.expectedEnvironment = Environment.PRODUCTION;
  input.transaction.environment = Environment.PRODUCTION;
  response.environment = Environment.PRODUCTION;
  current.environment = Environment.PRODUCTION;
  renewal.environment = Environment.PRODUCTION;
  await rejects(() => readCanonicalAppleSubscriptionStatus(input), "identity");
  response.appAppleId = 123;
  await rejects(() => readCanonicalAppleSubscriptionStatus(input), "identity");
  response.appAppleId = 6793534085;
  assert(
    (await readCanonicalAppleSubscriptionStatus(input)).status === 1,
    "correct production app rejected",
  );
});
