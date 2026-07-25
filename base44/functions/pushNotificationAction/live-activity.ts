import { clean } from "./contracts.ts";
import { decryptPushToken, tokenBinding } from "./token-crypto.ts";
import { type APNsResult, sendLiveActivityPush } from "./apns.ts";

type Entity = Record<string, any>;

function bounded(value: unknown, length: number): string {
  return clean(value).slice(0, length);
}

async function opaquePlayerID(
  roomID: string,
  emailValue: unknown,
): Promise<string> {
  const email = clean(emailValue).toLowerCase();
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${roomID}|${email}`),
  );
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("")
    .slice(0, 24);
}

function players(room: Entity): Entity[] {
  return Array.isArray(room?.players) ? room.players.slice(0, 12) : [];
}

function playerForUser(room: Entity, userID: string): Entity | null {
  return players(room).find((player) => clean(player?.user_id) === userID) ||
    null;
}

function playerStatus(room: Entity, email: string): string {
  const normalized = clean(email).toLowerCase();
  if (
    (room.spectators || []).map((value: unknown) => clean(value).toLowerCase())
      .includes(normalized)
  ) {
    return "spectator";
  }
  if (
    (room.eliminated_emails || []).map((value: unknown) =>
      clean(value).toLowerCase()
    )
      .includes(normalized)
  ) return "eliminated";
  return "active";
}

function matchPhase(
  room: Entity,
): "preparing" | "playing" | "voting" | "completed" {
  if (clean(room.status) === "finished") return "completed";
  const excluded = new Set(
    [
      ...(Array.isArray(room.spectators) ? room.spectators : []),
      ...(Array.isArray(room.eliminated_emails) ? room.eliminated_emails : []),
    ].map((email) => clean(email).toLowerCase()).filter(Boolean),
  );
  const activeEmails = new Set(
    players(room)
      .map((player) => clean(player?.email).toLowerCase())
      .filter((email) => email && !excluded.has(email)),
  );
  const activeVoteCount = new Set(
    (Array.isArray(room.vote_requests) ? room.vote_requests : [])
      .map((email) => clean(email).toLowerCase())
      .filter((email) => activeEmails.has(email)),
  ).size;
  const voteThreshold = activeEmails.size > 0
    ? Math.ceil(activeEmails.size * 0.51)
    : 0;
  if (
    clean(room.question_phase) === "results" ||
    (voteThreshold > 0 && activeVoteCount >= voteThreshold)
  ) return "voting";
  if (clean(room.status) === "playing") return "playing";
  return "preparing";
}

function timerState(room: Entity): {
  timerEndsAtEpochSeconds: number | null;
  pausedSecondsRemaining: number | null;
} {
  if (matchPhase(room) !== "playing") {
    return { timerEndsAtEpochSeconds: null, pausedSecondsRemaining: null };
  }
  const start = Date.parse(clean(room.game_started_at));
  const duration = Number(room.game_duration_seconds || 0);
  if (!Number.isFinite(start) || !Number.isFinite(duration) || duration <= 0) {
    return { timerEndsAtEpochSeconds: null, pausedSecondsRemaining: null };
  }
  const pausedTotal = Math.max(
    0,
    Number.isFinite(Number(room.game_paused_total_seconds))
      ? Number(room.game_paused_total_seconds)
      : 0,
  );
  const pausedAt = Date.parse(clean(room.game_paused_at));
  if (Number.isFinite(pausedAt)) {
    const activeElapsed = Math.max(
      0,
      Math.floor((pausedAt - start) / 1_000) - pausedTotal,
    );
    return {
      timerEndsAtEpochSeconds: null,
      pausedSecondsRemaining: Math.max(0, Math.floor(duration - activeElapsed)),
    };
  }
  return {
    timerEndsAtEpochSeconds: Math.round(start / 1_000 + duration + pausedTotal),
    pausedSecondsRemaining: null,
  };
}

function roomRevision(room: Entity): number {
  const revision = Date.parse(clean(room.updated_date));
  return Number.isFinite(revision) ? Math.max(0, Math.round(revision)) : 0;
}

export async function contentStateForUser(
  room: Entity,
  userID: string,
): Promise<{ state: Entity; viewerPlayerID: string; revision: number } | null> {
  const viewer = playerForUser(room, userID);
  if (!viewer?.email) return null;
  const roomID = clean(room.id);
  const participantEntries = await Promise.all(
    players(room).map(async (player) => {
      const email = clean(player.email).toLowerCase();
      return {
        id: await opaquePlayerID(roomID, email),
        displayName: bounded(player.name || "AGENT", 24) || "AGENT",
        avatarSymbol: bounded(player.avatar || "🕵️", 8) || "🕵️",
        status: playerStatus(room, email),
      };
    }),
  );
  const idForEmail = async (email: unknown) => {
    const normalized = clean(email).toLowerCase();
    return normalized ? await opaquePlayerID(roomID, normalized) : null;
  };
  const viewerEmail = clean(viewer.email).toLowerCase();
  const viewerPlayerID = await opaquePlayerID(roomID, viewerEmail);
  const revision = roomRevision(room);
  const mode = clean(room.game_mode) === "associations"
    ? "associations"
    : "questions";
  const currentAskerID = await idForEmail(room.current_asker_email);
  const timer = timerState(room);
  return {
    viewerPlayerID,
    revision,
    state: {
      phase: matchPhase(room),
      mode,
      participants: participantEntries,
      currentSpeakerID: currentAskerID,
      currentAskerID: mode === "questions" ? currentAskerID : null,
      currentResponderID: mode === "questions"
        ? await idForEmail(room.current_answerer_email)
        : null,
      round: Math.max(1, Math.round(Number(room.round_number || 1))),
      timerEndsAtEpochSeconds: timer.timerEndsAtEpochSeconds,
      pausedSecondsRemaining: timer.pausedSecondsRemaining,
      // Lock Screen and Dynamic Island are public glanceable surfaces.
      // Role and secret word remain inside the authenticated app only.
      privateIntel: null,
      revision,
    },
  };
}

function startedAtReferenceSeconds(room: Entity): number {
  const unixSeconds = Math.round(
    (Date.parse(clean(room.game_started_at || room.created_date)) ||
      Date.now()) / 1_000,
  );
  // Foundation's default Codable representation for Date uses seconds since
  // 2001-01-01, not Unix epoch.
  return unixSeconds - 978_307_200;
}

export async function liveActivityPayload(input: {
  room: Entity;
  registration: Entity;
  now?: Date;
}): Promise<
  | { payload: Entity; revision: number; event: "start" | "update" | "end" }
  | null
> {
  const personalized = await contentStateForUser(
    input.room,
    clean(input.registration.user_id),
  );
  if (!personalized) return null;
  const isFinished = clean(input.room.status) === "finished";
  const isStartToken = clean(input.registration.token_kind) === "push_to_start";
  if (isStartToken && isFinished) return null;
  const event = isStartToken ? "start" : isFinished ? "end" : "update";
  const now = input.now || new Date();
  const timestamp = Math.floor(now.getTime() / 1_000);
  const timerEndsAt = Number(personalized.state.timerEndsAtEpochSeconds || 0);
  const staleDate = timerEndsAt > timestamp
    ? Math.max(timestamp + 120, timerEndsAt + 60)
    : timestamp + 120;
  const aps: Entity = {
    timestamp,
    event,
    "content-state": personalized.state,
    "stale-date": isFinished ? undefined : staleDate,
  };
  if (event === "start") {
    aps["attributes-type"] = "SpyClashMatchActivityAttributes";
    aps["input-push-token"] = 1;
    aps.attributes = {
      roomID: clean(input.room.id),
      matchID: clean(input.room.match_id),
      viewerPlayerID: personalized.viewerPlayerID,
      startedAt: startedAtReferenceSeconds(input.room),
    };
    aps.alert = {
      title: "Mission started",
      body: "Your SpyClash table is live on the Lock Screen.",
    };
  }
  if (event === "end") {
    aps["dismissal-date"] = timestamp + 300;
  }
  aps["relevance-score"] = event === "end" ? 0 : 100;
  return { payload: { aps }, revision: personalized.revision, event };
}

export async function sendLiveActivityUpdate(input: {
  room: Entity;
  registration: Entity;
  now?: Date;
}): Promise<
  APNsResult & { skipped?: boolean; revision?: number; event?: string }
> {
  const now = input.now || new Date();
  const built = await liveActivityPayload({ ...input, now });
  if (!built) {
    return {
      delivered: false,
      retryable: false,
      invalidateToken: false,
      reason: "invalid_activity_binding",
      skipped: true,
    };
  }
  if (
    built.event === "start" &&
    new Set(
      [
        ...(Array.isArray(input.registration.started_match_ids)
          ? input.registration.started_match_ids
          : []),
        input.registration.last_started_match_id,
      ].map(clean).filter(Boolean),
    ).has(clean(input.room.match_id))
  ) {
    return {
      delivered: false,
      retryable: false,
      invalidateToken: false,
      reason: "already_started",
      skipped: true,
      revision: built.revision,
      event: built.event,
    };
  }
  if (
    built.event === "update" &&
    Number(input.registration.last_revision || -1) >= built.revision
  ) {
    return {
      delivered: false,
      retryable: false,
      invalidateToken: false,
      reason: "already_current",
      skipped: true,
      revision: built.revision,
      event: built.event,
    };
  }
  const token = await decryptPushToken(
    clean(input.registration.token_ciphertext),
    clean(input.registration.token_iv),
    tokenBinding(input.registration),
  );
  return {
    ...await sendLiveActivityPush({
      token,
      environment: clean(input.registration.environment) === "production"
        ? "production"
        : "sandbox",
      bundleID: clean(input.registration.bundle_id),
      collapseID: `live:${clean(input.room.match_id)}:${
        clean(input.registration.user_id)
      }`,
      expiration: Math.floor(now.getTime() / 1_000) + 3600,
      payload: built.payload,
    }),
    revision: built.revision,
    event: built.event,
  };
}
