import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  APPLE_NATIVE_HANDOFF_V2,
  nativeHandoffCallback,
  nativeHandoffVersion,
} from "./native-handoff.ts";
import { upstreamProviderFromBase44State } from "./provider.ts";

Deno.test("Apple HTTPS handoff is explicitly negotiated and legacy return stays unchanged", () => {
  assertEquals(nativeHandoffVersion(undefined), undefined);
  assertEquals(
    nativeHandoffCallback(undefined),
    "https://spyclash.com/api/apps/69a0e57fa939f578082f8091/functions/mobileAuthCallback",
  );
  assertEquals(
    nativeHandoffVersion(APPLE_NATIVE_HANDOFF_V2),
    APPLE_NATIVE_HANDOFF_V2,
  );
  assertEquals(
    nativeHandoffCallback(APPLE_NATIVE_HANDOFF_V2),
    "https://spyclash.com/MobileAppleAuthCallback.html?auth_provider=apple",
  );
  for (
    const value of [
      null,
      true,
      2,
      "",
      "apple-native-v2 ",
      "APPLE-NATIVE-V2",
      [APPLE_NATIVE_HANDOFF_V2],
      {},
      "https://attacker.example/",
    ]
  ) {
    assertThrows(() => nativeHandoffVersion(value));
    assertThrows(() => nativeHandoffCallback(value));
  }
});

Deno.test("Apple v2 return cannot select Google, and working Google selection is unchanged", () => {
  const app = "69a0e57fa939f578082f8091";
  const origin = "https://spyclash.com";
  for (const version of [undefined, APPLE_NATIVE_HANDOFF_V2]) {
    assertEquals(
      upstreamProviderFromBase44State(
        JSON.stringify({
          app_id: app,
          from_url: nativeHandoffCallback(version),
        }),
        app,
        origin,
      ),
      "apple",
    );
  }
  assertEquals(
    upstreamProviderFromBase44State(
      JSON.stringify({
        app_id: app,
        from_url:
          "https://spyclash.com/MobileAuthCallback.html?auth_provider=google",
      }),
      app,
      origin,
    ),
    "google",
  );
});
