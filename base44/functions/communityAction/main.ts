import { createClient, createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import {
  communityActionRequiresProfileWriteLease,
  normalizeCommunityQuery,
  normalizeSpyID,
  preferredSpyIDOwner,
  profileMatchesCommunityQuery,
  publicProfile,
  roomAcceptsCommunityInvites,
  sanitizeProfileComment,
  stableSpyID,
} from "./community.ts";
import { withCommunityWriteLeases } from "./community-write-lifecycle.ts";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import {
  blockedCounterpartIDs,
  deleteBlockedPairContent,
} from "./community-moderation.ts";
import {
  blockedByUserID,
  friendshipBlocksPair,
  normalizeCommunityReportReason,
  requireSafeCommunityText,
  safeCommunityTextForDisplay,
  sanitizeCommunityReportDetails,
} from "./community-safety.ts";
import {
  enqueueCommunityPushEvent,
  reusablePendingInviteEventID,
} from "./push-events.ts";
import { internalPushSecret } from "./internal-push.ts";

type Entity = Record<string, any>;
type Persist = <T>(writer: () => Promise<T>) => Promise<T>;

const MAX_SPY_ID_ALLOCATION_ATTEMPTS = 256;
const DIRECTORY_DEFAULT_LIMIT = 24;
const DIRECTORY_MAX_LIMIT = 60;
const PROFILE_FRIEND_LIMIT = 60;
const PROFILE_COMMENT_LIMIT = 40;
const COMMENT_COOLDOWN_MS = 5_000;

function errorResponse(message: string, status = 400) {
  return Response.json({ error: message }, { status });
}

function clean(value: unknown) {
  return String(value || "").trim();
}

function integer(
  value: unknown,
  fallback: number,
  minimum: number,
  maximum: number,
) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(maximum, Math.max(minimum, parsed));
}

function uniqueByID(items: Entity[]) {
  return items.filter((item, index, values) =>
    values.findIndex((candidate) => clean(candidate.id) === clean(item.id)) ===
      index
  );
}

function newestFirst(items: Entity[]) {
  return [...items].sort((first, second) =>
    Date.parse(clean(second.created_at || second.created_date)) -
    Date.parse(clean(first.created_at || first.created_date))
  );
}

function isParticipant(friendship: Entity, userID: string) {
  return friendship.requester_id === userID ||
    friendship.addressee_id === userID;
}

function playerEmail(player: unknown) {
  if (typeof player === "string") return clean(player).toLowerCase();
  if (player && typeof player === "object") {
    return clean((player as Entity).email).toLowerCase();
  }
  return "";
}

async function findEntityByID(base44: any, entity: string, id: string) {
  if (!id) return null;
  const rows = await base44.asServiceRole.entities[entity].filter({ id });
  return rows?.[0] || null;
}

async function findUserByID(base44: any, userID: string) {
  return await findEntityByID(base44, "User", userID);
}

function profileDefaultsPatch(user: Entity) {
  const patch: Entity = {};
  if (!clean(user.spy_card_theme)) patch.spy_card_theme = "field";
  if (!clean(user.spy_card_accent)) patch.spy_card_accent = "signal_red";
  if (!clean(user.spy_card_badge)) patch.spy_card_badge = "operative";
  return patch;
}

async function usersWithSpyID(base44: any, spyID: string) {
  return await base44.asServiceRole.entities.User.filter({ spy_id: spyID }) ||
    [];
}

async function listAllUsers(base44: any) {
  const pageSize = 5_000;
  const users: Entity[] = [];
  for (let skip = 0;; skip += pageSize) {
    const page = await base44.asServiceRole.entities.User.list(
      "created_date",
      pageSize,
      skip,
    ) || [];
    users.push(...page);
    if (page.length < pageSize) return users;
  }
}

async function ensureUserProfile(
  base44: any,
  user: Entity,
  persist?: Persist,
): Promise<Entity> {
  const userID = clean(user.id);
  if (!userID) throw new Error("Cannot allocate SPY ID without a user ID");

  const defaults = profileDefaultsPatch(user);
  const existingSpyID = normalizeSpyID(user.spy_id);
  if (existingSpyID) {
    const holders = await usersWithSpyID(base44, existingSpyID);
    const otherHolder = holders.some((candidate: Entity) =>
      clean(candidate.id) !== userID
    );
    const owner = preferredSpyIDOwner(holders);
    if (!otherHolder || clean(owner?.id) === userID) {
      const patch = { ...defaults };
      if (user.spy_id !== existingSpyID) patch.spy_id = existingSpyID;
      if (Object.keys(patch).length) {
        if (persist) {
          await persist(() =>
            base44.asServiceRole.entities.User.update(userID, patch)
          );
        }
        return { ...user, ...patch };
      }
      return { ...user, spy_id: existingSpyID };
    }
  }

  for (
    let attempt = 0;
    attempt < MAX_SPY_ID_ALLOCATION_ATTEMPTS;
    attempt += 1
  ) {
    const candidate = await stableSpyID(userID, attempt);
    const holders = await usersWithSpyID(base44, candidate);
    if (holders.some((holder: Entity) => clean(holder.id) !== userID)) continue;

    const patch = { ...defaults, spy_id: candidate };
    if (!persist) return { ...user, ...patch };
    await persist(() =>
      base44.asServiceRole.entities.User.update(userID, patch)
    );

    await new Promise((resolve) => setTimeout(resolve, 20));
    const confirmed = await usersWithSpyID(base44, candidate);
    const owner = preferredSpyIDOwner(confirmed);
    if (clean(owner?.id) === userID) return { ...user, ...patch };

    if (confirmed.length === 0) {
      const refreshed = await findUserByID(base44, userID);
      if (normalizeSpyID(refreshed?.spy_id) === candidate) {
        return {
          ...user,
          ...patch,
        };
      }
    }
  }

  throw new Error("Unable to allocate a unique SPY ID");
}

