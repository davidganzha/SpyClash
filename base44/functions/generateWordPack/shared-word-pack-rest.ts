import {
  selectSharedWordPackStock,
  type SharedWordPackHit,
  SharedWordPackLibraryError,
  type SharedWordPackLibraryStore,
  type SharedWordPackRequest,
  type SharedWordPackVariant,
} from "./shared-word-pack-library.ts";

/** Server-only adapter. No Supabase credentials are sent to an app or logged. */
export function createSharedWordPackRESTStore(options: {
  url: string;
  secret: string;
  fetch?: typeof fetch;
}): SharedWordPackLibraryStore {
  let origin: URL;
  const secret = options.secret.trim();
  try {
    origin = new URL(options.url);
    const local = ["localhost", "127.0.0.1", "[::1]"].includes(origin.hostname);
    if (
      origin.protocol !== "https:" && !(local && origin.protocol === "http:")
    ) throw new Error();
    if (
      origin.username || origin.password || origin.search || origin.hash ||
      origin.pathname !== "/"
    ) throw new Error();
    if (!secret || secret.startsWith("sb_publishable_")) throw new Error();
  } catch {
    throw new SharedWordPackLibraryError(
      "shared_library_unconfigured",
      "Word library is not configured. Try again later.",
    );
  }
  const headers: Record<string, string> = {
    apikey: secret,
    "Content-Type": "application/json",
  };
  // New secret keys are not JWTs. The gateway derives the role from apikey.
  if (!secret.startsWith("sb_secret_")) {
    headers.Authorization = `Bearer ${secret}`;
  }
  async function rpc(
    name: string,
    body: Record<string, unknown>,
  ): Promise<unknown> {
    try {
      const response = await (options.fetch ?? fetch)(
        new URL(`/rest/v1/rpc/${name}`, origin),
        {
          method: "POST",
          headers,
          body: JSON.stringify(body),
          signal: AbortSignal.timeout(8_000),
          // Base44's Workers runtime rejects "error" before sending. Manual
          // keeps credentials on this origin; the non-2xx check rejects 3xx.
          redirect: "manual",
        },
      );
      if (!response.ok) throw new Error();
      const text = await response.text();
      return text ? JSON.parse(text) : null;
    } catch {
      // Provider errors must not expose raw server responses or credentials.
      throw new SharedWordPackLibraryError();
    }
  }
  return {
    async read(request) {
      const records = await rpc("word_pack_library_read", {
        p_cache_key: request.cacheKey,
      });
      if (!Array.isArray(records)) throw new SharedWordPackLibraryError();
      return await selectSharedWordPackStock({ request, records });
    },
    async claim(cacheKey, token) {
      const claimed = await rpc("word_pack_library_claim", {
        p_cache_key: cacheKey,
        p_token: token,
      });
      if (typeof claimed !== "boolean") throw new SharedWordPackLibraryError();
      return claimed;
    },
    async publish(record: SharedWordPackVariant, token: string) {
      const saved = await rpc("word_pack_library_publish", {
        p_record: record,
        p_token: token,
      });
      if (typeof saved !== "boolean") throw new SharedWordPackLibraryError();
      return saved;
    },
    async release(cacheKey, token) {
      await rpc("word_pack_library_release", {
        p_cache_key: cacheKey,
        p_token: token,
      });
    },
  };
}

export type SharedWordPackAccess = {
  hit: SharedWordPackHit | null;
  seedWords: string[];
  token: string | null;
  release(): Promise<void>;
};

/** Run before starting the durable paid operation: a busy library or failed
 * lookup has no quota/provider effects, and the same request remains retryable. */
export async function acquireSharedWordPackAccess(
  store: SharedWordPackLibraryStore,
  request: SharedWordPackRequest,
): Promise<SharedWordPackAccess> {
  const hit = await store.read(request);
  if (hit && !hit.needsGeneration) return { hit, seedWords: [], token: null, release: async () => {} };
  const token = crypto.randomUUID();
  if (!await store.claim(request.cacheKey, token)) {
    throw new SharedWordPackLibraryError(
      "shared_library_busy",
      "This topic is being prepared. Retry the same request shortly.",
    );
  }
  const release = async () => {
    // A lost cleanup ACK cannot turn a valid result into a failed generation.
    // SQL compares the owner token, and an abandoned lease expires.
    await store.release(request.cacheKey, token).catch(() => {});
  };
  try {
    const afterClaim = await store.read(request);
    if (afterClaim && !afterClaim.needsGeneration) {
      await release();
      return { hit: afterClaim, seedWords: [], token: null, release: async () => {} };
    }
    return { hit: null, seedWords: afterClaim?.words ?? [], token, release };
  } catch (error) {
    await release();
    throw error;
  }
}
