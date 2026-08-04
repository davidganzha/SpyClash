import { appParams } from "@/lib/app-params";
import { createCommunityRequest, isExactSpyIDQuery } from "@/lib/communityProtocol";

const ROOM_INVITE_CLEANUP_KEY = "spy_pending_community_room_invite_cleanup";

export class CommunityActionError extends Error {
  constructor(message, status, code = null) {
    super(message);
    this.name = "CommunityActionError";
    this.status = status;
    this.code = code;
  }
}

function storedAccessToken() {
  try {
    return appParams.token
      || localStorage.getItem("base44_access_token")
      || localStorage.getItem("token");
  } catch {
    return appParams.token;
  }
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

export async function performCommunityAction(body, options = {}) {
  const request = createCommunityRequest({
    appId: appParams.appId,
    accessToken: storedAccessToken(),
    functionsVersion: appParams.functionsVersion,
  }, body);
  const retryDelays = options.retryTransient ? [180, 520] : [];

  for (let attempt = 0;; attempt += 1) {
    const response = await fetch(request.url, {
      ...request.init,
      signal: options.signal,
    });
    const payload = await response.json().catch(() => ({}));
    if (response.ok) return payload;
    if (response.status === 503 && attempt < retryDelays.length) {
      await delay(retryDelays[attempt]);
      continue;
    }
    throw new CommunityActionError(
      payload?.error || "Community action failed",
      response.status,
      payload?.code || null,
    );
  }
}

export function getCommunityState(options = {}) {
  return performCommunityAction(
    { action: "state" },
    { ...options, retryTransient: true },
  );
}

export function getCommunityDirectory(query = "", options = {}) {
  return performCommunityAction({
    action: "directory",
    query: String(query || "").trim(),
    offset: 0,
    limit: 60,
  }, { ...options, retryTransient: true });
}

export async function searchCommunity(query, options = {}) {
  const value = String(query || "").trim();
  if (isExactSpyIDQuery(value)) {
    try {
      const result = await performCommunityAction(
        { action: "search", spy_id: value },
        { ...options, retryTransient: true },
      );
      return { profiles: result?.profile ? [result.profile] : [], next_offset: null };
    } catch (error) {
      if (error?.status === 404) return { profiles: [], next_offset: null };
      throw error;
    }
  }
  return getCommunityDirectory(value, options);
}

export function sendFriendRequest(targetUserId) {
  return performCommunityAction({
    action: "send_request",
    target_user_id: targetUserId,
  });
}

export function updateFriendRequest(action, friendshipId) {
  return performCommunityAction({
    action,
    friendship_id: friendshipId,
  });
}

export function inviteCommunityOperative(targetUserId, room) {
  return performCommunityAction({
    action: "invite_to_room",
    target_user_id: targetUserId,
    room_id: room?.id,
    room_code: room?.code,
  });
}

export function updateRoomInvite(action, inviteId) {
  return performCommunityAction({ action, invite_id: inviteId });
}

function pendingCleanupIds() {
  try {
    const stored = JSON.parse(localStorage.getItem(ROOM_INVITE_CLEANUP_KEY) || "[]");
    return Array.isArray(stored)
      ? [...new Set(stored.map(String).filter(Boolean))]
      : [];
  } catch {
    return [];
  }
}

function storePendingCleanupIds(ids) {
  try {
    localStorage.setItem(ROOM_INVITE_CLEANUP_KEY, JSON.stringify([...ids].sort()));
  } catch {}
}

export function rememberRoomInviteCleanup(inviteId) {
  const ids = new Set(pendingCleanupIds());
  ids.add(String(inviteId));
  storePendingCleanupIds(ids);
}

export function clearRoomInviteCleanup(inviteId) {
  const ids = new Set(pendingCleanupIds());
  ids.delete(String(inviteId));
  storePendingCleanupIds(ids);
}

export async function retryPendingRoomInviteCleanups() {
  let cleared = 0;
  for (const inviteId of pendingCleanupIds()) {
    try {
      await updateRoomInvite("consume_room_invite", inviteId);
      clearRoomInviteCleanup(inviteId);
      cleared += 1;
    } catch (error) {
      if (error?.status === 404 || error?.status === 409) {
        clearRoomInviteCleanup(inviteId);
        cleared += 1;
      }
    }
  }
  return cleared;
}
