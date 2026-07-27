import {
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { resolveRoomActionUser } from "./request-auth.ts";

Deno.test("room actions preserve body-token identity verification", async () => {
  const calls: unknown[] = [];
  const user = { id: "user-token", email: "token@spyclash.test" };

  const result = await resolveRoomActionUser({
    accessToken: "token-123",
    appId: "app-1",
    serverUrl: "https://base44.test",
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
    appId: "app-1",
    serverUrl: "https://base44.test",
    token: "token-123",
  }]);
});

Deno.test("room actions accept an authenticated SDK request when storage token is absent", async () => {
  const user = { id: "user-cookie", email: "cookie@spyclash.test" };
  let identityClientCreated = false;

  const result = await resolveRoomActionUser({
    accessToken: "",
    appId: "app-1",
    serverUrl: "https://base44.test",
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
  await assertRejects(() => resolveRoomActionUser({
    accessToken: "",
    appId: "app-1",
    serverUrl: "https://base44.test",
    requestClient: {
      auth: { me: async () => {
        throw Object.assign(new Error("Unauthorized"), { status: 401 });
      } },
    },
    createIdentityClient: () => ({ auth: { me: async () => null } }),
  }), Error, "Unauthorized");
});
