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

function base64URL(value: string, padded = false) {
  const bytes = new TextEncoder().encode(value);
  const encoded = btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-").replace(/\//g, "_");
  return padded ? encoded : encoded.replace(/=+$/, "");
}

Deno.test("current Base44 Base64URL state selects Google with and without padding", () => {
  const value = state(
    "https://spyclash.com/MobileAuthCallback.html?auth_provider=google",
  );
  for (const padded of [false, true]) {
    assertEquals(
      upstreamProviderFromBase44State(base64URL(value, padded), APP_ID, ORIGIN),
      "google",
    );
  }
});

Deno.test("Base64URL state preserves Apple selection when Google was not requested", () => {
  for (
    const url of [
      "https://spyclash.com/home",
      "https://spyclash.com/home?auth_provider=apple",
    ]
  ) {
    assertEquals(
      upstreamProviderFromBase44State(base64URL(state(url)), APP_ID, ORIGIN),
      "apple",
    );
  }
});

Deno.test("encoded state retains exact app, HTTPS origin and single marker restrictions", () => {
  const cases = [
    state("https://spyclash.com/home?auth_provider=google", "another-app"),
    state("http://spyclash.com/home?auth_provider=google"),
    state("https://other.example/home?auth_provider=google"),
    state("https://spyclash.com:8443/home?auth_provider=google"),
    state("https://user@spyclash.com/home?auth_provider=google"),
    state(
      "https://spyclash.com/home?auth_provider=google&auth_provider=google",
    ),
    state("https://spyclash.com/home?auth_provider=google&auth_provider=apple"),
    state("https://spyclash.com/home?auth_provider=google#fragment"),
    state("https://spyclash.com/home?auth_provider=Google"),
  ];
  for (const value of cases) {
    assertEquals(
      upstreamProviderFromBase44State(base64URL(value), APP_ID, ORIGIN),
      "apple",
    );
  }
});

Deno.test("invalid Base64URL padding, whitespace, junk and noncanonical trailing bits default to Apple", () => {
  const value = base64URL(
    state("https://spyclash.com/MobileAuthCallback.html?auth_provider=google"),
  );
  assertEquals(value.length % 4, 3);
  const alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  const noncanonical = value.slice(0, -1) +
    alphabet[alphabet.indexOf(value.at(-1)!) + 1];
  for (
    const encoded of [
      value + "==",
      value + "===",
      "=" + value,
      value + "!",
      value + ".extra",
      value + "\n",
      " " + value,
      noncanonical,
    ]
  ) {
    assertEquals(
      upstreamProviderFromBase44State(encoded, APP_ID, ORIGIN),
      "apple",
    );
  }
});

Deno.test("invalid UTF-8 in an otherwise valid state cannot select Google", () => {
  const value = state("https://spyclash.com/home?auth_provider=google").slice(
    0,
    -1,
  );
  const invalidUTF8 = btoa(
    value + ',"extra":"' + String.fromCharCode(255) + '"}',
  )
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  assertEquals(
    upstreamProviderFromBase44State(invalidUTF8, APP_ID, ORIGIN),
    "apple",
  );
});

Deno.test("encoded nonobjects, malformed JSON and oversized state remain rejected", () => {
  for (
    const value of [
      "null",
      "[]",
      '"string"',
      "{",
      JSON.stringify({ app_id: APP_ID }),
    ]
  ) {
    assertEquals(
      upstreamProviderFromBase44State(base64URL(value), APP_ID, ORIGIN),
      "apple",
    );
  }
  assertEquals(
    upstreamProviderFromBase44State("A".repeat(4097), APP_ID, ORIGIN),
    "apple",
  );
  assertEquals(
    upstreamProviderFromBase44State(
      base64URL(
        state(
          "https://spyclash.com/" + "x".repeat(2048) + "?auth_provider=google",
        ),
      ),
      APP_ID,
      ORIGIN,
    ),
    "apple",
  );
});

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