async function findUserBySpyID(
  base44: any,
  value: unknown,
): Promise<{ spyID: string | null; user: Entity | null }> {
  const spyID = normalizeSpyID(value);
  if (!spyID) return { spyID: null, user: null };

  const direct = await usersWithSpyID(base44, spyID);
  for (const candidate of direct) {
    const ensured = await ensureUserProfile(base44, candidate);
    if (normalizeSpyID(ensured.spy_id) === spyID) {
      return { spyID, user: ensured };
    }
  }

  const users = await listAllUsers(base44);
  for (const candidate of users) {
    const stored = normalizeSpyID(candidate.spy_id);
    const firstCandidate = stored
      ? null
      : await stableSpyID(clean(candidate.id));
    if (stored !== spyID && firstCandidate !== spyID) continue;
    const ensured = await ensureUserProfile(base44, candidate);
    if (normalizeSpyID(ensured.spy_id) === spyID) {
      return { spyID, user: ensured };
    }
  }
  return { spyID, user: null };
}

async function resolveTargetUser(base44: any, body: Entity) {
  const targetUserID = clean(body.target_user_id || body.user_id);
  if (targetUserID) {
    const target = await findUserByID(base44, targetUserID);
    return target ? await ensureUserProfile(base44, target) : null;
  }
  const found = await findUserBySpyID(base44, body.spy_id);
  return found.user;
}

async function relationshipBetween(
  base44: any,
  firstID: string,
  secondID: string,
) {
  const outgoing = await base44.asServiceRole.entities.Friendship.filter({
    requester_id: firstID,
    addressee_id: secondID,
  });
  if (outgoing?.[0]) return outgoing[0];

  const incoming = await base44.asServiceRole.entities.Friendship.filter({
    requester_id: secondID,
    addressee_id: firstID,
  });
  return incoming?.[0] || null;
}

async function relationshipsForUser(base44: any, userID: string) {
  const [requested, received] = await Promise.all([
    base44.asServiceRole.entities.Friendship.filter({ requester_id: userID }),
    base44.asServiceRole.entities.Friendship.filter({ addressee_id: userID }),
  ]);
  return uniqueByID([...(requested || []), ...(received || [])]);
}

function requireUnblockedRelationship(
  friendship: Entity | null,
  firstUserID: string,
  secondUserID: string,
  status = 403,
  message = "Interaction unavailable",
) {
  if (friendshipBlocksPair(friendship, firstUserID, secondUserID)) {
    throw Object.assign(new Error(message), { status });
  }
}

function relationshipSummary(friendship: Entity | null, userID: string) {
  if (!friendship) return null;
  return {
    id: friendship.id,
    status: friendship.status,
    direction: friendship.requester_id === userID ? "outgoing" : "incoming",
  };
}

async function acceptedFriendProfiles(
  base44: any,
  userID: string,
  viewerUserID: string,
) {
  const [targetRelationships, viewerRelationships] = await Promise.all([
    relationshipsForUser(base44, userID),
    userID === viewerUserID
      ? Promise.resolve([])
      : relationshipsForUser(base44, viewerUserID),
  ]);
  const viewerBlocked = blockedCounterpartIDs(
    userID === viewerUserID ? targetRelationships : viewerRelationships,
    viewerUserID,
  );
  const accepted = targetRelationships
    .filter((friendship) => friendship.status === "accepted")
    .filter((friendship) => {
      const otherID = friendship.requester_id === userID
        ? friendship.addressee_id
        : friendship.requester_id;
      return !viewerBlocked.has(clean(otherID));
    })
    .slice(0, PROFILE_FRIEND_LIMIT);

  const profiles = await Promise.all(accepted.map(async (friendship) => {
    const otherID = friendship.requester_id === userID
      ? friendship.addressee_id
      : friendship.requester_id;
    const user = await findUserByID(base44, otherID);
    return user ? publicProfile(await ensureUserProfile(base44, user)) : null;
  }));
  return profiles.filter(Boolean);
}

