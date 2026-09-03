import { clean, NotificationContractError } from "./contracts.ts";
import { withNotificationWriteLease } from "./receipt-lifecycle.ts";

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
  return await withNotificationWriteLease({
    lifecycleStore: input.lifecycleStore,
    userID: adminUserID,
    action: async (adminPersist) =>
      await withNotificationWriteLease({
        lifecycleStore: input.lifecycleStore,
        userID: `notification-admin:${operationKey}`,
        action: async (operationPersist) =>
          // Lease acquisition retries occur inside each lifecycle helper,
          // before this callback starts. Never retry this mutation callback.
          await input.action(async (writer) =>
            await adminPersist(async () => await operationPersist(writer))
          ),
      }),
  });
}
