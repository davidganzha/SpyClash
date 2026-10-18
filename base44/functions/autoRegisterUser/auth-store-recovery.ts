export type AuthStoreScope = "apple_credential" | "identity_lifecycle";

export type AuthStoreDependencyReason =
  | "support_panel_context"
  | "timeout"
  | "rate_limited"
  | "service_unavailable"
  | "unauthorized"
  | "forbidden";

const SUPPORT_PANEL_DENIAL =
  "You need to access this app through the support panel first. Please go to the support panel and click on a ticket for this app to grant temporary access.";
const RETRY_DELAYS = [150, 400] as const;
const MAX_SHARED_RETRIES = 4;
const RECOVERY_WINDOW_MILLISECONDS = 3_000;

export class AuthStoreDependencyError extends Error {
  readonly status = 503;
  readonly operation = "filter";

  constructor(
    readonly scope: AuthStoreScope,
    readonly upstreamStatus: number,
    readonly reason: AuthStoreDependencyReason,
    readonly retryable = reason !== "unauthorized" && reason !== "forbidden",
  ) {
    super("Authentication storage is temporarily unavailable.");
    this.name = "AuthStoreDependencyError";
  }
}

function dependencyFailure(error: unknown): {
  status: number;
  reason: AuthStoreDependencyReason;
  canRetry: boolean;
} | undefined {
  if (!error || typeof error !== "object") return undefined;
  const { status, message } = error as { status?: unknown; message?: unknown };
  if (status === 401) {
    return { status, reason: "unauthorized", canRetry: false };
  }
  if (status === 403) {
    const canRetry = message === SUPPORT_PANEL_DENIAL;
    return {
      status,
      reason: canRetry ? "support_panel_context" : "forbidden",
      canRetry,
    };
  }
  if (status === 408) return { status, reason: "timeout", canRetry: true };
  if (status === 429) return { status, reason: "rate_limited", canRetry: true };
  if (status === 500 || status === 502 || status === 503 || status === 504) {
    return { status, reason: "service_unavailable", canRetry: true };
  }
  return undefined;
}

/** One instance per authentication request; only service entity reads recover. */
export function createAuthStoreRecovery(options: {
  sleep?: (milliseconds: number) => Promise<void>;
  now?: () => number;
} = {}) {
  const sleep = options.sleep ||
    ((milliseconds: number) =>
      new Promise<void>((resolve) => setTimeout(resolve, milliseconds)));
  const now = options.now || (() => performance.now());
  let retries = 0;
  let recoveryDeadline: number | undefined;

  async function filter<T>(
    operation: () => Promise<T>,
    scope: AuthStoreScope,
  ): Promise<T> {
    let lastDependencyFailure: AuthStoreDependencyError | undefined;
    for (let attempt = 0;; attempt += 1) {
      let result: T;
      try {
        result = await operation();
      } catch (error) {
        const failure = dependencyFailure(error);
        if (!failure) throw error;
        const unavailable = new AuthStoreDependencyError(
          scope,
          failure.status,
          failure.reason,
          failure.canRetry,
        );
        lastDependencyFailure = unavailable;
        if (!failure.canRetry || attempt >= RETRY_DELAYS.length) {
          throw unavailable;
        }
        // Start the shared window at the first eligible failure, so unrelated
        // Apple/SSO work does not consume the short storage recovery window.
        recoveryDeadline ??= now() + RECOVERY_WINDOW_MILLISECONDS;
        const delay = RETRY_DELAYS[attempt];
        if (
          retries >= MAX_SHARED_RETRIES ||
          now() + delay >= recoveryDeadline
        ) throw unavailable;
        // Reserve before awaiting, including when both stores read concurrently.
        retries += 1;
        await sleep(delay);
        if (now() >= recoveryDeadline) throw unavailable;
        continue;
      }
      // An in-flight SDK request is not cancelled, but a recovered read must
      // finish inside the same window before its data can authorize a write.
      if (
        attempt > 0 && lastDependencyFailure &&
        recoveryDeadline !== undefined && now() >= recoveryDeadline
      ) throw lastDependencyFailure;
      return result;
    }
  }

  return {
    wrap<T extends object>(store: T, scope: AuthStoreScope): T {
      const originalFilter = Reflect.get(store, "filter", store);
      if (typeof originalFilter !== "function") {
        throw new TypeError("Authentication store must expose filter.");
      }
      const recoveredFilter = (...args: unknown[]) =>
        filter(() => Reflect.apply(originalFilter, store, args), scope);
      return new Proxy(store, {
        get(target, property) {
          if (property === "filter") return recoveredFilter;
          const value = Reflect.get(target, property, target);
          return typeof value === "function" ? value.bind(target) : value;
        },
      });
    },
  };
}
