// Pure bounded paging policy shared by the admin-only gameRoomAction branch.
type Entity = Record<string, unknown>;

export type BackfillHistoryStore = {
  filter(
    query: Record<string, unknown>,
    sort?: string,
    limit?: number,
    skip?: number,
  ): Promise<Entity[]>;
};

type BackfillCursor = {
  version: 1;
  offset: number;
  anchorID: string;
};

export type CommunityProfileBackfillPage = {
  dry_run: boolean;
  history_rows_scanned: number;
  stable_users_found: number;
  reconciled_users: number;
  player_user_ids: string[];
  next_cursor: string | null;
};

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function encodeBase64URL(value: string): string {
  const bytes = new TextEncoder().encode(value);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_")
    .replace(/=+$/g, "");
}

function decodeBase64URL(value: string): string {
  const padded = value.replaceAll("-", "+").replaceAll("_", "/") +
    "=".repeat((4 - value.length % 4) % 4);
  const binary = atob(padded);
  return new TextDecoder().decode(
    Uint8Array.from(binary, (character) => character.charCodeAt(0)),
  );
}

function cursorError(): Error {
  return Object.assign(new Error("Backfill cursor is invalid or stale"), {
    status: 409,
    code: "backfill_cursor_stale",
  });
}

export function encodeBackfillCursor(
  offset: number,
  anchorIDValue: unknown,
): string {
  const anchorID = clean(anchorIDValue);
  if (!Number.isSafeInteger(offset) || offset < 1 || !anchorID) {
    throw cursorError();
  }
  return encodeBase64URL(JSON.stringify(
    {
      version: 1,
      offset,
      anchorID,
    } satisfies BackfillCursor,
  ));
}

export function decodeBackfillCursor(value: unknown): BackfillCursor | null {
  const encoded = clean(value);
  if (!encoded) return null;
  try {
    const parsed = JSON.parse(decodeBase64URL(encoded));
    if (
      parsed?.version !== 1 || !Number.isSafeInteger(parsed?.offset) ||
      parsed.offset < 1 || !clean(parsed?.anchorID)
    ) throw cursorError();
    return {
      version: 1,
      offset: parsed.offset,
      anchorID: clean(parsed.anchorID),
    };
  } catch {
    throw cursorError();
  }
}

export function normalizedBackfillBatchSize(value: unknown): number {
  const candidate = Number(value);
  if (!Number.isFinite(candidate)) return 50;
  return Math.max(1, Math.min(Math.trunc(candidate), 100));
}

async function assertCursorAnchor(
  store: BackfillHistoryStore,
  cursor: BackfillCursor | null,
): Promise<void> {
  if (!cursor) return;
  const anchor = await store.filter(
    {},
    "created_date",
    1,
    cursor.offset - 1,
  ) || [];
  if (clean(anchor[0]?.id) !== cursor.anchorID) throw cursorError();
}

export async function runCommunityProfileBackfillPage(input: {
  historyStore: BackfillHistoryStore;
  cursor?: unknown;
  batchSize?: unknown;
  apply: boolean;
  reconcileUser: (userID: string) => Promise<void>;
}): Promise<CommunityProfileBackfillPage> {
  const cursor = decodeBackfillCursor(input.cursor);
  await assertCursorAnchor(input.historyStore, cursor);
  const offset = cursor?.offset || 0;
  const batchSize = normalizedBackfillBatchSize(input.batchSize);
  const rows = await input.historyStore.filter(
    {},
    "created_date",
    batchSize + 1,
    offset,
  ) || [];
  const page = rows.slice(0, batchSize);
  const playerUserIDs = [
    ...new Set(
      page.map((row) => clean(row?.player_user_id)).filter(Boolean),
    ),
  ].sort();

  let reconciledUsers = 0;
  if (input.apply) {
    // A failure returns no cursor. Retrying the same input safely repeats only
    // absolute per-user mirrors; already-completed users are unchanged.
    for (const userID of playerUserIDs) {
      await input.reconcileUser(userID);
      reconciledUsers += 1;
    }
  }

  const last = page.at(-1);
  const nextCursor = rows.length > page.length && last
    ? encodeBackfillCursor(offset + page.length, last.id)
    : null;
  return {
    dry_run: !input.apply,
    history_rows_scanned: page.length,
    stable_users_found: playerUserIDs.length,
    reconciled_users: reconciledUsers,
    player_user_ids: playerUserIDs,
    next_cursor: nextCursor,
  };
}