async function profileComments(
  base44: any,
  targetUserID: string,
  viewerUserID: string,
) {
  const [rows, viewerRelationships, targetRelationships] = await Promise.all([
    base44.asServiceRole.entities.ProfileComment.filter({
      target_user_id: targetUserID,
    }),
    relationshipsForUser(base44, viewerUserID),
    viewerUserID === targetUserID
      ? Promise.resolve([])
      : relationshipsForUser(base44, targetUserID),
  ]);
  const blockedAuthors = new Set([
    ...blockedCounterpartIDs(viewerRelationships, viewerUserID),
    ...blockedCounterpartIDs(targetRelationships, targetUserID),
  ]);
  const comments: Entity[] = newestFirst(rows || []).flatMap((comment) => {
    const body = safeCommunityTextForDisplay(comment.body, "");
    if (!body || blockedAuthors.has(clean(comment.author_user_id))) return [];
    return [{ ...comment, body } as Entity];
  }).slice(0, PROFILE_COMMENT_LIMIT);
  const authorCache = new Map<string, Entity | null>();

  return await Promise.all(comments.map(async (comment) => {
    const authorID = clean(comment.author_user_id);
    if (!authorCache.has(authorID)) {
      const author = await findUserByID(base44, authorID);
      authorCache.set(
        authorID,
        author ? await ensureUserProfile(base44, author) : null,
      );
    }
    const author = authorCache.get(authorID);
    return {
      id: clean(comment.id),
      body: clean(comment.body),
      created_at: clean(comment.created_at || comment.created_date),
      author: author ? publicProfile(author) : null,
      can_delete: authorID === viewerUserID || targetUserID === viewerUserID,
    };
  })).then((items) => items.filter((item) => item.author));
}

async function buildProfileDetail(
  base44: any,
  current: Entity,
  target: Entity,
) {
  const relationship = target.id === current.id
    ? null
    : await relationshipBetween(base44, current.id, target.id);
  requireUnblockedRelationship(
    relationship,
    current.id,
    target.id,
    404,
    "Operative not found",
  );
  const [friends, comments] = await Promise.all([
    acceptedFriendProfiles(base44, target.id, current.id),
    profileComments(base44, target.id, current.id),
  ]);

  return {
    profile: publicProfile(target),
    is_self: target.id === current.id,
    relationship: relationshipSummary(relationship, current.id),
    friends,
    comments,
  };
}

async function incomingRoomInvites(base44: any, current: Entity) {
  const [pending, accepted, relationships] = await Promise.all([
    base44.asServiceRole.entities.RoomInvite.filter({
      recipient_user_id: current.id,
      status: "pending",
    }),
    base44.asServiceRole.entities.RoomInvite.filter({
      recipient_user_id: current.id,
      status: "accepted",
    }),
    relationshipsForUser(base44, current.id),
  ]);
  const blockedSenders = blockedCounterpartIDs(relationships, current.id);
  const invitations = newestFirst(
    uniqueByID([...(pending || []), ...(accepted || [])]),
  ).filter((invite) => !blockedSenders.has(clean(invite.sender_user_id)));

  const senderCache = new Map<string, Entity | null>();
  return await Promise.all(invitations.map(async (invite) => {
    const senderID = clean(invite.sender_user_id);
    if (!senderCache.has(senderID)) {
      const sender = await findUserByID(base44, senderID);
      senderCache.set(
        senderID,
        sender ? await ensureUserProfile(base44, sender) : null,
      );
    }
    const sender = senderCache.get(senderID);
    return {
      id: clean(invite.id),
      status: clean(invite.status),
      room_id: clean(invite.room_id),
      room_code: clean(invite.room_code),
      created_at: clean(invite.created_at || invite.created_date),
      sender: sender ? publicProfile(sender) : null,
    };
  })).then((items) => items.filter((item) => item.sender));
}

async function buildState(base44: any, rawUser: Entity) {
  const user = await ensureUserProfile(base44, rawUser);
  const [all, roomInvites] = await Promise.all([
    relationshipsForUser(base44, user.id),
    incomingRoomInvites(base44, user),
  ]);

  const profileCache = new Map<string, Entity>();
  async function counterpart(friendship: Entity) {
    const otherID = friendship.requester_id === user.id
      ? friendship.addressee_id
      : friendship.requester_id;
    if (!profileCache.has(otherID)) {
      const found = await findUserByID(base44, otherID);
      if (found) {
        profileCache.set(otherID, await ensureUserProfile(base44, found));
      }
    }
    const found = profileCache.get(otherID);
    return found ? publicProfile(found) : null;
  }

  const friends = [];
  const incoming = [];
  const outgoing = [];
  const blocked = [];
  for (const friendship of all) {
    const profile = await counterpart(friendship);
    if (!profile) continue;

    const record = {
      id: friendship.id,
      status: friendship.status,
      direction: friendship.requester_id === user.id ? "outgoing" : "incoming",
      profile,
    };
    if (friendship.status === "blocked") {
      if (blockedByUserID(friendship) === user.id) blocked.push(record);
    } else if (friendship.status === "accepted") friends.push(record);
    else if (
      friendship.status === "pending" && record.direction === "incoming"
    ) incoming.push(record);
    else if (friendship.status === "pending") outgoing.push(record);
  }

  return {
    me: publicProfile(user),
    friends,
    incoming,
    outgoing,
    blocked,
    incoming_room_invites: roomInvites,
  };
}

