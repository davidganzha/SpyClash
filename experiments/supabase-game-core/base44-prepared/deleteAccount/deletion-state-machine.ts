export type DeletionFailureDisposition =
  | "rollback_before_cleanup"
  | "retain_deleting_for_retry";

/** Irreversible content cleanup commits deletion intent, even if User.delete fails. */
export function deletionFailureDisposition(
  irreversibleCleanupStarted: boolean,
): DeletionFailureDisposition {
  return irreversibleCleanupStarted
    ? "retain_deleting_for_retry"
    : "rollback_before_cleanup";
}
