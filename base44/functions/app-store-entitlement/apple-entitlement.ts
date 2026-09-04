import {
  limitlessApplePurchaseEnabled,
  limitlessEnabled,
} from "./limitless-rollout.ts";
export const SPYCLASH_IOS_BUNDLE_ID = "com.spyclash.ios";
export const SPYCLASH_APPLE_APP_ID = 6793534085;
// The historical product id cannot be renamed because Apple transactions and
// server notifications refer to it permanently.
export const LEGACY_SUBSCRIPTION_PRODUCT_ID =
  `${SPYCLASH_IOS_BUNDLE_ID}.limitless.weekly`;
export const CASADA_PROTOCOL_ENABLED = !limitlessEnabled();

export function casadaPurchaseRetirement(
  universalAccess = CASADA_PROTOCOL_ENABLED,
  applePurchasesEnabled = limitlessApplePurchaseEnabled(),
) {
  if (!universalAccess) {
    return applePurchasesEnabled ? null : {
      status: 503,
      message:
        "New subscriptions are not available yet. Existing purchases can still be restored.",
    };
  }
  return {
    status: 409,
    message:
      "Full access is already included. App Store purchase is not required.",
  } as const;
}

export function appleCommerceConfigurationError(input: {
  bundleID: string;
  productID: string;
  appAppleID?: number;
}): string | null {
  if (input.bundleID !== SPYCLASH_IOS_BUNDLE_ID) {
    return "APPLE_IAP_BUNDLE_ID does not match the current SpyClash iOS app.";
  }
  if (input.productID !== LEGACY_SUBSCRIPTION_PRODUCT_ID) {
    return "APPLE_IAP_PRODUCT_ID does not match the legacy subscription product.";
  }
  if (
    input.appAppleID !== undefined &&
    input.appAppleID !== SPYCLASH_APPLE_APP_ID
  ) {
    return "APPLE_IAP_APPLE_ID does not match the current App Store Connect app.";
  }
  return null;
}

export type AppleEnvironment = "Sandbox" | "Production";

export type AppleTransactionPayload = {
  originalTransactionId?: string;
  transactionId?: string;
  bundleId?: string;
  productId?: string;
  type?: string;
  purchaseDate?: number;
  originalPurchaseDate?: number;
  expiresDate?: number;
  appAccountToken?: string;
  signedDate?: number;
  revocationDate?: number;
  isUpgraded?: boolean;
  environment?: AppleEnvironment | string;
};

export type AppleRenewalPayload = {
  originalTransactionId?: string;
  productId?: string;
  autoRenewProductId?: string;
  autoRenewStatus?: number;
  isInBillingRetryPeriod?: boolean;
  gracePeriodExpiresDate?: number;
  renewalDate?: number;
  appAccountToken?: string;
  signedDate?: number;
  environment?: AppleEnvironment | string;
};

export type AppleEntitlementRecord = {
  id?: string;
  source_key: string;
  user_id: string;
  user_email?: string;
  provider: "apple";
  product_id: string;
  original_transaction_id: string;
  transaction_id: string;
  app_account_token: string;
  status: string;
  purchased_at?: string;
  expires_at: string;
  environment: "sandbox" | "production";
  cancel_at_period_end?: boolean;
  last_verified_at: string;
  provider_event_at: string;
  provider_event_id?: string;
};

export type NormalizeAppleEntitlementInput = {
  transaction: AppleTransactionPayload;
  renewal?: AppleRenewalPayload;
  appleStatus?: number;
  notificationType?: string;
  notificationUUID?: string;
  eventAtMilliseconds?: number;
  userID: string;
  userEmail?: string;
  now?: Date;
};

export function isoFromAppleMilliseconds(value: unknown): string | undefined {
  const milliseconds = Number(value);
  if (!Number.isFinite(milliseconds) || milliseconds <= 0) return undefined;
  return new Date(milliseconds).toISOString();
}