async function buildDirectory(base44: any, body: Entity, current: Entity) {
  const query = normalizeCommunityQuery(body.query);
  const offset = integer(body.offset, 0, 0, 1_000_000);
  const limit = integer(
    body.limit,
    DIRECTORY_DEFAULT_LIMIT,
    1,
    DIRECTORY_MAX_LIMIT,
  );
  const exactSpyID = normalizeSpyID(body.query);
  const blockedUserIDs = blockedCounterpartIDs(
    await relationshipsForUser(base44, current.id),
    current.id,
  );

  if (exactSpyID) {
    const result = await findUserBySpyID(base44, exactSpyID);
    return {
      profiles: result.user && !blockedUserIDs.has(clean(result.user.id))
        ? [publicProfile(result.user)]
        : [],
      next_offset: null,
    };
  }

  if (query) {
    const all = await listAllUsers(base44);
    const matching = all.filter((candidate) =>
      !blockedUserIDs.has(clean(candidate.id)) &&
      profileMatchesCommunityQuery(candidate, query)
    );
    const page = matching.slice(offset, offset + limit);
    const profiles = await Promise.all(
      page.map(async (candidate) =>
        publicProfile(await ensureUserProfile(base44, candidate))
      ),
    );
    return {
      profiles,
      next_offset: offset + limit < matching.length ? offset + limit : null,
    };
  }

  const visibleUsers = newestFirst(
    (await listAllUsers(base44)).filter((candidate: Entity) =>
      !blockedUserIDs.has(clean(candidate.id))
    ),
  );
  const visible = visibleUsers.slice(offset, offset + limit);
  const profiles = await Promise.all(
    visible.map(async (candidate: Entity) =>
      publicProfile(await ensureUserProfile(base44, candidate))
    ),
  );
  return {
    profiles,
    next_offset: offset + limit < visibleUsers.length ? offset + limit : null,
  };
}

async function sendFriendRequest(
  base44: any,
  current: Entity,
  target: Entity,
  persist: Persist,
  eventID: string,
) {
  if (target.id === current.id) {
    throw Object.assign(new Error("Cannot add yourself"), { status: 409 });
  }
  const existing = await relationshipBetween(base44, current.id, target.id);
  if (existing?.status === "accepted") {
    throw Object.assign(new Error("Already friends"), { status: 409 });
  }
  if (existing?.status === "pending") {
    if (clean(existing.requester_id) === current.id) {
      return clean(existing.request_event_id);
    }
    throw Object.assign(new Error("Request already pending"), { status: 409 });
  }
  if (existing?.status === "blocked") {
    throw Object.assign(new Error("Request unavailable"), { status: 403 });
  }

  const now = new Date().toISOString();
  const payload = {
    requester_id: current.id,
    addressee_id: target.id,
    requester_spy_id: current.spy_id,
    addressee_spy_id: target.spy_id,
    status: "pending",
    request_event_id: eventID,
    updated_at: now,
  };
  await enqueueCommunityPushEvent({
    store: base44.asServiceRole.entities.PushNotificationEvent,
    persist,
    eventType: "friend_request",
    sourceEventID: eventID,
    actorUserID: current.id,
    recipientUserID: target.id,
  });
  if (existing) {
    await persist(() =>
      base44.asServiceRole.entities.Friendship.update(existing.id, payload)
    );
  } else {
    await persist(() =>
      base44.asServiceRole.entities.Friendship.create({
        ...payload,
        created_at: now,
      })
    );
  }
  return eventID;
}

async function processPushEventBestEffort(base44: any, eventID: string) {
  const internalSecret = internalPushSecret(
    Deno.env.get("PUSH_INTERNAL_SECRET"),
  );
  if (!eventID || !internalSecret) return;
  try {
    await base44.asServiceRole.functions.invoke("pushNotificationAction", {
      action: "process_event",
      source_event_id: eventID,
      internal_secret: internalSecret,
    });
  } catch (error) {
    console.error(
      "community push dispatch deferred",
      error instanceof Error ? error.message : error,
    );
  }
}

async function validateRoomInvite(
  base44: any,
  current: Entity,
  body: Entity,
  target: Entity,
) {
  if (target.id === current.id) {
    throw Object.assign(new Error("Cannot invite yourself"), { status: 409 });
  }
  const roomID = clean(body.room_id);
  const roomCode = clean(body.room_code).toUpperCase();
  const room = await findEntityByID(base44, "GameRoom", roomID);
  if (!room || clean(room.code).toUpperCase() !== roomCode) {
    throw Object.assign(new Error("Room not found"), { status: 404 });
  }
  if (!roomAcceptsCommunityInvites(room.status)) {
    throw Object.assign(new Error("Room is no longer accepting invites"), {
      status: 409,
    });
  }

  const currentEmail = clean(current.email).toLowerCase();
  const targetEmail = clean(target.email).toLowerCase();
  const players = Array.isArray(room.players)
    ? room.players.map(playerEmail)
    : [];
  if (!currentEmail || !players.includes(currentEmail)) {
    throw Object.assign(new Error("Join the room before inviting operatives"), {
      status: 403,
    });
  }
  if (targetEmail && players.includes(targetEmail)) {
    throw Object.assign(new Error("Operative is already in this room"), {
      status: 409,
    });
  }
  return room;
}

