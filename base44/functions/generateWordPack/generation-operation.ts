import type { PreparedWordPackIdempotency } from "./generation-idempotency.ts";
import { WordPackIdempotencyConflictError } from "./generation-idempotency.ts";
import {
  normalizeGeneratedWordPack,
  type WordPackResult,
} from "./generation-cache.ts";
import type { GenerationWriteGuard } from "./generation-write-lifecycle.ts";

export type WordPackOperationRecord = {
  id?: string;
  request_key: string;
  user_id: string;
  request_id: string;
  request_fingerprint: string;
  operation_token: string;
  state: "prepared" | "running" | "completed" | "failed";
  updated_at: string;
  result_words?: string[];
  result_category?: string;
  exhausted?: boolean;
  completed_at?: string;
};

export type WordPackOperationStore = {
  filter: (
    query: Record<string, unknown>,
    sort: string,
    limit: number,
    skip: number,
  ) => Promise<WordPackOperationRecord[]>;
  create: (record: WordPackOperationRecord) => Promise<WordPackOperationRecord>;
  updateMany: (
    query: Record<string, unknown>,
    update: Record<string, Record<string, unknown>>,
  ) => Promise<{ updated?: number }>;
};

export class WordPackOperationError extends Error {
  readonly status = 503;
  readonly retryable = false;
  constructor(
    readonly code:
      | "generation_outcome_unknown"
      | "generation_journal_unavailable",
    message: string,
  ) {
    super(message);
    this.name = "WordPackOperationError";
  }
}

function unavailable(): WordPackOperationError {
  return new WordPackOperationError(
    "generation_journal_unavailable",
    "Generation recovery is temporarily unavailable. No automatic new generation was started.",
  );
}

function uncertain(): WordPackOperationError {
  return new WordPackOperationError(
    "generation_outcome_unknown",
    "The previous generation has no confirmed result. It will not be repeated automatically. Start a new generation explicitly if needed.",
  );
}

function matches(
  row: WordPackOperationRecord,
  identity: PreparedWordPackIdempotency,
): boolean {
  return row.request_key === identity.requestKey &&
    row.user_id === identity.userID &&
    row.request_id === identity.requestID &&
    row.request_fingerprint === identity.requestFingerprint;
}

/** Fail closed on duplicate/invalid journal rows; never choose a fresh row over an older effect. */
async function lookup(
  store: WordPackOperationStore,
  identity: PreparedWordPackIdempotency,
): Promise<WordPackOperationRecord | null> {
  const rows = await store.filter(
    { request_key: identity.requestKey },
    "created_date",
    2,
    0,
  );
  if (rows.some((row) => !matches(row, identity))) {
    throw new WordPackIdempotencyConflictError();
  }
  if (rows.length > 1) throw unavailable();
  const row = rows[0];
  if (!row) return null;
  if (
    !row.id || !row.operation_token ||
    !["prepared", "running", "completed", "failed"].includes(row.state)
  ) throw unavailable();
  return row;
}

function result(row: WordPackOperationRecord): WordPackResult {
  try {
    return normalizeGeneratedWordPack({
      category: row.result_category,
      words: row.result_words,
      exhausted: row.exhausted,
    });
  } catch {
    throw unavailable();
  }
}

/** Read-only fast replay. A journal result does not depend on the legacy replay store. */
export async function lookupCompletedWordPackOperation(input: {
  store: WordPackOperationStore;
  identity: PreparedWordPackIdempotency;
}): Promise<WordPackResult | null> {
  const row = await lookup(input.store, input.identity);
  return row?.state === "completed" ? result(row) : null;
}

/**
 * Called inside the existing per-account generation coordinator. The durable
 * running marker commits BEFORE quota/provider work. A restarted invocation
 * may replay a completed result, but can never rerun an ambiguous operation.
 * Prepared rows are safe to take over: their exact-token CAS has not permitted
 * effects. There is deliberately no time-based deletion/retry of running rows.
 */
