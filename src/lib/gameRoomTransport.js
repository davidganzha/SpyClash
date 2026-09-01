function failureStatus(error) {
  return Number(error?.status || error?.response?.status || error?.data?.status) || 500;
}

function failureCode(error) {
  return error?.code || error?.data?.code || error?.response?.data?.code || null;
}

function failureRetryable(error) {
  return error?.retryable === true
    || error?.data?.retryable === true
    || error?.response?.data?.retryable === true;
}

function failureMessage(error) {
  return error?.data?.error
    || error?.response?.data?.error
    || error?.message
    || "Room action failed";
}

function normalizedFailure(error) {
  return Object.assign(new Error(failureMessage(error)), {
    status: failureStatus(error),
    code: failureCode(error),
    retryable: failureRetryable(error),
  });
}

export const GAME_ROOM_READ_DEADLINE_MILLISECONDS = 3_000;
export const GAME_ROOM_UNCERTAIN_MUTATION_DEADLINE_MILLISECONDS = 2_000;
const DEADLINED_UNCERTAIN_MUTATIONS = new Set([
  "request_vote",
  "cast_detective_vote",
  "close_room",
]);

function normalizedDeadlineMilliseconds(value) {
  const milliseconds = Number(value);
  return Number.isFinite(milliseconds) && milliseconds > 0
    ? milliseconds
    : null;
}

export function gameRoomActionDeadlineMilliseconds(body, override = undefined) {
  if (override !== undefined) return normalizedDeadlineMilliseconds(override);
  const action = String(body?.action || "").trim();
  if (action === "get_room") return GAME_ROOM_READ_DEADLINE_MILLISECONDS;
  return DEADLINED_UNCERTAIN_MUTATIONS.has(action)
    ? GAME_ROOM_UNCERTAIN_MUTATION_DEADLINE_MILLISECONDS
    : null;
}

function actionDeadlineError(body) {
  const isRoomRead = String(body?.action || "").trim() === "get_room";
  return Object.assign(new Error(
    isRoomRead ? "Room refresh timed out" : "Room action timed out",
  ), {
    name: "GameRoomActionTimeoutError",
    status: 408,
    code: isRoomRead ? "room_read_timeout" : "room_action_timeout",
    retryable: true,
  });
}

async function settleBeforeDeadline(operation, {
  body,
  deadlineMilliseconds,
  onTimeout = null,
}) {
  const deadline = normalizedDeadlineMilliseconds(deadlineMilliseconds);
  if (deadline === null) return await operation();

  let timeoutHandle = null;
  try {
    return await Promise.race([
      Promise.resolve().then(operation),
      new Promise((_, reject) => {
        timeoutHandle = setTimeout(() => {
          reject(actionDeadlineError(body));
          try {
            onTimeout?.();
          } catch {
            // The deadline remains authoritative even if cancellation support fails.
          }
        }, deadline);
      }),
    ]);
  } finally {
    if (timeoutHandle !== null) clearTimeout(timeoutHandle);
  }
}

export function isRetryableRoomActionConflict(error) {
  const code = String(error?.code || "").trim().toLowerCase();
  return Number(error?.status) === 409
    && error?.retryable === true
    && ["active_lease", "cas_contention"].includes(code);
}

export async function dispatchGameRoomAction({
  body,
  accessToken,
  endpoint,
  headers,
  invoke,
  request,
  deadlineMilliseconds = undefined,
}) {
  const actionDeadlineMilliseconds = gameRoomActionDeadlineMilliseconds(
    body,
    deadlineMilliseconds,
  );
  if (!accessToken) {
    try {
      const result = await settleBeforeDeadline(
        () => invoke(body),
        { body, deadlineMilliseconds: actionDeadlineMilliseconds },
      );
      return result?.data ?? result;
    } catch (error) {
      throw normalizedFailure(error);
    }
  }

  const abortController = actionDeadlineMilliseconds !== null
    && typeof AbortController === "function"
    ? new AbortController()
    : null;
  return await settleBeforeDeadline(
    async () => {
      const response = await request(endpoint, {
        method: "POST",
        credentials: "omit",
        headers,
        body: JSON.stringify({
          ...body,
          access_token: accessToken,
        }),
        ...(abortController ? { signal: abortController.signal } : {}),
      });
      const payload = await response.json().catch(() => ({}));

      if (!response.ok) {
        throw Object.assign(new Error(payload?.error || "Room action failed"), {
          status: response.status,
          code: payload?.code || null,
          retryable: payload?.retryable === true,
        });
      }

      return payload;
    },
    {
      body,
      deadlineMilliseconds: actionDeadlineMilliseconds,
      onTimeout: () => abortController?.abort(),
    },
  );
}
