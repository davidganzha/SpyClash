import { base44 } from "@/api/base44Client";
import {
  isOnlineGameHistory,
  mergePlayerGameHistory,
} from "./gameHistoryPolicy";

const PAGE_SIZE = 100;

async function loadOnlineHistory(query, requestedLimit = null) {
  const history = [];
  const seenIds = new Set();
  let offset = 0;

  while (true) {
    const page = await base44.entities.GameHistory.filter(
      query,
      "-created_date",
      PAGE_SIZE,
      offset,
    );
    const unseen = page.filter((record) => !record?.id || !seenIds.has(record.id));
    unseen.forEach((record) => {
      if (record?.id) seenIds.add(record.id);
    });
    history.push(...unseen.filter(isOnlineGameHistory));

    if (requestedLimit !== null && history.length >= requestedLimit) break;
    if (page.length < PAGE_SIZE || unseen.length === 0) break;
    offset += page.length;
  }

  return requestedLimit === null ? history : history.slice(0, requestedLimit);
}

/**
 * Full access loads the complete archive by default. A finite limit remains only as
 * an internal utility option for callers that intentionally request a preview.
 */
export async function loadPlayerGameHistory(email, {
  fullHistory = true,
  historyLimit = null,
  userId = null,
} = {}) {
  const limit = fullHistory || historyLimit === null
    ? null
    : Math.max(0, Number(historyLimit) || 0);
  if (limit === 0) return [];

  const queries = [
    String(userId || "").trim() ? { player_user_id: String(userId).trim() } : null,
    String(email || "").trim() ? { player_email: String(email).trim() } : null,
  ].filter(Boolean);
  const results = await Promise.allSettled(
    queries.map(query => loadOnlineHistory(query, null)),
  );
  const successful = results.filter(result => result.status === "fulfilled");
  if (successful.length === 0) {
    for (const result of results) {
      if (result.status === "rejected") throw result.reason;
    }
    throw new Error("Unable to load game history");
  }

  return mergePlayerGameHistory(
    successful.map(result => result.value),
    limit,
  );
}
