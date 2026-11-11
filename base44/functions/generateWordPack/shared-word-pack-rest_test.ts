import {
  assert,
  assertEquals,
  assertRejects,
  assertThrows,
} from "jsr:@std/assert@1";
import {
  buildSharedWordPackVariant,
  prepareSharedWordPackRequest,
  type SharedWordPackHit,
  SharedWordPackLibraryError,
  type SharedWordPackLibraryStore,
} from "./shared-word-pack-library.ts";
import {
  acquireSharedWordPackAccess,
  createSharedWordPackRESTStore,
} from "./shared-word-pack-rest.ts";

const request = await prepareSharedWordPackRequest({
  theme: "Musical instruments",
  language: "und",
  promptVersion: "test-v1",
  requestedCount: 5,
  exclusions: [],
});
const record = await buildSharedWordPackVariant({
  request,
  result: {
    words: ["Piano", "Guitar", "Violin", "Cello", "Flute"],
    exhausted: false,
  },
});
const hit: SharedWordPackHit = {
  words: record.words,
  exhausted: false,
  variantKey: "local-hit",
  expiresAt: record.expires_at,
};
const origin = "https://library.example.test";
const token = "809f955b-05f8-456a-a4b4-1d70a19b998b";

class Store implements SharedWordPackLibraryStore {
  reads: (SharedWordPackHit | null | Error)[] = [null, null];
  claimed = true;
  calls: string[] = [];
  claimToken = "";
  releaseError = false;
  async read() {
    this.calls.push("read");
    const value = this.reads.shift() ?? null;
    if (value instanceof Error) throw value;
    return value;
  }
  async claim(key: string, owner: string) {
    this.calls.push("claim");
    assertEquals(key, request.cacheKey);
    this.claimToken = owner;
    return this.claimed;
  }
  async publish() {
    this.calls.push("publish");
    return true;
  }
  async release(key: string, owner: string) {
    this.calls.push("release");
    assertEquals(key, request.cacheKey);
    assertEquals(owner, this.claimToken);
    if (this.releaseError) throw new Error("lost cleanup response");
  }
}

Deno.test("shared REST uses server-only RPC and modern secret header without a JWT bearer", async () => {
  const calls: { url: string; body: any }[] = [];
  const store = createSharedWordPackRESTStore({
    url: origin,
    secret: "sb_secret_local_fixture",
    fetch: (input, init) => {
      const headers = new Headers(init?.headers);
      assertEquals(headers.get("apikey"), "sb_secret_local_fixture");
      assertEquals(headers.get("authorization"), null);
      assertEquals(headers.get("content-type"), "application/json");
      assertEquals(init?.method, "POST");
      assertEquals(init?.redirect, "manual");
      assert(init?.signal instanceof AbortSignal);
      const url = String(input), body = JSON.parse(String(init?.body));
      calls.push({ url, body });
      if (url.endsWith("_read")) {
        return Promise.resolve(Response.json([record]));
      }
      if (url.endsWith("_release")) {
        return Promise.resolve(new Response(null, { status: 204 }));
      }
      return Promise.resolve(Response.json(true));
    },
  });
  assertEquals((await store.read(request))?.words, record.words);
  assertEquals(await store.claim(request.cacheKey, token), true);
  assertEquals(await store.publish(record, token), true);
  await store.release(request.cacheKey, token);
  assertEquals(
    calls.map((call) => call.url),
    ["read", "claim", "publish", "release"].map((verb) =>
      `${origin}/rest/v1/rpc/word_pack_library_${verb}`
    ),
  );
  assertEquals(calls[0].body, { p_cache_key: request.cacheKey });
  assertEquals(calls[1].body, {
    p_cache_key: request.cacheKey,
    p_token: token,
  });
  assertEquals(calls[2].body, { p_record: record, p_token: token });
  assertEquals(calls[3].body, {
    p_cache_key: request.cacheKey,
    p_token: token,
  });
  assert(!JSON.stringify(calls).includes("Musical instruments"));
});

Deno.test("shared REST supports legacy service-role JWT in both required headers", async () => {
  const store = createSharedWordPackRESTStore({
    url: origin,
    secret: "fixture.service.role",
    fetch: (_input, init) => {
      const headers = new Headers(init?.headers);
      assertEquals(headers.get("apikey"), "fixture.service.role");
      assertEquals(headers.get("authorization"), "Bearer fixture.service.role");
      return Promise.resolve(Response.json([]));
    },
  });
  assertEquals(await store.read(request), null);
});

Deno.test("shared REST works with Workers redirect modes and rejects redirects without forwarding credentials", async () => {
  for (const status of [200, 301, 302, 303, 307, 308]) {
    const calls: string[] = [];
    const store = createSharedWordPackRESTStore({
      url: origin,
      secret: "sb_secret_local_fixture",
      fetch: (input, init) => {
        // Match Workers' request-construction restriction. The previous
        // redirect:error implementation fails even for an ordinary 200 read.
        if (init?.redirect === "error") throw new TypeError("Unsupported redirect mode");
        calls.push(String(input));
        assertEquals(init?.redirect, "manual");
        return Promise.resolve(status === 200 ? Response.json([record]) :
          new Response(null, { status, headers: { Location: "https://other.example.test/private" } }));
      },
    });
    if (status === 200) {
      assertEquals((await acquireSharedWordPackAccess(store, request)).hit?.words, record.words);
    } else {
      await assertRejects(() => acquireSharedWordPackAccess(store, request), SharedWordPackLibraryError);
    }
    assertEquals(calls, [`${origin}/rest/v1/rpc/word_pack_library_read`]);
  }
});

