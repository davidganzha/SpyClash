import { clean, NotificationContractError } from "./contracts.ts";
import { withNotificationWriteLease } from "./receipt-lifecycle.ts";

const MAX_SERIALIZATION_ATTEMPTS = 20;

function retryable(error: unknown): boolean {
  return error instanceof NotificationContractError &&
    ["active_lease", "cas_contention"].includes(error.code);
}

async function pause(attempt: number): Promise<void> {
  const milliseconds = Math.min(50, 2 ** Math.min(attempt, 6));
  await new Promise((resolve) => setTimeout(resolve, milliseconds));
}

/**
 * Serialize an admin mutation against both account deletion and its stable
 * request/announcement key. The inner synthetic lifecycle subject prevents
 * two admins from publishing the same request id concurrently.
 */
export async function withSerializedAdminMutation<T>(input: {
  lifecycleStore: any;
  adminUserID: string;
  operationKey: string;
  action: (persist: <R>(writer: () => Promise<R>) => Promise<R>) => Promise<T>;
}): Promise<T> {
  const adminUserID = clean(input.adminUserID);
  const operationKey = clean(input.operationKey);
  if (!adminUserID || !operationKey) {
    throw new NotificationContractError("Admin mutation key is invalid.");
  }
  let lastError: unknown;
  for (let attempt = 0; attempt < MAX_SERIALIZATION_ATTEMPTS; attempt += 1) {
    try {
      return await withNotificationWriteLease({
        lifecycleStore: input.lifecycleStore,
        userID: adminUserID,
        action: async (adminPersist) =>
          await withNotificationWriteLease({
            lifecycleStore: input.lifecycleStore,
            userID: `notification-admin:${operationKey}`,
            action: async (operationPersist) =>
              await input.action(async (writer) =>
                await adminPersist(async () => await operationPersist(writer))
              ),
          }),
      });
    } catch (error) {
      lastError = error;
      if (!retryable(error) || attempt + 1 >= MAX_SERIALIZATION_ATTEMPTS) {
        throw error;
      }
      await pause(attempt);
    }
  }
  throw lastError;
}
