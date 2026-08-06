import test from "node:test";
import assert from "node:assert/strict";

import {
  checkForWebRelease,
  entryScriptPathFromDocument,
  reloadForWebRelease,
  webReleaseHasChanged,
} from "./webRelease.js";

function fakeDocument(source, baseURI = "https://spyclash.com/Game?id=room-1") {
  return {
    baseURI,
    querySelector: () => source
      ? { getAttribute: (name) => name === "src" ? source : null }
      : null,
  };
}

test("entryScriptPathFromDocument finds the hashed Vite entry", () => {
  assert.equal(
    entryScriptPathFromDocument(fakeDocument("/assets/index-old.js")),
    "/assets/index-old.js",
  );
  assert.equal(entryScriptPathFromDocument(fakeDocument(null)), null);
});

test("webReleaseHasChanged requires two different entry paths", () => {
  assert.equal(webReleaseHasChanged("/assets/index-a.js", "/assets/index-b.js"), true);
  assert.equal(webReleaseHasChanged("/assets/index-a.js", "/assets/index-a.js"), false);
  assert.equal(webReleaseHasChanged(null, "/assets/index-b.js"), false);
});

test("checkForWebRelease bypasses the index cache and detects a new bundle", async () => {
  const requests = [];
  class FakeDOMParser {
    parseFromString() {
      return fakeDocument("/assets/index-new.js", "https://spyclash.com/");
    }
  }

  const changed = await checkForWebRelease({
    documentLike: fakeDocument("/assets/index-old.js"),
    locationLike: {
      href: "https://spyclash.com/Game?id=room-1",
      origin: "https://spyclash.com",
    },
    fetchImpl: async (url, options) => {
      requests.push({ url, options });
      return { ok: true, text: async () => "<html></html>" };
    },
    DOMParserImpl: FakeDOMParser,
    now: () => 1234,
  });

  assert.equal(changed, true);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, "https://spyclash.com/?_sc_update=1234");
  assert.equal(requests[0].options.cache, "no-store");
  assert.equal(requests[0].options.credentials, "same-origin");
});

test("checkForWebRelease is disabled for the unhashed Vite development entry", async () => {
  let fetchCount = 0;
  const changed = await checkForWebRelease({
    documentLike: fakeDocument(null),
    locationLike: {
      href: "http://127.0.0.1:5173/Game?id=room-1",
      origin: "http://127.0.0.1:5173",
    },
    fetchImpl: async () => {
      fetchCount += 1;
      return { ok: true, text: async () => "" };
    },
  });

  assert.equal(changed, false);
  assert.equal(fetchCount, 0);
});

test("reloadForWebRelease preserves the room URL and adds a cache buster", () => {
  let replacement = null;
  reloadForWebRelease({
    locationLike: {
      href: "https://spyclash.com/Game?id=room-1#card",
      replace: (value) => { replacement = value; },
    },
    now: () => 5678,
  });

  assert.equal(
    replacement,
    "https://spyclash.com/Game?id=room-1&_sc_update=5678#card",
  );
});
