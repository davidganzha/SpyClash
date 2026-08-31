import {
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  canonicalRoomActionRequest,
  hasTrustedRoomActionContext,
  resolveRoomActionUser,
  SPYCLASH_BASE44_API_URL,
  SPYCLASH_BASE44_APP_ID,
} from "./request-auth.ts";

Deno.test("room actions preserve body-token identity verification", async () => {
  const calls: unknown[] = [];
  const user = { id: "user-token", email: "token@spyclash.test" };

  const result = await resolveRoomActionUser({
    accessToken: "token-123",
    requestClient: {
      auth: { me: async () => ({ id: "wrong", email: "wrong@test" }) },
    },
    createIdentityClient: (config) => {
      calls.push(config);
      return { auth: { me: async () => user } };
    },
  });

  assertEquals(result, user);
  assertEquals(calls, [{
    appId: SPYCLASH_BASE44_APP_ID,
    serverUrl: SPYCLASH_BASE44_API_URL,
    token: "token-123",
  }]);
});

Deno.test("room actions accept an authenticated SDK request when storage token is absent", async () => {
  const user = { id: "user-cookie", email: "cookie@spyclash.test" };
  let identityClientCreated = false;

  const result = await resolveRoomActionUser({
    accessToken: "",
    requestClient: { auth: { me: async () => user } },
    createIdentityClient: () => {
      identityClientCreated = true;
      return { auth: { me: async () => null } };
    },
  });

  assertEquals(result, user);
  assertEquals(identityClientCreated, false);
});

Deno.test("unauthenticated SDK requests remain rejected", async () => {
  await assertRejects(
    () =>
      resolveRoomActionUser({
        accessToken: "",
        requestClient: {
          auth: {
            me: async () => {
              throw Object.assign(new Error("Unauthorized"), { status: 401 });
            },
          },
        },
        createIdentityClient: () => ({ auth: { me: async () => null } }),
      }),
    Error,
    "Unauthorized",
  );
});

Deno.test("room action service context must belong to SpyClash", () => {
  const trusted = new Request("https://functions.test/gameRoomAction", {
    method: "POST",
    headers: {
      "Base44-App-Id": SPYCLASH_BASE44_APP_ID,
      "Base44-Service-Authorization": "Bearer service-token",
    },
  });
  const foreign = new Request("https://functions.test/gameRoomAction", {
    method: "POST",
    headers: {
      "Base44-App-Id": "foreign-app",
      "Base44-Service-Authorization": "Bearer service-token",
    },
  });

  assertEquals(hasTrustedRoomActionContext(trusted), true);
  assertEquals(hasTrustedRoomActionContext(foreign), false);
});

Deno.test("room action SDK request ignores caller-supplied Base44 routing", () => {
  const request = new Request("https://functions.test/gameRoomAction", {
    method: "POST",
    headers: {
      "Base44-App-Id": SPYCLASH_BASE44_APP_ID,
      "Base44-Api-Url": "https://attacker.invalid",
      "Base44-Service-Authorization": "Bearer service-token",
    },
  });

  const canonical = canonicalRoomActionRequest(request);
  assertEquals(canonical.headers.get("Base44-App-Id"), SPYCLASH_BASE44_APP_ID);
  assertEquals(
    canonical.headers.get("Base44-Api-Url"),
    SPYCLASH_BASE44_API_URL,
  );
  assertEquals(
    canonical.headers.get("Base44-Service-Authorization"),
    "Bearer service-token",
  );
});
