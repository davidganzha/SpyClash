export const MIN_GAME_PLAYERS = 3;
export const MAX_SPIES = 3;
export const MULTI_SPY_CLIENT_CAPABILITY = "multi_spy_v1";

function clean(value) {
  return String(value ?? "").normalize("NFKC").trim();
}

export function normalizedEmail(value) {
  return clean(value).toLocaleLowerCase();
}

export function maxSpyCountForPlayerCount(playerCount) {
  const players = Math.max(0, Math.floor(Number(playerCount) || 0));
  return Math.max(1, Math.min(MAX_SPIES, Math.floor(players / 3)));
}

export function normalizeSpyCount(value, playerCount = null) {
  const requested = Number(value);
  const count = Number.isInteger(requested) ? requested : 1;
  const maximum = playerCount === null
    ? MAX_SPIES
    : maxSpyCountForPlayerCount(playerCount);
  return Math.max(1, Math.min(count, maximum));
}

export function isAllowedSpyCount(playerCount, spyCount) {
  const players = Math.floor(Number(playerCount) || 0);
  const spies = Number(spyCount);
  return players >= MIN_GAME_PLAYERS
    && Number.isInteger(spies)
    && spies >= 1
    && spies <= maxSpyCountForPlayerCount(players);
}

/**
 * Reads only role data that the server projected to this viewer. New rooms use
 * spy_emails; the scalar fallback keeps one-spy legacy rooms playable.
 */
export function projectedSpyEmails(room = {}) {
  const source = Array.isArray(room.spy_emails) && room.spy_emails.length > 0
    ? room.spy_emails
    : [room.spy_email];
  const seen = new Set();
  return source.flatMap((value) => {
    const email = normalizedEmail(value);
    if (!email || seen.has(email)) return [];
    seen.add(email);
    return [email];
  }).slice(0, MAX_SPIES);
}

export function isSpyEmailForRoom(room, email) {
  const viewer = normalizedEmail(email);
  return Boolean(viewer) && projectedSpyEmails(room).includes(viewer);
}

export function projectedSpyPlayers(room = {}) {
  const spies = new Set(projectedSpyEmails(room));
  if (!Array.isArray(room.players) || spies.size === 0) return [];
  return room.players.filter((player) => spies.has(normalizedEmail(player?.email)));
}

export function revealedSpyEmails(room = {}) {
  const seen = new Set();
  return (Array.isArray(room.revealed_spy_emails) ? room.revealed_spy_emails : [])
    .flatMap((value) => {
      const email = normalizedEmail(value);
      if (!email || seen.has(email)) return [];
      seen.add(email);
      return [email];
    })
    .slice(0, MAX_SPIES);
}

export function resultSpyPlayers(room = {}) {
  const emails = new Set([...projectedSpyEmails(room), ...revealedSpyEmails(room)]);
  if (!Array.isArray(room.players)) return [];
  return room.players.filter((player) => emails.has(normalizedEmail(player?.email)));
}

/**
 * Teammates are shown only when the public lobby switch is on and the backend
 * projected their addresses to this spy. The client never reconstructs a team.
 */
export function projectedSpyTeammates(room, viewerEmail) {
  if (room?.spies_know_each_other !== true || !isSpyEmailForRoom(room, viewerEmail)) {
    return [];
  }
  const viewer = normalizedEmail(viewerEmail);
  return projectedSpyPlayers(room).filter(
    (player) => normalizedEmail(player?.email) !== viewer,
  );
}

export function publicSpyCount(room = {}) {
  return normalizeSpyCount(room.lobby_spy_count ?? room.spy_count ?? 1);
}

export function isRankedSpyRoom(room = {}) {
  return publicSpyCount(room) === 1 && room.ranked !== false;
}

export function withMultiSpyCapability(values = []) {
  const capabilities = Array.isArray(values) ? values : [];
  return [...new Set([
    ...capabilities.map(clean).filter(Boolean),
    MULTI_SPY_CLIENT_CAPABILITY,
  ])];
}

export function withMultiSpyPlayerCapability(player = {}) {
  return {
    ...player,
    client_capabilities: withMultiSpyCapability(player.client_capabilities),
  };
}

export function withMultiSpyActionCapability(body = {}) {
  return {
    ...body,
    client_capabilities: withMultiSpyCapability(body.client_capabilities),
  };
}

export function isClientUpdateRequiredError(error) {
  const code = clean(error?.code).toLocaleLowerCase();
  return [
    "client_update_required",
    "multi_spy_client_update_required",
    "incompatible_client",
  ].includes(code);
}