Deno.serve(async (req) => {
  try {
    const body = await req.json().catch(() => ({}));
    const accessToken = clean(body.access_token);
    const appID = req.headers.get("Base44-App-Id");
    const serverURL = req.headers.get("Base44-Api-Url") || "https://base44.app";

    if (!accessToken || !appID) return errorResponse("Unauthorized", 401);

    const identityClient = createClient({
      appId: appID,
      serverUrl: serverURL,
      token: accessToken,
    });
    const user = await identityClient.auth.me();
    if (!user?.id) return errorResponse("Unauthorized", 401);

    const base44 = createClientFromRequest(req);
    const lifecycleStore =
      base44.asServiceRole.entities.BillingIdentityLifecycle;
    const action = clean(body.action || "state").toLowerCase();
    const current = communityActionRequiresProfileWriteLease(action)
      ? await withCommunityWriteLeases({
        lifecycleStore,
        userIDs: [user.id],
        action: ({ persist }) => ensureUserProfile(base44, user, persist),
      })
      : await ensureUserProfile(base44, user);

    if (action === "state") {
      return Response.json(await buildState(base44, current));
    }
    if (action === "directory") {
      return Response.json(await buildDirectory(base44, body, current));
    }
    if (action === "search") {
      const found = await findUserBySpyID(base44, body.spy_id);
      if (!found.spyID) return errorResponse("Invalid SPY ID", 422);
      if (!found.user) return errorResponse("Operative not found", 404);
      const relationship = found.user.id === current.id
        ? null
        : await relationshipBetween(base44, current.id, found.user.id);
      if (friendshipBlocksPair(relationship, current.id, found.user.id)) {
        return errorResponse("Operative not found", 404);
      }
      return Response.json({
        profile: publicProfile(found.user),
        is_self: found.user.id === current.id,
        relationship: relationshipSummary(relationship, current.id),
      });
    }
    if (action === "profile") {
      const target = await resolveTargetUser(base44, body);
      if (!target) return errorResponse("Operative not found", 404);
      return Response.json(await buildProfileDetail(base44, current, target));
    }

    if (action === "send_request") {
      const target = await resolveTargetUser(base44, body);
      if (!target) return errorResponse("Operative not found", 404);
      const eventID = crypto.randomUUID();
      const queuedEventID = await withCommunityWriteLeases({
        lifecycleStore,
        userIDs: [current.id, target.id],
        action: async ({ persist }) => {
          const [freshCurrent, freshTarget] = await Promise.all([
            findUserByID(base44, current.id),
            findUserByID(base44, target.id),
          ]);
          if (!freshCurrent || !freshTarget) {
            throw Object.assign(new Error("Operative not found"), {
              status: 404,
            });
          }
          return await sendFriendRequest(
            base44,
            await ensureUserProfile(base44, freshCurrent, persist),
            await ensureUserProfile(base44, freshTarget, persist),
            persist,
            eventID,
          );
        },
      });
      await processPushEventBestEffort(base44, queuedEventID);
      return Response.json(await buildState(base44, current));
    }

    if (action === "add_comment") {
      const target = await resolveTargetUser(base44, body);
      if (!target) return errorResponse("Operative not found", 404);
      if (target.id === current.id) {
        return errorResponse("Comment on another operative's profile", 409);
      }
      const sanitizedComment = sanitizeProfileComment(body.comment);
      if (!sanitizedComment) {
        return errorResponse("Comment must contain 1-280 characters", 422);
      }
      const comment = requireSafeCommunityText(
        sanitizedComment,
        "Comment",
      );

      await withCommunityWriteLeases({
        lifecycleStore,
        userIDs: [current.id, target.id],
        action: async ({ persist }) => {
          const [freshCurrent, freshTarget] = await Promise.all([
            findUserByID(base44, current.id),
            findUserByID(base44, target.id),
          ]);
          if (!freshCurrent || !freshTarget) {
            throw Object.assign(new Error("Operative not found"), {
              status: 404,
            });
          }
          requireUnblockedRelationship(
            await relationshipBetween(base44, current.id, target.id),
            current.id,
            target.id,
          );
          const previous = newestFirst(
            await base44.asServiceRole.entities.ProfileComment.filter({
              author_user_id: current.id,
            }) || [],
          )[0];
          const previousTime = Date.parse(
            clean(previous?.created_at || previous?.created_date),
          );
          if (
            Number.isFinite(previousTime) &&
            Date.now() - previousTime < COMMENT_COOLDOWN_MS
          ) {
            throw Object.assign(
              new Error("Wait before posting another comment"),
              {
                status: 429,
              },
            );
          }
          const now = new Date().toISOString();
          await persist(() =>
            base44.asServiceRole.entities.ProfileComment.create({
              target_user_id: target.id,
              author_user_id: current.id,
              body: comment,
              created_at: now,
              updated_at: now,
            })
          );
        },
      });
      return Response.json(await buildProfileDetail(base44, current, target));
    }

    if (action === "delete_comment") {
      const commentID = clean(body.comment_id);
      const initialComment = await findEntityByID(
        base44,
        "ProfileComment",
        commentID,
      );
      if (!initialComment) return errorResponse("Comment not found", 404);
      const participantIDs = [
        clean(initialComment.author_user_id),
        clean(initialComment.target_user_id),
      ];
      await withCommunityWriteLeases({
        lifecycleStore,
        userIDs: participantIDs,
        action: async ({ persist }) => {
          const comment = await findEntityByID(
            base44,
            "ProfileComment",
            commentID,
          );
          if (!comment) {
            throw Object.assign(new Error("Comment not found"), {
              status: 404,
            });
          }
          if (
            clean(comment.author_user_id) !== current.id &&
            clean(comment.target_user_id) !== current.id
          ) {
            throw Object.assign(new Error("Comment cannot be deleted"), {
              status: 403,
            });
          }
          await persist(() =>
            base44.asServiceRole.entities.ProfileComment.delete(comment.id)
          );
        },
      });
      const target = await findUserByID(
        base44,
        clean(initialComment.target_user_id),
      );
      if (!target) return errorResponse("Operative not found", 404);
      return Response.json(
        await buildProfileDetail(
          base44,
          current,
          await ensureUserProfile(base44, target),
        ),
      );
    }

    if (action === "invite_to_room") {
      const target = await resolveTargetUser(base44, body);
      if (!target) return errorResponse("Operative not found", 404);
      const eventID = crypto.randomUUID();
      const queuedEventID = await withCommunityWriteLeases({
        lifecycleStore,
        userIDs: [current.id, target.id],
        action: async ({ persist }) => {
          const [freshCurrent, freshTarget] = await Promise.all([
            findUserByID(base44, current.id),
            findUserByID(base44, target.id),
          ]);
          if (!freshCurrent || !freshTarget) {
            throw Object.assign(new Error("Operative not found"), {
              status: 404,
            });
          }
          requireUnblockedRelationship(
            await relationshipBetween(base44, current.id, target.id),
            current.id,
            target.id,
          );
          const room = await validateRoomInvite(
            base44,
            freshCurrent,
            body,
            freshTarget,
          );
          const existing = newestFirst(
            await base44.asServiceRole.entities.RoomInvite.filter({
              sender_user_id: current.id,
              recipient_user_id: target.id,
              room_id: room.id,
            }) || [],
          )[0];
          const reusableEventID = reusablePendingInviteEventID(existing);
          if (reusableEventID) return reusableEventID;
          const now = new Date().toISOString();
          const payload = {
            sender_user_id: current.id,
            recipient_user_id: target.id,
            room_id: room.id,
            room_code: clean(room.code).toUpperCase(),
            status: "pending",
            notification_event_id: eventID,
            updated_at: now,
          };
          await enqueueCommunityPushEvent({
            store: base44.asServiceRole.entities.PushNotificationEvent,
            persist,
            eventType: "room_invite",
            sourceEventID: eventID,
            actorUserID: current.id,
            recipientUserID: target.id,
            roomID: room.id,
          });
          if (existing) {
            await persist(() =>
              base44.asServiceRole.entities.RoomInvite.update(
                existing.id,
                payload,
              )
            );
          } else {
            await persist(() =>
              base44.asServiceRole.entities.RoomInvite.create({
                ...payload,
                created_at: now,
              })
            );
          }
          return eventID;
        },
      });
      await processPushEventBestEffort(base44, queuedEventID);
      return Response.json({ ok: true });
    }

    if (
      ["accept_room_invite", "decline_room_invite", "consume_room_invite"]
        .includes(action)
    ) {
      const inviteID = clean(body.invite_id);
      const initialInvite = await findEntityByID(
        base44,
        "RoomInvite",
        inviteID,
      );
      if (
        !initialInvite || clean(initialInvite.recipient_user_id) !== current.id
      ) {
        return errorResponse("Room invite not found", 404);
      }
      let acceptedRoomCode: string | null = null;
      await withCommunityWriteLeases({
        lifecycleStore,
        userIDs: [
          initialInvite.sender_user_id,
          initialInvite.recipient_user_id,
        ],
        action: async ({ persist }) => {
          const invite = await findEntityByID(base44, "RoomInvite", inviteID);
          if (!invite || clean(invite.recipient_user_id) !== current.id) {
            throw Object.assign(new Error("Room invite not found"), {
              status: 404,
            });
          }
          const senderID = clean(invite.sender_user_id);
          requireUnblockedRelationship(
            await relationshipBetween(base44, current.id, senderID),
            current.id,
            senderID,
          );
          if (action === "decline_room_invite") {
            await persist(() =>
              base44.asServiceRole.entities.RoomInvite.delete(invite.id)
            );
            return;
          }
          if (action === "consume_room_invite") {
            if (invite.status !== "accepted") {
              throw Object.assign(new Error("Room invite is not accepted"), {
                status: 409,
              });
            }
            await persist(() =>
              base44.asServiceRole.entities.RoomInvite.delete(invite.id)
            );
            return;
          }
          if (invite.status !== "pending") {
            throw Object.assign(new Error("Room invite cannot be accepted"), {
              status: 409,
            });
          }
          const room = await findEntityByID(
            base44,
            "GameRoom",
            clean(invite.room_id),
          );
          if (!room || !roomAcceptsCommunityInvites(room.status)) {
            await persist(() =>
              base44.asServiceRole.entities.RoomInvite.update(invite.id, {
                status: "expired",
                updated_at: new Date().toISOString(),
              })
            );
            throw Object.assign(new Error("Room is no longer available"), {
              status: 409,
            });
          }
          acceptedRoomCode = clean(room.code).toUpperCase();
          await persist(() =>
            base44.asServiceRole.entities.RoomInvite.update(invite.id, {
              status: "accepted",
              updated_at: new Date().toISOString(),
            })
          );
        },
      });
      return Response.json({
        state: await buildState(base44, current),
        room_code: acceptedRoomCode,
      });
    }

    if (action === "block") {
      const target = await resolveTargetUser(base44, body);
      if (!target) return errorResponse("Operative not found", 404);
      if (target.id === current.id) {
        return errorResponse("Cannot block yourself", 409);
      }
      await withCommunityWriteLeases({
        lifecycleStore,
        userIDs: [current.id, target.id],
        action: async ({ persist }) => {
          const [freshCurrent, freshTarget] = await Promise.all([
            findUserByID(base44, current.id),
            findUserByID(base44, target.id),
          ]);
          if (!freshCurrent || !freshTarget) {
            throw Object.assign(new Error("Operative not found"), {
              status: 404,
            });
          }
          const [protectedCurrent, protectedTarget] = await Promise.all([
            ensureUserProfile(base44, freshCurrent, persist),
            ensureUserProfile(base44, freshTarget, persist),
          ]);
          const existing = await relationshipBetween(
            base44,
            current.id,
            target.id,
          );
          if (
            existing?.status === "blocked" &&
            blockedByUserID(existing) !== current.id
          ) {
            throw Object.assign(new Error("Interaction unavailable"), {
              status: 403,
            });
          }
          const now = new Date().toISOString();
          const payload = {
            requester_id: clean(existing?.requester_id) || current.id,
            addressee_id: clean(existing?.addressee_id) || target.id,
            requester_spy_id: clean(existing?.requester_id) === target.id
              ? protectedTarget.spy_id
              : protectedCurrent.spy_id,
            addressee_spy_id: clean(existing?.addressee_id) === current.id
              ? protectedCurrent.spy_id
              : protectedTarget.spy_id,
            status: "blocked",
            blocked_by_id: current.id,
            updated_at: now,
          };
          if (existing) {
            await persist(() =>
              base44.asServiceRole.entities.Friendship.update(
                existing.id,
                payload,
              )
            );
          } else {
            await persist(() =>
              base44.asServiceRole.entities.Friendship.create({
                ...payload,
                created_at: now,
              })
            );
          }
          await deleteBlockedPairContent({
            profileCommentStore: base44.asServiceRole.entities.ProfileComment,
            roomInviteStore: base44.asServiceRole.entities.RoomInvite,
            firstUserID: current.id,
            secondUserID: target.id,
            persist,
          });
        },
      });
      return Response.json(await buildState(base44, current));
    }

    if (action === "unblock") {
      const friendshipID = clean(body.friendship_id);
      const initial = await findEntityByID(base44, "Friendship", friendshipID);
      if (!initial || !isParticipant(initial, current.id)) {
        return errorResponse("Relationship not found", 404);
      }
      await withCommunityWriteLeases({
        lifecycleStore,
        userIDs: [initial.requester_id, initial.addressee_id],
        action: async ({ persist }) => {
          const friendship = await findEntityByID(
            base44,
            "Friendship",
            friendshipID,
          );
          if (
            !friendship || !isParticipant(friendship, current.id) ||
            friendship.status !== "blocked"
          ) {
            throw Object.assign(new Error("Relationship not found"), {
              status: 404,
            });
          }
          if (blockedByUserID(friendship) !== current.id) {
            throw Object.assign(new Error("Relationship cannot be unblocked"), {
              status: 403,
            });
          }
          await persist(() =>
            base44.asServiceRole.entities.Friendship.delete(friendship.id)
          );
        },
      });
      return Response.json(await buildState(base44, current));
    }

    if (action === "report") {
      const reportType = clean(body.report_type).toLowerCase();
      const reason = normalizeCommunityReportReason(body.reason);
      if (!reason || !["user", "comment"].includes(reportType)) {
        return errorResponse(
          "A valid report reason and type are required",
          422,
        );
      }
      const commentID = reportType === "comment" ? clean(body.comment_id) : "";
      const initialComment = commentID
        ? await findEntityByID(base44, "ProfileComment", commentID)
        : null;
      const initialTarget = reportType === "comment"
        ? await findUserByID(base44, clean(initialComment?.author_user_id))
        : await resolveTargetUser(base44, body);
      if (!initialTarget || (reportType === "comment" && !initialComment)) {
        return errorResponse("Reported content not found", 404);
      }
      if (initialTarget.id === current.id) {
        return errorResponse("You cannot report yourself", 409);
      }
      await withCommunityWriteLeases({
        lifecycleStore,
        userIDs: [current.id, initialTarget.id],
        action: async ({ persist }) => {
          const target = await findUserByID(base44, initialTarget.id);
          if (!target) {
            throw Object.assign(new Error("Reported content not found"), {
              status: 404,
            });
          }
          let snapshot = `${clean(target.display_name || target.full_name)} ${
            clean(target.spy_id)
          }`;
          if (reportType === "comment") {
            const comment = await findEntityByID(
              base44,
              "ProfileComment",
              commentID,
            );
            if (!comment || clean(comment.author_user_id) !== target.id) {
              throw Object.assign(new Error("Reported content not found"), {
                status: 404,
              });
            }
            snapshot = clean(comment.body);
          }
          const reportIdentity: Entity = {
            reporter_user_id: current.id,
            reported_user_id: target.id,
            report_type: reportType,
          };
          if (commentID) reportIdentity.comment_id = commentID;
          const [open, reviewing] = await Promise.all([
            base44.asServiceRole.entities.CommunityReport.filter({
              ...reportIdentity,
              status: "open",
            }),
            base44.asServiceRole.entities.CommunityReport.filter({
              ...reportIdentity,
              status: "reviewing",
            }),
          ]);
          if ((open?.length || 0) + (reviewing?.length || 0) > 0) return;
          const now = new Date().toISOString();
          await persist(() =>
            base44.asServiceRole.entities.CommunityReport.create({
              ...reportIdentity,
              reason,
              details: sanitizeCommunityReportDetails(body.details),
              content_snapshot: sanitizeCommunityReportDetails(snapshot),
              status: "open",
              created_at: now,
              updated_at: now,
            })
          );
        },
      });
      return Response.json({ ok: true, message: "Report received" });
    }

    const friendshipID = clean(body.friendship_id);
    if (!friendshipID) return errorResponse("Friendship ID required", 422);
    const initialFriendship = await findEntityByID(
      base44,
      "Friendship",
      friendshipID,
    );
    if (!initialFriendship || !isParticipant(initialFriendship, current.id)) {
      return errorResponse("Relationship not found", 404);
    }
    if (
      !["accept", "decline", "cancel_request", "remove_friend"].includes(
        action,
      )
    ) {
      return errorResponse("Unsupported action", 400);
    }
    await withCommunityWriteLeases({
      lifecycleStore,
      userIDs: [
        initialFriendship.requester_id,
        initialFriendship.addressee_id,
      ],
      action: async ({ persist }) => {
        const friendship = await findEntityByID(
          base44,
          "Friendship",
          friendshipID,
        );
        if (!friendship || !isParticipant(friendship, current.id)) {
          throw Object.assign(new Error("Relationship not found"), {
            status: 404,
          });
        }
        if (friendship.status === "blocked") {
          throw Object.assign(new Error("Relationship unavailable"), {
            status: 403,
          });
        }
        if (
          ["accept", "decline"].includes(action) &&
          (friendship.addressee_id !== current.id ||
            friendship.status !== "pending")
        ) {
          throw Object.assign(new Error("Request cannot be updated"), {
            status: 409,
          });
        }
        if (
          action === "cancel_request" &&
          (friendship.requester_id !== current.id ||
            friendship.status !== "pending")
        ) {
          throw Object.assign(new Error("Request cannot be cancelled"), {
            status: 409,
          });
        }
        if (action === "remove_friend" && friendship.status !== "accepted") {
          throw Object.assign(new Error("Not friends"), { status: 409 });
        }
        if (["accept", "decline"].includes(action)) {
          await persist(() =>
            base44.asServiceRole.entities.Friendship.update(friendship.id, {
              status: action === "accept" ? "accepted" : "declined",
              blocked_by_id: null,
              updated_at: new Date().toISOString(),
            })
          );
        } else {
          await persist(() =>
            base44.asServiceRole.entities.Friendship.delete(friendship.id)
          );
        }
      },
    });
    return Response.json(await buildState(base44, current));
  } catch (error: any) {
    console.error("communityAction", error?.message, error?.stack);
    const status = error instanceof BillingIdentityLifecycleError
      ? 503
      : Number(error?.status || error?.statusCode || 500);
    return errorResponse(
      status >= 400 && status < 600 ? error?.message : "Community unavailable",
      status,
    );
  }
});
