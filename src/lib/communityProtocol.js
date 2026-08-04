export function createCommunityRequest(
  { appId, accessToken, functionsVersion },
  body,
) {
  const resolvedAppId = String(appId || "").trim();
  const resolvedToken = String(accessToken || "").trim();
  if (!resolvedAppId) throw new Error("Missing Base44 app ID");
  if (!resolvedToken) throw new Error("Missing access token");

  const headers = {
    "Content-Type": "application/json",
    "Base44-App-Id": resolvedAppId,
    // The local Base44/Vite gateway still routes by X-App-Id. The function
    // itself authenticates against Base44-App-Id and the body token.
    "X-App-Id": resolvedAppId,
  };
  if (functionsVersion) {
    headers["Base44-Functions-Version"] = String(functionsVersion);
  }

  /** @type {RequestInit} */
  const init = {
    method: "POST",
    credentials: "omit",
    headers,
    body: JSON.stringify({
      ...body,
      access_token: resolvedToken,
    }),
  };
  return {
    url: `/api/apps/${encodeURIComponent(resolvedAppId)}/functions/communityAction`,
    init,
  };
}

export function isExactSpyIDQuery(value) {
  return /^\s*[0-9]{3}[- ]?[0-9]{3}\s*$/.test(String(value || ""));
}

export function communityAttentionCount(state) {
  const friendRequests = Array.isArray(state?.incoming)
    ? state.incoming.filter((item) => item?.status === "pending").length
    : 0;
  const roomInvites = Array.isArray(state?.incoming_room_invites)
    ? state.incoming_room_invites.filter((item) =>
      ["pending", "accepted"].includes(String(item?.status || "").toLowerCase())
    ).length
    : 0;
  return friendRequests + roomInvites;
}

export function relationshipForProfile(state, userId) {
  const resolvedUserId = String(userId || "");
  for (const group of ["friends", "incoming", "outgoing", "blocked"]) {
    const relationship = (state?.[group] || []).find((item) =>
      String(item?.profile?.id || "") === resolvedUserId
    );
    if (relationship) return relationship;
  }
  return null;
}

export function stateWithoutRoomInvite(state, inviteId) {
  if (!state) return state;
  return {
    ...state,
    incoming_room_invites: (state.incoming_room_invites || []).filter(
      (invite) => invite?.id !== inviteId,
    ),
  };
}

export async function joinCommunityRoomInvite({
  invite,
  player,
  acceptInvite,
  joinRoom,
  rememberCleanup,
  consumeInvite,
  clearCleanup,
}) {
  let acceptedState = null;
  let roomCode = String(invite?.room_code || "").trim().toUpperCase();

  if (String(invite?.status || "").toLowerCase() !== "accepted") {
    const accepted = await acceptInvite(invite.id);
    acceptedState = accepted?.state || null;
    roomCode = String(accepted?.room_code || roomCode).trim().toUpperCase();
  }

  const room = await joinRoom({ roomCode, player });
  await rememberCleanup(invite.id);

  let cleanupPending = false;
  try {
    await consumeInvite(invite.id);
    await clearCleanup(invite.id);
  } catch (error) {
    if (error?.status === 404 || error?.status === 409) {
      await clearCleanup(invite.id);
    } else {
      cleanupPending = true;
    }
  }

  return { room, acceptedState, cleanupPending };
}
