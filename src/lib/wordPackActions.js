import { appParams } from "@/lib/app-params";

export class WordPackActionError extends Error {
  constructor(message, status, code = null) {
    super(message);
    this.name = "WordPackActionError";
    this.status = status;
    this.code = code;
  }
}

function storedAccessToken() {
  try {
    return appParams.token
      || localStorage.getItem("base44_access_token")
      || localStorage.getItem("token");
  } catch {
    return appParams.token;
  }
}

async function performWordPackAction(body) {
  const accessToken = storedAccessToken();
  if (!accessToken) throw new WordPackActionError("Missing access token", 401);

  const headers = {
    "Content-Type": "application/json",
    "X-App-Id": String(appParams.appId),
  };
  if (appParams.functionsVersion) {
    headers["Base44-Functions-Version"] = appParams.functionsVersion;
  }

  const response = await fetch(`/api/apps/${appParams.appId}/functions/wordPackAction`, {
    method: "POST",
    credentials: "omit",
    headers,
    body: JSON.stringify({ ...body, access_token: accessToken }),
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new WordPackActionError(
      payload?.error || "Word pack action failed",
      response.status,
      payload?.code || null,
    );
  }
  return payload;
}

export async function listWordPacks() {
  return await performWordPackAction({ action: "list" });
}

export async function createWordPack({ name, category, words }) {
  return await performWordPackAction({ action: "create", name, category, words });
}

export async function updateWordPack(id, { name, category, words }) {
  return await performWordPackAction({
    action: "update",
    pack_id: id,
    name,
    category,
    words,
  });
}

export async function deleteWordPack(id) {
  return await performWordPackAction({ action: "delete", pack_id: id });
}
