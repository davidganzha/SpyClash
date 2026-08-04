import assert from "node:assert/strict";
import test from "node:test";

import {
  isProductionAppOrigin,
  resolveAppBaseUrl,
  resolveAppId,
  resolveFunctionsVersion,
  SPYCLASH_BASE44_APP_ID,
} from "./appParamsPolicy.js";

test("recognizes public SpyClash and deployed Base44 origins", () => {
  assert.equal(isProductionAppOrigin({ protocol: "https:", hostname: "spyclash.com" }), true);
  assert.equal(isProductionAppOrigin({ protocol: "https:", hostname: "www.spyclash.com" }), true);
  assert.equal(isProductionAppOrigin({ protocol: "https:", hostname: "spy-game-zone.base44.app" }), true);
  assert.equal(isProductionAppOrigin({ protocol: "https:", hostname: "another-app.base44.app" }), false);
  assert.equal(isProductionAppOrigin({ protocol: "https:", hostname: "preview.base44.app" }), false);
  assert.equal(isProductionAppOrigin({ protocol: "http:", hostname: "localhost" }), false);
});

test("production build always uses the tracked SpyClash app identity", () => {
  assert.deepEqual(resolveAppId({
    urlValue: "another-app",
    environmentValue: null,
    storedValue: "stale-app",
    productionOrigin: true,
  }), {
    value: SPYCLASH_BASE44_APP_ID,
    persist: false,
    clearStored: true,
  });
});

test("official production origin has a deterministic app identity without local env", () => {
  assert.deepEqual(resolveAppId({
    urlValue: null,
    environmentValue: null,
    storedValue: null,
    productionOrigin: true,
  }), {
    value: SPYCLASH_BASE44_APP_ID,
    persist: false,
    clearStored: false,
  });
});

test("non-production origin fails closed without an explicit app identity", () => {
  assert.deepEqual(resolveAppId({
    urlValue: null,
    environmentValue: null,
    storedValue: null,
    productionOrigin: false,
  }), {
    value: null,
    persist: false,
    clearStored: false,
  });
});

test("development preview may explicitly target another app", () => {
  assert.deepEqual(resolveAppId({
    urlValue: "preview-app",
    environmentValue: null,
    storedValue: null,
    productionOrigin: false,
  }), {
    value: "preview-app",
    persist: false,
    clearStored: false,
  });
});

test("non-production origin never reuses a stored production app identity", () => {
  assert.deepEqual(resolveAppId({
    urlValue: null,
    environmentValue: null,
    storedValue: SPYCLASH_BASE44_APP_ID,
    productionOrigin: false,
  }), {
    value: null,
    persist: false,
    clearStored: true,
  });
});

test("production auth base URL is always same-origin", () => {
  assert.deepEqual(resolveAppBaseUrl({
    urlValue: "https://evil.example/path",
    environmentValue: "https://another.example",
    storedValue: "https://stale.example",
    productionOrigin: true,
  }), {
    value: null,
    persist: false,
    clearStored: true,
  });
});

test("development auth base URL requires an explicit safe HTTP origin", () => {
  assert.deepEqual(resolveAppBaseUrl({
    urlValue: "http://localhost:5173/path",
    environmentValue: null,
    storedValue: null,
    productionOrigin: false,
  }), {
    value: "http://localhost:5173",
    persist: false,
    clearStored: false,
  });

  assert.deepEqual(resolveAppBaseUrl({
    urlValue: "javascript:alert(1)",
    environmentValue: "https://user:password@example.com",
    storedValue: "https://stale.example",
    productionOrigin: false,
  }), {
    value: null,
    persist: false,
    clearStored: true,
  });
});

test("public origin drops a stale persisted functions version", () => {
  assert.deepEqual(resolveFunctionsVersion({
    urlValue: null,
    environmentValue: null,
    storedValue: "stale-preview",
    productionOrigin: true,
  }), {
    value: null,
    persist: false,
    clearStored: true,
  });
});

test("public origin ignores URL and environment function versions", () => {
  assert.deepEqual(resolveFunctionsVersion({
    urlValue: "preview-42",
    environmentValue: "preview-env",
    storedValue: "stale-preview",
    productionOrigin: true,
  }), {
    value: null,
    persist: false,
    clearStored: true,
  });
});

test("development origin may reuse its persisted preview version", () => {
  assert.deepEqual(resolveFunctionsVersion({
    urlValue: null,
    environmentValue: null,
    storedValue: "preview-42",
    productionOrigin: false,
  }), {
    value: "preview-42",
    persist: false,
    clearStored: false,
  });
});
