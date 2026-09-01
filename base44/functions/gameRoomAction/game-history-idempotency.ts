type Entity = Record<string, unknown>;

export type GameHistoryResultStore = {
  filter(
    query: Record<string, unknown>,
    sort?: string,
    limit?: number,
    skip?: number,
  ): Promise<Entity[]>;
  create(value: Entity): Promise<unknown>;
};

export type PersistedGameHistoryResult = {
  status: "created" | "existing" | "recovered";
  record: Entity;
};

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

export function gameHistoryResultKey(
  matchIDValue: unknown,
  playerUserIDValue: unknown,
): string {
  const matchID = clean(matchIDValue);
  const playerUserID = clean(playerUserIDValue);
  if (!matchID || !playerUserID) {
    throw new Error("A stable match and player identity are required");
  }
  return `game-result:v1:${matchID}:${playerUserID}`;
}

function canonicalResult(rows: readonly Entity[]): Entity | null {
  return [...rows].sort((left, right) => {
    const leftCreated = clean(left?.created_date);
    const rightCreated = clean(right?.created_date);
    return leftCreated.localeCompare(rightCreated) ||
      clean(left?.id).localeCompare(clean(right?.id)) ||
      JSON.stringify(left).localeCompare(JSON.stringify(right));
  })[0] || null;
}

async function findPersistedResult(
  store: GameHistoryResultStore,
  resultKey: string,
  matchID: string,
  playerUserID: string,
): Promise<Entity | null> {
  const keyed =
    await store.filter({ result_key: resultKey }, "created_date", 4, 0) || [];
  const exactKeyed = keyed.filter((row) =>
    clean(row?.result_key) === resultKey
  );
  if (exactKeyed.length) return canonicalResult(exactKeyed);

  // Rollout compatibility: a row created immediately before `result_key`
  // shipped is still the same durable result when both stable identities
  // match. Mutable email is deliberately never used for reconciliation.
  const byMatch =
    await store.filter({ match_id: matchID }, "created_date", 100, 0) || [];
  return canonicalResult(
    byMatch.filter((row) =>
      clean(row?.match_id) === matchID &&
      clean(row?.player_user_id) === playerUserID
    ),
  );
}

export async function persistGameHistoryResult(input: {
  store: GameHistoryResultStore;
  record: Entity;
}): Promise<PersistedGameHistoryResult> {
  const matchID = clean(input.record?.match_id);
  const playerUserID = clean(input.record?.player_user_id);
  const resultKey = gameHistoryResultKey(matchID, playerUserID);
  const record = { ...input.record, result_key: resultKey };

  const existing = await findPersistedResult(
    input.store,
    resultKey,
    matchID,
    playerUserID,
  );
  if (existing) return { status: "existing", record: existing };

  try {
    const created = await input.store.create(record);
    return {
      status: "created",
      record: created && typeof created === "object"
        ? created as Entity
        : record,
    };
  } catch (createError) {
    // Base44 may durably commit an entity while its HTTP response is lost.
    // Recover by the deterministic result identity before allowing a retry to
    // issue another create. If the confirmation read also fails or is stale,
    // preserve the original error; aggregate/client dedupe remains defense in
    // depth for any historical duplicate already present.
    try {
      const recovered = await findPersistedResult(
        input.store,
        resultKey,
        matchID,
        playerUserID,
      );
      if (recovered) return { status: "recovered", record: recovered };
    } catch {
      // The create failure is the authoritative diagnostic for the caller.
    }
    throw createError;
  }
}
