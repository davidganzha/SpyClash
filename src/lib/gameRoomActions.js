import { appParams } from "@/lib/app-params";
import { base44 } from "@/api/base44Client";
import {
  buildGameRoomActionHeaders,
  ROOM_POLL_FALLBACK_INTERVAL_MILLISECONDS,
  ROOM_POLL_ERROR_THRESHOLD,
  roomPollDelayMilliseconds,
  shouldRefreshForGameRoomSignal,
} from "@/lib/gameRoomSync";
import {
  dispatchGameRoomAction,
  isRetryableRoomActionConflict,
} from "@/lib/gameRoomTransport";
import {
  withMultiSpyActionCapability,
  withMultiSpyPlayerCapability,
} from "@/lib/multiSpyRules";
import {
  GAME_ROOM_CLOSE_ACTION,
  GAME_ROOM_LEAVE_ACTION,
  gameRoomExitPayload,
} from "@/lib/gameRoomExit";
import { gameRoomJoinPayload } from "@/lib/gameRoomJoin";

export class GameRoomActionError extends Error {
  constructor(message, status, code = null, retryable = false) {
    super(message);
    this.name = "GameRoomActionError";
    this.status = status;
    this.code = code;
    this.retryable = retryable;
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
  const capableBody = withMultiSpyActionCapability(body);
  const accessToken = runtime.accessToken !== undefined
    ? runtime.accessToken
    : storedAccessToken();

  const headers = buildGameRoomActionHeaders(appParams);
  try {
    return await dispatchGameRoomAction({
      body: capableBody,
      accessToken,
      endpoint: `/api/apps/${appParams.appId}/functions/gameRoomAction`,
      headers,
      invoke: runtime.invoke
        || ((payload) => base44.functions.invoke("gameRoomAction", payload)),
      request: runtime.fetch || fetch,
      deadlineMilliseconds: runtime.deadlineMilliseconds,
    });
  } catch (error) {
    throw new GameRoomActionError(
      error?.message || "Room action failed",
      Number(error?.status) || 500,
      error?.code || null,
      error?.retryable === true,
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
  return await performGameRoomAction({
    action: "create_room",
    player: withMultiSpyPlayerCapability(player),
  });
}

export async function leaveGameRoom(
  roomId,
  expectedRevision = null,
  expectedMembershipID = null,
) {
  return await performGameRoomAction(gameRoomExitPayload({
    action: GAME_ROOM_LEAVE_ACTION,
    roomId,
    expectedRevision,
    expectedMembershipID,
  }));
}

export async function closeGameRoom(
  roomId,
  expectedRevision = null,
  expectedMembershipID = null,
) {
  return await performGameRoomAction(gameRoomExitPayload({
    action: GAME_ROOM_CLOSE_ACTION,
    roomId,
    expectedRevision,
    expectedMembershipID,
  }));
}

export async function runGameRoomAction(action, roomId, fields = {}) {
  const payload = { action, room_id: roomId, ...fields };
  try {
    return await performGameRoomAction(payload);
  } catch (error) {
    // Detective casts use a room/match/actor/target-scoped authoritative
    // refresh loop in Game.jsx. Do not perform this generic blind retry first.
    if (action === "cast_detective_vote" || !isRetryableRoomActionConflict(error)) {
      throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
    return await performGameRoomAction(payload);
  }
}

export function subscribeGameRoom(roomId, onEvent, options = {}) {
  const config = typeof options === "number" ? { intervalMs: options } : options;
  const intervalMs = config?.intervalMs ?? ROOM_POLL_FALLBACK_INTERVAL_MILLISECONDS;
  const userId = config?.userId ?? null;
  const currentRoomRevision = () => {
    const value = typeof config?.currentRoomRevision === "function"
      ? config.currentRoomRevision()
      : config?.currentRoomRevision;
    return value ?? null;
  };
  const subscribeSignals = config?.subscribeSignals
    || ((callback) => base44.entities.GameRoomSignal.subscribe(callback));
  let cancelled = false;
  let inFlight = false;
  let lastUpdated = null;
  let timer = null;
  let unsubscribeSignals = null;
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
      const revision = Number.isInteger(Number(room.room_revision))
        ? `room:${Number(room.room_revision)}`
        : room.updated_date || JSON.stringify(room);
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

  const requestImmediatePoll = () => {
    if (cancelled) return;
    if (timer) clearTimeout(timer);
    timer = null;
    if (inFlight) {
      pendingImmediatePoll = true;
      return;
    }
    void poll();
  };

  const handleVisibilityChange = () => {
    if (cancelled || isHidden()) return;
    requestImmediatePoll();
  };

  if (typeof document !== "undefined") {
    document.addEventListener("visibilitychange", handleVisibilityChange);
  }
  try {
    unsubscribeSignals = subscribeSignals((event) => {
      if (!shouldRefreshForGameRoomSignal(event, {
        roomId,
        userId,
        currentRoomRevision: currentRoomRevision(),
      })) return;
      const state = String(event?.data?.state || "active").toLocaleLowerCase();
      if (state === "closed") {
        cancelled = true;
        if (timer) clearTimeout(timer);
        onEvent({ id: roomId, type: "delete", data: null });
        return;
      }
      requestImmediatePoll();
    });
  } catch (error) {
    console.warn("Game room realtime unavailable; using fallback polling", error);
  }
  void poll();
  return () => {
    cancelled = true;
    if (timer) clearTimeout(timer);
    unsubscribeSignals?.();
    if (typeof document !== "undefined") {
      document.removeEventListener("visibilitychange", handleVisibilityChange);
    }
  };
}

/**
 * @param {{roomId?: string | null, roomCode?: string | null, player: any, joinMembershipID?: string | null, expectedMembershipID?: string | null}} input
 */
export async function joinGameRoom({
  roomId = null,
  roomCode = null,
  player,
  joinMembershipID = null,
  expectedMembershipID = null,
}) {
  const payload = await performGameRoomAction(gameRoomJoinPayload({
    roomId,
    roomCode,
    player: withMultiSpyPlayerCapability(player),
    joinMembershipID,
    expectedMembershipID,
  }));
  if (!payload?.id) {
    throw new GameRoomActionError("Unable to join room", 502);
  }
  return payload;
}

export async function finalizeExpiredOnlineGame(roomId, expectedScope = {}) {
  const payload = await performGameRoomAction({
    action: "finalize_expired_room",
    room_id: roomId,
    expected_match_id: expectedScope?.expected_match_id || undefined,
    expected_game_started_at: expectedScope?.expected_game_started_at || undefined,
  });
  if (!payload?.id) {
    throw new GameRoomActionError("Unable to finalize expired online game", 502);
  }
  return payload;
}
