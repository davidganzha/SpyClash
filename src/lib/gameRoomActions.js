import { appParams } from "@/lib/app-params";
import { base44 } from "@/api/base44Client";
import {
  buildGameRoomActionHeaders,
  ROOM_POLL_ERROR_THRESHOLD,
  roomPollDelayMilliseconds,
} from "@/lib/gameRoomSync";
import { dispatchGameRoomAction } from "@/lib/gameRoomTransport";

export class GameRoomActionError extends Error {
  constructor(message, status, code = null) {
    super(message);
    this.name = "GameRoomActionError";
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

/**
 * Room actions normally use the body-token transport because it also works
 * during the Base44 user-provisioning boundary. Some valid SSO sessions are
 * cookie/SDK-backed and do not expose that token to localStorage; for those,
 * fall back to the authenticated SDK invocation instead of making every room
 * control look inert.
 *
 * The optional runtime is intentionally test-only dependency injection.
 */
export async function performGameRoomAction(body, runtime = {}) {
  const accessToken = runtime.accessToken !== undefined
    ? runtime.accessToken
    : storedAccessToken();

  const headers = buildGameRoomActionHeaders(appParams);
  try {
    return await dispatchGameRoomAction({
      body,
      accessToken,
      endpoint: `/api/apps/${appParams.appId}/functions/gameRoomAction`,
      headers,
      invoke: runtime.invoke
        || ((payload) => base44.functions.invoke("gameRoomAction", payload)),
      request: runtime.fetch || fetch,
    });
  } catch (error) {
    throw new GameRoomActionError(
      error?.message || "Room action failed",
      Number(error?.status) || 500,
      error?.code || null,
    );
  }
}

export async function getGameRoom(roomId) {
  if (!roomId) return null;
  try {
    return await performGameRoomAction({ action: "get_room", room_id: roomId });
  } catch (error) {
    if (error?.status === 404) return null;
    throw error;
  }
}

export async function getActiveGameRoom(preferredRoomId = null) {
  return await performGameRoomAction({
    action: "get_active_room",
    room_id: preferredRoomId || undefined,
  });
}

export async function getLeaderboard() {
  const payload = await performGameRoomAction({ action: "get_leaderboard" });
  return Array.isArray(payload?.entries) ? payload.entries : [];
}

export async function createGameRoom({ player }) {
  return await performGameRoomAction({ action: "create_room", player });
}

export async function leaveGameRoom(roomId) {
  return await performGameRoomAction({ action: "leave_room", room_id: roomId });
}

export async function runGameRoomAction(action, roomId, fields = {}) {
  return await performGameRoomAction({ action, room_id: roomId, ...fields });
}

export function subscribeGameRoom(roomId, onEvent, intervalMs = 1_200) {
  let cancelled = false;
  let inFlight = false;
  let lastUpdated = null;
  let timer = null;
  let consecutiveFailures = 0;
  let pendingImmediatePoll = false;

  const isHidden = () => typeof document !== "undefined" && document.visibilityState === "hidden";

  const schedule = (delay = null) => {
    if (cancelled) return;
    if (timer) clearTimeout(timer);
    const nextDelay = delay ?? roomPollDelayMilliseconds({
      baseIntervalMilliseconds: intervalMs,
      consecutiveFailures,
      hidden: isHidden(),
    });
    timer = setTimeout(poll, nextDelay);
  };

  const poll = async () => {
    if (cancelled) return;
    if (inFlight) {
      pendingImmediatePoll = true;
      return;
    }
    inFlight = true;
    try {
      const room = await getGameRoom(roomId);
      if (cancelled) return;
      if (!room) {
        cancelled = true;
        onEvent({ id: roomId, type: "delete", data: null });
        return;
      }
      const recovered = consecutiveFailures >= ROOM_POLL_ERROR_THRESHOLD;
      consecutiveFailures = 0;
      if (recovered) {
        onEvent({ id: roomId, type: "sync", state: "connected" });
      }
      const revision = room.updated_date || JSON.stringify(room);
      if (revision !== lastUpdated) {
        lastUpdated = revision;
        onEvent({ id: roomId, type: "update", data: room });
      }
    } catch (error) {
      if (cancelled) return;
      if (error?.status === 403 || error?.status === 404) {
        cancelled = true;
        onEvent({ id: roomId, type: "delete", data: null });
        return;
      }
      consecutiveFailures += 1;
      if (consecutiveFailures >= ROOM_POLL_ERROR_THRESHOLD) {
        onEvent({
          id: roomId,
          type: "sync",
          state: "reconnecting",
          attempt: consecutiveFailures,
          error,
        });
      }
    } finally {
      inFlight = false;
      if (!cancelled) {
        if (pendingImmediatePoll) {
          pendingImmediatePoll = false;
          schedule(0);
        } else {
          schedule();
        }
      }
    }
  };

  const handleVisibilityChange = () => {
    if (cancelled || isHidden()) return;
    if (timer) clearTimeout(timer);
    timer = null;
    void poll();
  };

  if (typeof document !== "undefined") {
    document.addEventListener("visibilitychange", handleVisibilityChange);
  }
  void poll();
  return () => {
    cancelled = true;
    if (timer) clearTimeout(timer);
    if (typeof document !== "undefined") {
      document.removeEventListener("visibilitychange", handleVisibilityChange);
    }
  };
}

/**
 * @param {{roomId?: string | null, roomCode?: string | null, player: any}} input
 */
export async function joinGameRoom({ roomId = null, roomCode = null, player }) {
  const payload = await performGameRoomAction({
    action: "join_room",
    room_id: roomId,
    room_code: roomCode,
    player,
  });
  if (!payload?.id) {
    throw new GameRoomActionError("Unable to join room", 502);
  }
  return payload;
}

export async function finalizeExpiredOnlineGame(roomId) {
  const payload = await performGameRoomAction({
    action: "finalize_expired_room",
    room_id: roomId,
  });
  if (!payload?.id) {
    throw new GameRoomActionError("Unable to finalize expired online game", 502);
  }
  return payload;
}
