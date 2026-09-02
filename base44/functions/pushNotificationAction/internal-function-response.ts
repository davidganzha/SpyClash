type Entity = Record<string, unknown>;

function record(value: unknown): Entity | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Entity
    : null;
}

function count(value: unknown): number {
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(parsed)) return 0;
  return Math.min(Math.max(Math.floor(parsed), 0), 1_000_000);
}

/**
 * Backend Base44 clients deliberately keep raw Axios responses for function
 * calls (`interceptResponses: false`). Never return that wrapper from another
 * function: its request graph contains circular ClientRequest references.
 * This also accepts a future SDK that may unwrap the body directly.
 */
export function internalFunctionBody(response: unknown): Entity {
  const outer = record(response);
  if (!outer) return {};
  return record(outer.data) || outer;
}

export function profileRepairDrainSummary(response: unknown): Entity {
  const body = internalFunctionBody(response);
  return {
    ok: body.ok === true,
    selected: count(body.selected),
    performed: count(body.performed),
    completed: count(body.completed),
    deferred: count(body.deferred),
  };
}