Deno.test("shared REST rejects unconfigured or unsafe destinations before any request", () => {
  for (
    const url of [
      "",
      "http://remote.example.test",
      `${origin}/path`,
      `${origin}/?key=x`,
      `${origin}/#fragment`,
      "https://user:password@example.test",
    ]
  ) {
    assertThrows(
      () => createSharedWordPackRESTStore({ url, secret: "sb_secret_fixture" }),
      SharedWordPackLibraryError,
    );
  }
  for (
    const secret of [
      "",
      "   ",
      "sb_publishable_fixture",
      " sb_publishable_fixture ",
    ]
  ) {
    assertThrows(
      () => createSharedWordPackRESTStore({ url: origin, secret }),
      SharedWordPackLibraryError,
    );
  }
  createSharedWordPackRESTStore({
    url: "http://127.0.0.1:56321",
    secret: "sb_secret_fixture",
  });
});

Deno.test("transport, timeout, HTTP and malformed read failures never authorize a cache miss", async () => {
  const responses: (() => Promise<Response>)[] = [
    () => Promise.reject(new Error("credential-sensitive backend error")),
    () => Promise.reject(new DOMException("timed out", "TimeoutError")),
    () =>
      Promise.resolve(
        new Response("credential-sensitive backend error", { status: 503 }),
      ),
    () => Promise.resolve(new Response("not json")),
    () => Promise.resolve(Response.json({ unexpected: [] })),
    () => Promise.resolve(Response.json(null)),
  ];
  for (const response of responses) {
    let calls = 0;
    const store = createSharedWordPackRESTStore({
      url: origin,
      secret: "sb_secret_fixture",
      fetch: () => {
        calls++;
        return response();
      },
    });
    const error = await assertRejects(
      () => acquireSharedWordPackAccess(store, request),
      SharedWordPackLibraryError,
    );
    assertEquals(error.status, 503);
    assertEquals(error.retryable, true);
    assert(!error.message.includes("credential-sensitive"));
    assertEquals(
      calls,
      1,
      "failed lookup must not progress to a generation lease",
    );
  }
});

Deno.test("shared REST distinguishes false claims from malformed boolean responses", async () => {
  const denied = createSharedWordPackRESTStore({
    url: origin,
    secret: "sb_secret_fixture",
    fetch: () => Promise.resolve(Response.json(false)),
  });
  assertEquals(await denied.claim(request.cacheKey, token), false);
  assertEquals(await denied.publish(record, token), false);
  for (const value of [null, "true", 1, { claimed: true }]) {
    const store = createSharedWordPackRESTStore({
      url: origin,
      secret: "sb_secret_fixture",
      fetch: () => Promise.resolve(Response.json(value)),
    });
    await assertRejects(
      () => store.claim(request.cacheKey, token),
      SharedWordPackLibraryError,
    );
    await assertRejects(
      () => store.publish(record, token),
      SharedWordPackLibraryError,
    );
  }
});

Deno.test("shared preflight hit returns stock without a topic lease", async () => {
  const store = new Store();
  store.reads = [hit];
  const access = await acquireSharedWordPackAccess(store, request);
  assertEquals(access.hit, hit);
  assertEquals(access.token, null);
  await access.release();
  assertEquals(store.calls, ["read"]);
});

Deno.test("shared preflight rereads under its claim before authorizing provider work", async () => {
  const store = new Store();
  const access = await acquireSharedWordPackAccess(store, request);
  assertEquals(access.hit, null);
  assertEquals(access.token, store.claimToken);
  assert(/^[0-9a-f-]{36}$/.test(access.token!));
  assertEquals(store.calls, ["read", "claim", "read"]);
  await access.release();
  assertEquals(store.calls, ["read", "claim", "read", "release"]);
});

Deno.test("a result published during claim acquisition suppresses provider work", async () => {
  const store = new Store();
  store.reads = [null, hit];
  const access = await acquireSharedWordPackAccess(store, request);
  assertEquals(access.hit, hit);
  assertEquals(access.token, null);
  await access.release();
  assertEquals(store.calls, ["read", "claim", "read", "release"]);
});

Deno.test("another worker's claim yields retryable busy without releasing its lease", async () => {
  const store = new Store();
  store.claimed = false;
  const error = await assertRejects(
    () => acquireSharedWordPackAccess(store, request),
    SharedWordPackLibraryError,
  );
  assertEquals(error.code, "shared_library_busy");
  assertEquals(error.retryable, true);
  assertEquals(store.calls, ["read", "claim"]);
});

Deno.test("failed reread releases only the owned topic lease and remains an error", async () => {
  const store = new Store();
  store.reads = [null, new SharedWordPackLibraryError()];
  await assertRejects(
    () => acquireSharedWordPackAccess(store, request),
    SharedWordPackLibraryError,
  );
  assertEquals(store.calls, ["read", "claim", "read", "release"]);
});

Deno.test("cleanup response loss cannot invalidate a hit or confirmed miss", async () => {
  for (const secondRead of [null, hit]) {
    const store = new Store();
    store.reads = [null, secondRead];
    store.releaseError = true;
    const access = await acquireSharedWordPackAccess(store, request);
    assertEquals(access.hit, secondRead);
    await access.release();
    assertEquals(store.calls, ["read", "claim", "read", "release"]);
  }
});
