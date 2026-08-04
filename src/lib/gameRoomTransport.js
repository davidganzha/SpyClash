function failureStatus(error) {
  return Number(error?.status || error?.response?.status || error?.data?.status) || 500;
}

function failureCode(error) {
  return error?.code || error?.data?.code || error?.response?.data?.code || null;
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
  });
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
      throw normalizedFailure(error);
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
    });
  }

  return payload;
}
