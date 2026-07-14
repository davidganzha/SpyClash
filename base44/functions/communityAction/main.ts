import { createClient, createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import {
  normalizeCommunityQuery,
  normalizeSpyID,
  preferredSpyIDOwner,
  profileMatchesCommunityQuery,
  publicProfile,
  roomAcceptsCommunityInvites,
  sanitizeProfileComment,
  stableSpyID,
} from "./community.ts";

type Entity = Record<string, any>;

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

async function ensureUserProfile(base44: any, user: Entity): Promise<Entity> {
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
        await base44.asServiceRole.entities.User.update(userID, patch);
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
    await base44.asServiceRole.entities.User.update(userID, patch);

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

function relationshipSummary(friendship: Entity | null, userID: string) {
  if (!friendship) return null;
  return {
    id: friendship.id,
    status: friendship.status,
    direction: friendship.requester_id === userID ? "outgoing" : "incoming",
  };
}

async function acceptedFriendProfiles(base44: any, userID: string) {
  const [requested, received] = await Promise.all([
    base44.asServiceRole.entities.Friendship.filter({ requester_id: userID }),
    base44.asServiceRole.entities.Friendship.filter({ addressee_id: userID }),
  ]);
  const accepted = uniqueByID([...(requested || []), ...(received || [])])
    .filter((friendship) => friendship.status === "accepted")
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
  const rows = await base44.asServiceRole.entities.ProfileComment.filter({
    target_user_id: targetUserID,
  }) || [];
  const comments = newestFirst(rows).slice(0, PROFILE_COMMENT_LIMIT);
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
  const [friends, comments] = await Promise.all([
    acceptedFriendProfiles(base44, target.id),
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
  const [pending, accepted] = await Promise.all([
    base44.asServiceRole.entities.RoomInvite.filter({
      recipient_user_id: current.id,
      status: "pending",
    }),
    base44.asServiceRole.entities.RoomInvite.filter({
      recipient_user_id: current.id,
      status: "accepted",
    }),
  ]);
  const invitations = newestFirst(
    uniqueByID([...(pending || []), ...(accepted || [])]),
  );

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
  const [requested, received, roomInvites] = await Promise.all([
    base44.asServiceRole.entities.Friendship.filter({ requester_id: user.id }),
    base44.asServiceRole.entities.Friendship.filter({ addressee_id: user.id }),
    incomingRoomInvites(base44, user),
  ]);
  const all = uniqueByID([...(requested || []), ...(received || [])]);

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
  for (const friendship of all) {
    const profile = await counterpart(friendship);
    if (!profile) continue;

    const requesterSpyID = friendship.requester_id === user.id
      ? user.spy_id
      : profile.spy_id;
    const addresseeSpyID = friendship.addressee_id === user.id
      ? user.spy_id
      : profile.spy_id;
    const identityPatch: Entity = {};
    if (friendship.requester_spy_id !== requesterSpyID) {
      identityPatch.requester_spy_id = requesterSpyID;
    }
    if (friendship.addressee_spy_id !== addresseeSpyID) {
      identityPatch.addressee_spy_id = addresseeSpyID;
    }
    if (Object.keys(identityPatch).length) {
      await base44.asServiceRole.entities.Friendship.update(
        friendship.id,
        identityPatch,
      );
      Object.assign(friendship, identityPatch);
    }

    const record = {
      id: friendship.id,
      status: friendship.status,
      direction: friendship.requester_id === user.id ? "outgoing" : "incoming",
      profile,
    };
    if (friendship.status === "accepted") friends.push(record);
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
    incoming_room_invites: roomInvites,
  };
}

async function buildDirectory(base44: any, body: Entity) {
  const query = normalizeCommunityQuery(body.query);
  const offset = integer(body.offset, 0, 0, 1_000_000);
  const limit = integer(
    body.limit,
    DIRECTORY_DEFAULT_LIMIT,
    1,
    DIRECTORY_MAX_LIMIT,
  );
  const exactSpyID = normalizeSpyID(body.query);

  if (exactSpyID) {
    const result = await findUserBySpyID(base44, exactSpyID);
    return {
      profiles: result.user ? [publicProfile(result.user)] : [],
      next_offset: null,
    };
  }

  if (query) {
    const all = await listAllUsers(base44);
    const matching = all.filter((candidate) =>
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

  const page = await base44.asServiceRole.entities.User.list(
    "-created_date",
    limit + 1,
    offset,
  ) || [];
  const visible = page.slice(0, limit);
  const profiles = await Promise.all(
    visible.map(async (candidate: Entity) =>
      publicProfile(await ensureUserProfile(base44, candidate))
    ),
  );
  return {
    profiles,
    next_offset: page.length > limit ? offset + limit : null,
  };
}

async function sendFriendRequest(base44: any, current: Entity, target: Entity) {
  if (target.id === current.id) {
    throw Object.assign(new Error("Cannot add yourself"), { status: 409 });
  }
  const existing = await relationshipBetween(base44, current.id, target.id);
  if (existing?.status === "accepted") {
    throw Object.assign(new Error("Already friends"), { status: 409 });
  }
  if (existing?.status === "pending") {
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
    updated_at: now,
  };
  if (existing) {
    await base44.asServiceRole.entities.Friendship.update(existing.id, payload);
  } else {
    await base44.asServiceRole.entities.Friendship.create({
      ...payload,
      created_at: now,
    });
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
    const action = clean(body.action || "state").toLowerCase();
    const current = await ensureUserProfile(base44, user);

    if (action === "state") {
      return Response.json(await buildState(base44, current));
    }
    if (action === "directory") {
      return Response.json(await buildDirectory(base44, body));
    }

    if (action === "search") {
      const found = await findUserBySpyID(base44, body.spy_id);
      if (!found.spyID) return errorResponse("Invalid SPY ID", 422);
      if (!found.user) return errorResponse("Operative not found", 404);
      const relationship = found.user.id === current.id
        ? null
        : await relationshipBetween(base44, current.id, found.user.id);
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
      await sendFriendRequest(base44, current, target);
      return Response.json(await buildState(base44, current));
    }

    if (action === "add_comment") {
      const target = await resolveTargetUser(base44, body);
      if (!target) return errorResponse("Operative not found", 404);
      if (target.id === current.id) {
        return errorResponse("Comment on another operative's profile", 409);
      }
      const comment = sanitizeProfileComment(body.comment);
      if (!comment) {
        return errorResponse("Comment must contain 1-280 characters", 422);
      }

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
        return errorResponse("Wait before posting another comment", 429);
      }

      const now = new Date().toISOString();
      await base44.asServiceRole.entities.ProfileComment.create({
        target_user_id: target.id,
        author_user_id: current.id,
        body: comment,
        created_at: now,
        updated_at: now,
      });
      return Response.json(await buildProfileDetail(base44, current, target));
    }

    if (action === "delete_comment") {
      const commentID = clean(body.comment_id);
      const comment = await findEntityByID(base44, "ProfileComment", commentID);
      if (!comment) return errorResponse("Comment not found", 404);
      if (
        comment.author_user_id !== current.id &&
        comment.target_user_id !== current.id
      ) {
        return errorResponse("Comment cannot be deleted", 403);
      }
      const target = await findUserByID(base44, clean(comment.target_user_id));
      await base44.asServiceRole.entities.ProfileComment.delete(comment.id);
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
      const room = await validateRoomInvite(base44, current, body, target);
      const existing = newestFirst(
        await base44.asServiceRole.entities.RoomInvite.filter({
          sender_user_id: current.id,
          recipient_user_id: target.id,
          room_id: room.id,
        }) || [],
      )[0];
      const now = new Date().toISOString();
      const payload = {
        sender_user_id: current.id,
        recipient_user_id: target.id,
        room_id: room.id,
        room_code: clean(room.code).toUpperCase(),
        status: "pending",
        updated_at: now,
      };
      if (existing) {
        await base44.asServiceRole.entities.RoomInvite.update(
          existing.id,
          payload,
        );
      } else {
        await base44.asServiceRole.entities.RoomInvite.create({
          ...payload,
          created_at: now,
        });
      }
      return Response.json({ ok: true });
    }

    if (
      ["accept_room_invite", "decline_room_invite", "consume_room_invite"]
        .includes(action)
    ) {
      const inviteID = clean(body.invite_id);
      const invite = await findEntityByID(base44, "RoomInvite", inviteID);
      if (!invite || invite.recipient_user_id !== current.id) {
        return errorResponse("Room invite not found", 404);
      }

      if (action === "decline_room_invite") {
        await base44.asServiceRole.entities.RoomInvite.delete(invite.id);
        return Response.json({
          state: await buildState(base44, current),
          room_code: null,
        });
      }
      if (action === "consume_room_invite") {
        if (invite.status !== "accepted") {
          return errorResponse("Room invite is not accepted", 409);
        }
        await base44.asServiceRole.entities.RoomInvite.delete(invite.id);
        return Response.json({
          state: await buildState(base44, current),
          room_code: null,
        });
      }

      const room = await findEntityByID(
        base44,
        "GameRoom",
        clean(invite.room_id),
      );
      if (!room || !roomAcceptsCommunityInvites(room.status)) {
        await base44.asServiceRole.entities.RoomInvite.update(invite.id, {
          status: "expired",
          updated_at: new Date().toISOString(),
        });
        return errorResponse("Room is no longer available", 409);
      }
      await base44.asServiceRole.entities.RoomInvite.update(invite.id, {
        status: "accepted",
        updated_at: new Date().toISOString(),
      });
      return Response.json({
        state: await buildState(base44, current),
        room_code: clean(room.code).toUpperCase(),
      });
    }

    const friendshipID = clean(body.friendship_id);
    if (!friendshipID) return errorResponse("Friendship ID required", 422);
    const friendship = await findEntityByID(base44, "Friendship", friendshipID);
    if (!friendship || !isParticipant(friendship, current.id)) {
      return errorResponse("Relationship not found", 404);
    }

    if (action === "accept") {
      if (
        friendship.addressee_id !== current.id ||
        friendship.status !== "pending"
      ) {
        return errorResponse("Request cannot be accepted", 409);
      }
      await base44.asServiceRole.entities.Friendship.update(friendship.id, {
        status: "accepted",
        updated_at: new Date().toISOString(),
      });
    } else if (action === "decline") {
      if (
        friendship.addressee_id !== current.id ||
        friendship.status !== "pending"
      ) {
        return errorResponse("Request cannot be declined", 409);
      }
      await base44.asServiceRole.entities.Friendship.update(friendship.id, {
        status: "declined",
        updated_at: new Date().toISOString(),
      });
    } else if (action === "cancel_request") {
      if (
        friendship.requester_id !== current.id ||
        friendship.status !== "pending"
      ) {
        return errorResponse("Request cannot be cancelled", 409);
      }
      await base44.asServiceRole.entities.Friendship.delete(friendship.id);
    } else if (action === "remove_friend") {
      if (friendship.status !== "accepted") {
        return errorResponse("Not friends", 409);
      }
      await base44.asServiceRole.entities.Friendship.delete(friendship.id);
    } else {
      return errorResponse("Unsupported action", 400);
    }

    return Response.json(await buildState(base44, current));
  } catch (error: any) {
    console.error("communityAction", error?.message, error?.stack);
    const status = Number(error?.status || error?.statusCode || 500);
    return errorResponse(
      status >= 400 && status < 600 ? error?.message : "Community unavailable",
      status,
    );
  }
});
