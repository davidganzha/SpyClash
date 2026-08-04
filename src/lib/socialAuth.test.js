import assert from "node:assert/strict";
import test from "node:test";

import { buildSocialLoginUrl } from "./socialAuth.js";

const APP_ID = "69a0e57fa939f578082f8091";

test("Apple login uses the canonical Base44 SSO endpoint and clean return URL", () => {
  const loginUrl = new URL(buildSocialLoginUrl({
    provider: "apple",
    appId: APP_ID,
    origin: "https://spyclash.com",
  }));

  assert.equal(loginUrl.origin, "https://spyclash.com");
  assert.equal(loginUrl.pathname, `/api/apps/${APP_ID}/auth/sso/login`);
  assert.equal(loginUrl.searchParams.get("app_id"), APP_ID);
  assert.equal(loginUrl.searchParams.get("from_url"), "https://spyclash.com/home");
});

test("Google login selects Google only through the signed Base44 return state", () => {
  const loginUrl = new URL(buildSocialLoginUrl({
    provider: "google",
    appId: APP_ID,
    origin: "https://spyclash.com",
  }));
  const returnUrl = new URL(loginUrl.searchParams.get("from_url"));

  assert.equal(returnUrl.origin, "https://spyclash.com");
  assert.equal(returnUrl.pathname, "/home");
  assert.deepEqual(returnUrl.searchParams.getAll("auth_provider"), ["google"]);
});

test("social login rejects unknown providers and malformed app ids", () => {
  assert.throws(() => buildSocialLoginUrl({
    provider: "facebook",
    appId: APP_ID,
    origin: "https://spyclash.com",
  }), /Unsupported social auth provider/);

  assert.throws(() => buildSocialLoginUrl({
    provider: "apple",
    appId: "../other-app",
    origin: "https://spyclash.com",
  }), /Invalid Base44 app id/);
});
