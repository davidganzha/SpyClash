function failureStatus(error) {
  return Number(error?.status || error?.response?.status || error?.data?.status) || 500;
}

function failureCode(error) {
  // Axios may set code=ERR_BAD_REQUEST while the server supplies the actual
  // conflict code in the response body. Domain codes must win.
  return error?.response?.data?.code || error?.data?.code || error?.code || null;
}

function failureRetryable(error) {
  return (error?.response?.data?.retryable ?? error?.data?.retryable ??
    error?.retryable) === true;
}

function failureMessage(error) {
  return error?.data?.error
    || error?.response?.data?.error
    || error?.message
    || "Room action failed";
}

export function normalizeActionFailure(error) {
  return Object.assign(new Error(failureMessage(error)), {
    status: failureStatus(error),
    code: failureCode(error),
    retryable: failureRetryable(error),
  });
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
}) {
  if (!accessToken) {
    try {
      const result = await invoke(body);
      return result?.data ?? result;
    } catch (error) {
      throw normalizeActionFailure(error);
    }
  }

  const response = await request(endpoint, {
    method: "POST",
    credentials: "omit",
    headers,
    body: JSON.stringify({
      ...body,
      access_token: accessToken,
    }),
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
}