export async function runWordPackOperation<T>(input: {
  store: WordPackOperationStore;
  identity: PreparedWordPackIdempotency;
  guard: GenerationWriteGuard;
  execute: () => Promise<
    { value: T; result: WordPackResult | null; replayCommitted?: boolean }
  >;
  now?: () => Date;
  randomUUID?: () => string;
}): Promise<
  { replayed: true; result: WordPackResult } | { replayed: false; value: T }
> {
  const now = input.now ?? (() => new Date());
  const token = (input.randomUUID ?? (() => crypto.randomUUID()))();
  let row: WordPackOperationRecord | null;
  try {
    row = await lookup(input.store, input.identity);
    if (!row) {
      const prepared: WordPackOperationRecord = {
        request_key: input.identity.requestKey,
        user_id: input.identity.userID,
        request_id: input.identity.requestID,
        request_fingerprint: input.identity.requestFingerprint,
        operation_token: token,
        state: "prepared",
        updated_at: now().toISOString(),
      };
      // A lost create response can hide a durable row. Always reconcile before
      // deciding to proceed; never create a second row as an automatic retry.
      try {
        await input.guard.boundary(() => input.store.create(prepared));
      } catch { /* read below */ }
      row = await lookup(input.store, input.identity);
      if (!row) throw unavailable();
    }
    if (row.state === "completed") {
      return { replayed: true, result: result(row) };
    }
    if (row.state !== "prepared") throw uncertain();
    const observedToken = row.operation_token;
    const observedUpdatedAt = row.updated_at;
    let started: { updated?: number } | undefined;
    try {
      started = await input.guard.boundary(() =>
        input.store.updateMany({
          id: row!.id,
          state: "prepared",
          operation_token: observedToken,
          updated_at: observedUpdatedAt,
        }, {
          $set: {
            state: "running",
            operation_token: token,
            updated_at: now().toISOString(),
          },
        })
      );
    } catch {
      // The CAS may have committed. Only this exact token may continue, and
      // only after a fresh read confirms it. Otherwise no effects may start.
    }
    const confirmed = await lookup(input.store, input.identity);
    if (
      started?.updated === 0 || !confirmed || confirmed.state !== "running" ||
      confirmed.operation_token !== token
    ) throw uncertain();
    row = confirmed;
  } catch (error) {
    if (
      error instanceof WordPackOperationError ||
      error instanceof WordPackIdempotencyConflictError
    ) throw error;
    throw unavailable();
  }

  // A kill here or inside execute leaves running: the next request refuses to
  // repeat provider/quota effects, even after the account lease expires.
  const execution = await input.execute();
  const completedResult = execution.result
    ? normalizeGeneratedWordPack(execution.result)
    : null;
  const finalState = completedResult ? "completed" : "failed";
  const finalFields = {
    state: finalState,
    updated_at: now().toISOString(),
    ...(completedResult
      ? {
        result_category: "AI GENERATED",
        result_words: completedResult.words,
        exhausted: completedResult.exhausted,
        completed_at: now().toISOString(),
      }
      : {}),
  };
  // Exact CAS plus reconciliation tolerates a committed completion whose
  // response was lost; retrying this write never repeats generation itself.
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      await input.guard.boundary(() =>
        input.store.updateMany({
          id: row!.id,
          state: "running",
          operation_token: token,
        }, { $set: finalFields })
      );
    } catch { /* reconcile exact persisted outcome */ }
    try {
      const saved = await lookup(input.store, input.identity);
      if (saved?.operation_token === token && saved.state === finalState) {
        if (
          completedResult &&
          JSON.stringify(result(saved).words) !==
            JSON.stringify(completedResult.words)
        ) throw unavailable();
        return { replayed: false, value: execution.value };
      }
    } catch (error) {
      if (error instanceof WordPackIdempotencyConflictError) throw error;
    }
  }
  // The caller may already have committed a separately verified replay record.
  // Preserve those valid words despite journal maintenance failure. The running
  // marker remains durable and still forbids a second execution after a crash.
  if (completedResult && execution.replayCommitted === true) {
    console.warn(
      "generateWordPack journal completion deferred; replay result committed",
    );
    return { replayed: false, value: execution.value };
  }
  throw unavailable();
}
