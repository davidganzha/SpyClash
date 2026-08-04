const LEGACY_ONLINE_ROOM_CODE = /^[A-Z0-9]{6}$/;

export function isOnlineGameHistory(record) {
  const matchType = String(record?.match_type || "").trim().toLowerCase();
  if (matchType) return matchType === "online" && record?.ranked !== false;
  if (record?.ranked === false) return false;

  // GameHistory predates match_type. Legacy records came from six-character
  // online room codes; local pass-and-play never created GameHistory rows.
  const roomCode = String(record?.room_code || "").trim().toUpperCase();
  return LEGACY_ONLINE_ROOM_CODE.test(roomCode);
}

export function mergePlayerGameHistory(streams, limit = null) {
  const byId = new Map();
  let anonymousIndex = 0;

  streams.flat().forEach(record => {
    if (!isOnlineGameHistory(record)) return;
    const id = String(record?.id || "").trim();
    const key = id ? `id:${id}` : `anonymous:${anonymousIndex++}`;
    if (!byId.has(key)) byId.set(key, record);
  });

  const history = [...byId.values()].sort((left, right) =>
    String(right?.created_date || "").localeCompare(String(left?.created_date || ""))
  );
  return limit === null ? history : history.slice(0, Math.max(0, limit));
}
