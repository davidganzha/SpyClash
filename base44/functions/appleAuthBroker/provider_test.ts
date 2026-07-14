import { upstreamProviderFromBase44State } from "./provider.ts";

function assertEquals<T>(actual: T, expected: T) {
  if (actual !== expected) {
    throw new Error(`Expected ${String(expected)}, received ${String(actual)}`);
  }
}

const APP_ID = "69a0e57fa939f578082f8091";
const ORIGIN = "https://spyclash.com";

function state(fromURL: string, appId = APP_ID) {
  return JSON.stringify({ app_id: appId, from_url: fromURL });
}

Deno.test("validated Base44 from_url selects Google", () => {
  assertEquals(
    upstreamProviderFromBase44State(
      state(
        `https://spyclash.com/api/apps/${APP_ID}/functions/mobileAuthCallback?auth_provider=google`,
      ),
      APP_ID,
      ORIGIN,
    ),
    "google",
  );
});

Deno.test("provider query outside Base44 state cannot select Google", () => {
  assertEquals(
    upstreamProviderFromBase44State("opaque-state", APP_ID, ORIGIN),
    "apple",
  );
});

Deno.test("wrong app and cross-origin return URLs default to Apple", () => {
  assertEquals(
    upstreamProviderFromBase44State(
      state("https://spyclash.com/home?auth_provider=google", "other-app"),
      APP_ID,
      ORIGIN,
    ),
    "apple",
  );
  assertEquals(
    upstreamProviderFromBase44State(
      state("https://example.com/home?auth_provider=google"),
      APP_ID,
      ORIGIN,
    ),
    "apple",
  );
});

Deno.test("ambiguous, malformed, or fragment markers default to Apple", () => {
  assertEquals(
    upstreamProviderFromBase44State(
      state(
        "https://spyclash.com/home?auth_provider=google&auth_provider=google",
      ),
      APP_ID,
      ORIGIN,
    ),
    "apple",
  );
  assertEquals(
    upstreamProviderFromBase44State(
      state("https://spyclash.com/home#auth_provider=google"),
      APP_ID,
      ORIGIN,
    ),
    "apple",
  );
  assertEquals(
    upstreamProviderFromBase44State("not-json", APP_ID, ORIGIN),
    "apple",
  );
});
