export type CommunityMutationDisposition =
  | "apply"
  | "already_applied"
  | "invalid_actor"
  | "invalid_state";

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function status(value: unknown): string {
  return clean(value).toLowerCase();
}

/**
 * A lost HTTP response may cause the addressee to replay the exact same
 * decision. Only that original addressee may treat the target state as a
 * success; the requester and unrelated actors still fail closed.
 */
export function friendshipDecisionDisposition(
  actionValue: unknown,
  friendship: Record<string, unknown>,
  actorIDValue: unknown,
): CommunityMutationDisposition {
  const action = clean(actionValue).toLowerCase();
  const actorID = clean(actorIDValue);
  const addresseeID = clean(friendship?.addressee_id);
  if (!actorID || addresseeID !== actorID) return "invalid_actor";

  const currentStatus = status(friendship?.status);
  const targetStatus = action === "accept"
    ? "accepted"
    : action === "decline"
    ? "declined"
    : "";
  if (!targetStatus) return "invalid_state";
  if (currentStatus === "pending") return "apply";
  if (currentStatus === targetStatus) return "already_applied";
  return "invalid_state";
}

/**
 * Room-invite acceptance has the same lost-response contract as friendship
 * acceptance. A replay is successful only for the original recipient and the
 * exact already-accepted invite.
 */
export function roomInviteAcceptanceDisposition(
  invite: Record<string, unknown>,
  actorIDValue: unknown,
): CommunityMutationDisposition {
  const actorID = clean(actorIDValue);
  if (!actorID || clean(invite?.recipient_user_id) !== actorID) {
    return "invalid_actor";
  }
  const currentStatus = status(invite?.status);
  if (currentStatus === "pending") return "apply";
  if (currentStatus === "accepted") return "already_applied";
  return "invalid_state";
}