export function entitlementStatusFromApple(input: {
  appleStatus?: number;
  notificationType?: string;
  transaction: AppleTransactionPayload;
  now?: Date;
}): string {
  const notificationType = String(input.notificationType || "").toUpperCase();
  if (notificationType === "REFUND") return "refunded";
  if (notificationType === "REVOKE") return "revoked";
  // A REFUND_REVERSED notification requires the app to reinstate access when
  // Apple's current subscription status grants it. The transaction included
  // in the notification may still describe the previously refunded purchase,
  // including its revocationDate, so the reconciled App Store Server API status
  // must take precedence over that historical field.
  if (notificationType === "REFUND_REVERSED") {
    switch (input.appleStatus) {
      case 1:
        return "active";
      case 2:
        return "expired";
      case 3:
        return "billing_retry";
      case 4:
        return "grace_period";
      case 5:
        return "revoked";
    }

    const expiresAt = Number(input.transaction.expiresDate);
    const now = input.now ?? new Date();
    return Number.isFinite(expiresAt) && expiresAt > now.getTime()
      ? "active"
      : "expired";
  }
  if (input.transaction.revocationDate) return "revoked";
  if (input.transaction.isUpgraded) return "expired";

  switch (input.appleStatus) {
    case 1:
      return "active";
    case 2:
      return "expired";
    case 3:
      return "billing_retry";
    case 4:
      return "grace_period";
    case 5:
      return "revoked";
  }

  if (notificationType === "EXPIRED") return "expired";
  const expiresAt = Number(input.transaction.expiresDate);
  const now = input.now ?? new Date();
  return Number.isFinite(expiresAt) && expiresAt > now.getTime()
    ? "active"
    : "expired";
}

export function requiresCanonicalSubscriptionStatus(
  notificationType: unknown,
): boolean {
  return String(notificationType || "").toUpperCase() === "REFUND_REVERSED";
}

export function normalizeAppleEntitlement(
  input: NormalizeAppleEntitlementInput,
): AppleEntitlementRecord {
  const { transaction, renewal } = input;
  const originalTransactionID = String(
    transaction.originalTransactionId || renewal?.originalTransactionId || "",
  );
  const transactionID = String(transaction.transactionId || "");
  const productID = String(transaction.productId || renewal?.productId || "");
  const appAccountToken = String(
    transaction.appAccountToken || renewal?.appAccountToken || "",
  ).toLowerCase();
  const rawEnvironment = String(
    transaction.environment || renewal?.environment || "",
  );
  const environment = rawEnvironment === "Production"
    ? "production"
    : rawEnvironment === "Sandbox"
    ? "sandbox"
    : null;

  if (!originalTransactionID) {
    throw new Error("Apple original transaction ID is missing.");
  }
  if (!transactionID) throw new Error("Apple transaction ID is missing.");
  if (!productID) throw new Error("Apple product ID is missing.");
  if (!appAccountToken) throw new Error("Apple appAccountToken is missing.");
  if (!environment) {
    throw new Error("Unsupported Apple transaction environment.");
  }

  const expiresMilliseconds = Math.max(
    Number(transaction.expiresDate) || 0,
    input.appleStatus === 4 ? Number(renewal?.gracePeriodExpiresDate) || 0 : 0,
  );
  const expiresAt = isoFromAppleMilliseconds(expiresMilliseconds);
  if (!expiresAt) throw new Error("Apple subscription expiry is missing.");

  const now = input.now ?? new Date();
  const eventAt = isoFromAppleMilliseconds(
    input.eventAtMilliseconds || transaction.signedDate || renewal?.signedDate,
  ) || now.toISOString();

  return {
    source_key: `apple:${originalTransactionID}`,
    user_id: input.userID,
    user_email: input.userEmail,
    provider: "apple",
    product_id: productID,
    original_transaction_id: originalTransactionID,
    transaction_id: transactionID,
    app_account_token: appAccountToken,
    status: entitlementStatusFromApple({
      appleStatus: input.appleStatus,
      notificationType: input.notificationType,
      transaction,
      now,
    }),
    purchased_at: isoFromAppleMilliseconds(
      transaction.originalPurchaseDate || transaction.purchaseDate,
    ),
    expires_at: expiresAt,
    environment,
    cancel_at_period_end: renewal?.autoRenewStatus === undefined
      ? undefined
      : Number(renewal.autoRenewStatus) === 0,
    last_verified_at: now.toISOString(),
    provider_event_at: eventAt,
    provider_event_id: input.notificationUUID,
  };
}

export function shouldApplyProviderEvent(
  current: { provider_event_at?: string; provider_event_id?: string },
  incoming: { provider_event_at?: string; provider_event_id?: string },
): boolean {
  if (
    incoming.provider_event_id &&
    current.provider_event_id === incoming.provider_event_id
  ) {
    return false;
  }

  const currentTime = Date.parse(current.provider_event_at || "");
  const incomingTime = Date.parse(incoming.provider_event_at || "");
  if (Number.isFinite(currentTime) && Number.isFinite(incomingTime)) {
    return incomingTime >= currentTime;
  }
  return true;
}

export function publicAppleEntitlement(record: AppleEntitlementRecord) {
  return {
    provider: record.provider,
    product_id: record.product_id,
    status: record.status,
    expires_at: record.expires_at,
    environment: record.environment,
  };
}
