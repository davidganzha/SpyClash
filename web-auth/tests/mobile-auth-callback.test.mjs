import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const moduleSource = readFileSync(new URL("../src/lib/mobileAuthCallback.js", import.meta.url), "utf8");
// Keep browser capabilities inside a VM. Only the module's three named export
// keywords are removed; the implementation itself is executed unchanged.
const script = moduleSource.replace(/^export (?=function )/gm, "");
const base = "https://spyclash.com/MobileAuthCallback.html";
const callback = (query) => `${base}?auth_provider=google&${query}`;
function run(source, {
  navigationThrows = false, historyThrows = false, language = "en-GB",
  navigationType = "navigate", performanceThrows = false, performanceMissing = false
} = {}) {
  let address = new URL(source);
  let currentHref = source;
  const events = [];
  const attempts = [];
  const forbiddenCalls = [];
  const forbidden = (name) => () => {
    forbiddenCalls.push(name);
    throw new Error(`Forbidden capability: ${name}`);
  };
  const elements = {};
  function makeElement(tagName) {
    events.push({ type: "create", tagName });
    let id = "";
    let text = "";
    const element = { tagName, hidden: false, href: undefined, style: {}, children: [] };
    Object.defineProperty(element, "id", {
      get: () => id,
      set: (value) => { id = value; elements[id] = element; },
    });
    Object.defineProperty(element, "textContent", {
      get: () => text,
      set: (value) => { text = value; events.push({ type: "text", id }); },
    });
    Object.defineProperty(element, "innerHTML", { get: forbidden("innerHTML"), set: forbidden("innerHTML") });
    element.append = (...children) => { element.children.push(...children); };
    element.replaceChildren = (...children) => { element.children = children; };
    element.click = () => {
      assert.equal(element.hidden, false, "Only a visible fallback can be clicked");
      assert.ok(element.href, "Fallback must have a real link destination");
      attempts.push({ type: "link", url: element.href });
    };
    return element;
  }
  const root = makeElement("div");
  root.id = "root";
  const body = makeElement("body");
  body.append(root);
  events.length = 0;
  const location = {
    get href() { return currentHref; },
    get origin() { return address.origin; },
    get pathname() { return address.pathname; },
    replace(url) {
      events.push({ type: "navigate" });
      attempts.push({ type: "replace", url });
      if (navigationThrows) throw new Error("Browser requires a user gesture");
    },
  };
  const history = {
    replaceState(state, title, url) {
      events.push({ type: "clear", url });
      if (historyThrows) throw new Error("History unavailable");
      address = new URL(url, address);
      currentHref = address.href;
      assert.equal(address.search, "", "History must not retain query credentials");
      assert.equal(address.hash, "", "History must not retain a fragment");
      assert.equal(state, null, "History state must not retain credentials");
    },
  };
  const document = {
    documentElement: { lang: "en" },
    body,
    getElementById(id) { return elements[id] || null; },
    createElement(tagName) {
      assert.ok(["main", "h1", "p", "a"].includes(tagName), "No executable or network-loading DOM elements");
      return makeElement(tagName);
    },
    write: forbidden("document.write"),
  };
  Object.defineProperty(document, "cookie", { get: forbidden("cookie"), set: forbidden("cookie") });
  const window = { location, history, navigator: { language }, document };
  if (!performanceMissing) {
    window.performance = {
      getEntriesByType(type) {
        assert.equal(type, "navigation");
        if (performanceThrows) throw new Error("private-navigation-diagnostic");
        return [{ type: navigationType }];
      }
    };
  }
  const context = { window, document, URL, URLSearchParams };
  for (const target of [context, window]) {
    for (const name of ["fetch", "XMLHttpRequest", "WebSocket", "EventSource", "Image", "Worker", "importScripts"]) {
      target[name] = forbidden(name);
    }
    for (const name of ["localStorage", "sessionStorage", "indexedDB", "caches"]) {
      Object.defineProperty(target, name, { get: forbidden(name) });
    }
    target.console = new Proxy({}, { get: forbidden("console") });
  }
  window.navigator.sendBeacon = forbidden("sendBeacon");
  vm.createContext(context, { codeGeneration: { strings: false, wasm: false } });
  vm.runInContext(script, context, { timeout: 1000 });
  const remount = () => {
    vm.runInContext("mountMobileAuthCallback(document, window);", context, { timeout: 1000 });
    assert.deepEqual(forbiddenCalls, [], "Forbidden capability use fails even if the implementation catches it");
  };
  remount();
  assert.equal(events[0]?.type, "clear", "Address must be cleaned before UI work or navigation");
  return { get address() { return address; }, events, attempts, elements, document, remount };
}

function assertRejected(source) {
  const result = run(source);
  assert.equal(result.address.search, "");
  assert.equal(result.address.hash, "");
  assert.deepEqual(result.attempts, []);
  assert.equal(result.elements["open-app"].hidden, true);
  assert.equal(result.elements["open-app"].href, undefined);
  assert.match(result.elements.diagnostic.textContent, /^Support code: SCG174-\d{2} · navigate · m1$/);
  return result;
}

test("isolated helper has only named exports and no imports, storage, logging, or network calls", () => {
  assert.equal((moduleSource.match(/^export function /gm) || []).length, 3);
  assert.doesNotMatch(script, /\b(?:import|fetch|XMLHttpRequest|WebSocket|localStorage|sessionStorage|indexedDB|console)\b/);
  assert.doesNotMatch(script, /\binnerHTML\b|\bouterHTML\b|\burl\(/);
});

test("early route detection recognizes only the exact callback pathname", () => {
  for (const [pathname, expected] of [
    ["/MobileAuthCallback.html", true],
    ["/MobileAuthCallback.html/", false],
    ["/mobileauthcallback.html", false],
    ["/%4DobileAuthCallback.html", false],
    ["/home", false],
    ["/PrivacyPolicy", false],
  ]) {
    assert.equal(vm.runInNewContext(script + "\nisMobileAuthCallbackRoute(location);", { location: { pathname } }), expected);
  }
});

test("pure parser rejects an invalid absolute URL", () => {
  for (const source of ["not a URL", null, undefined, {}]) {
    assert.equal(vm.runInNewContext(script + "\nparseMobileAuthCallbackURL(source);", { source, URL }), null);
  }
});

test("fresh token returns through only the fixed native destination after clearing the URL", () => {
  const token = "header.payload.signature";
  const result = run(callback(`access_token=${token}&redirect_uri=https%3A%2F%2Fevil.example&unrelated=private`));
  assert.deepEqual(result.attempts, [{ type: "replace", url: `spyclash://auth?access_token=${token}` }]);
  assert.equal(result.address.href, base);
  assert.equal(result.elements["open-app"].href, result.attempts[0].url);
  assert.equal(result.elements["open-app"].hidden, false);
  assert.equal(result.elements.diagnostic.hidden, true);
  assert.equal(result.elements.diagnostic.textContent, "");
  assert.ok(result.events.findIndex((event) => event.type === "navigate") > 0);
  assert.ok(Object.values(result.elements).every((element) => !element.textContent.includes(token)));
});

test("token encoding cannot introduce query fields or markup", () => {
  const token = "opaque+value/&error=access_denied<test>";
  const result = run(callback(`access_token=${encodeURIComponent(token)}`));
  assert.equal(result.attempts[0].url, `spyclash://auth?access_token=${encodeURIComponent(token)}`);
  const target = new URL(result.attempts[0].url);
  assert.deepEqual([...target.searchParams], [["access_token", token]]);
});

test("20,000 ASCII characters remain valid; the next character is rejected", () => {
  assert.equal(run(callback(`access_token=${"a".repeat(20000)}`)).attempts.length, 1);
  assertRejected(callback(`access_token=${"a".repeat(20001)}`));
});

test("gesture fallback remains usable when automatic navigation throws or is ignored", () => {
  for (const navigationThrows of [false, true]) {
    const result = run(callback("access_token=token"), { navigationThrows });
    result.elements["open-app"].click();
    assert.deepEqual(result.attempts, [
      { type: "replace", url: "spyclash://auth?access_token=token" },
      { type: "link", url: "spyclash://auth?access_token=token" },
    ]);
  }
});

test("no navigation occurs when query clearing fails", () => {
  const result = run(callback("access_token=token"), { historyThrows: true });
  assert.deepEqual(result.attempts, []);
  assert.equal(result.events[0].type, "clear");
  assert.equal(result.elements["open-app"].hidden, true);
  assert.equal(result.elements.diagnostic.textContent, "Support code: SCG174-11 · navigate · m1");
});

test("a refresh cannot replay a token from storage or the cleaned address", () => {
  const first = run(callback("access_token=token"));
  const reloaded = run(first.address.href, { navigationType: "reload" });
  assert.deepEqual(reloaded.attempts, []);
  assert.equal(reloaded.elements["open-app"].hidden, true);
  assert.equal(reloaded.elements.diagnostic.textContent, "Support code: SCG174-04 · reload · m1");
});

test("a second mount reads the cleaned location and cannot recover the prior DOM token", () => {
  const result = run(callback("access_token=private-first-mount"));
  result.remount();
  assert.equal(result.address.href, base);
  assert.equal(result.attempts.length, 1);
  assert.equal(result.elements.title.textContent, "Sign-in could not be completed");
  assert.equal(result.elements["open-app"].hidden, true);
  assert.equal(result.elements["open-app"].href, undefined);
  assert.equal(result.elements.diagnostic.textContent, "Support code: SCG174-04 · navigate · m2+");
  result.remount();
  assert.equal(result.elements.diagnostic.textContent, "Support code: SCG174-04 · navigate · m2+");
  assert.equal(result.attempts.length, 1);
  assert.ok(Object.values(result.elements).every((element) => !element.textContent.includes("private-first-mount")));
});

test("Russian copy is available without exposing credentials", () => {
  const result = run(callback("access_token=token"), { language: "ru-RU" });
  assert.equal(result.document.documentElement.lang, "ru");
  assert.equal(result.elements["open-app"].textContent, "Открыть SpyClash");
  const failure = run(base, { language: "ru-RU", navigationType: "back_forward" });
  assert.equal(failure.elements.diagnostic.textContent, "Код для поддержки: SCG174-04 · back_forward · m1");
});

for (const [reason, source, code] of [
  ["invalid_url", "https://foreign.example/MobileAuthCallback.html?access_token=private", "01"],
  ["fragment", callback("access_token=private#private-fragment"), "02"],
  ["duplicate_parameter", callback("access_token=private&unrelated=one&unrelated=two"), "03"],
  ["empty_query", base, "04"],
  ["empty_query", base + "?", "04"],
  ["missing_provider", base + "?access_token=private", "05"],
  ["wrong_provider", base + "?auth_provider=private-provider&access_token=private", "06"],
  ["missing_payload", base + "?auth_provider=google&private-key=private-value", "07"],
  ["mixed_payload", callback("access_token=private&error_description=private-error"), "08"],
  ["invalid_token", callback("access_token=%20private%20"), "09"],
  ["invalid_error", callback("error=%20private-error%20"), "10"],
]) {
  test(`diagnostic ${code} identifies only fixed ${reason} without reflecting input`, () => {
    const parsed = vm.runInNewContext(script + "\nparseMobileAuthCallbackResult(source);", { source, URL });
    assert.equal(parsed.reason, reason);
    assert.equal(parsed.nativeURL, null);
    const result = assertRejected(source);
    assert.equal(result.elements.diagnostic.textContent, `Support code: SCG174-${code} · navigate · m1`);
    assert.ok(Object.values(result.elements).every((element) => !element.textContent.includes("private")));
    assert.ok(Object.values(result.elements).every((element) => !element.textContent.includes(source)));
  });
}

test("navigation diagnostic accepts only the fixed navigation kinds", () => {
  for (const navigationType of ["navigate", "reload", "back_forward", "private-type", null, 42, { type: "reload" }]) {
    const result = run(base, { navigationType });
    const expected = ["navigate", "reload", "back_forward"].includes(navigationType) ? navigationType : "unknown";
    assert.equal(result.elements.diagnostic.textContent, `Support code: SCG174-04 · ${expected} · m1`);
  }
  for (const options of [{ performanceMissing: true }, { performanceThrows: true }]) {
    const result = run(base, options);
    assert.equal(result.elements.diagnostic.textContent, "Support code: SCG174-04 · unknown · m1");
    assert.ok(Object.values(result.elements).every((element) => !element.textContent.includes("private-navigation-diagnostic")));
  }
});

test("history failure has a fixed priority and never reflects token or parser details", () => {
  const result = run(callback("access_token=private-token&error=private-error"), {
    historyThrows: true, navigationType: "reload", language: "ru-RU"
  });
  assert.equal(result.elements.diagnostic.textContent, "Код для поддержки: SCG174-11 · reload · m1");
  assert.deepEqual(result.attempts, []);
  assert.equal(result.elements["open-app"].href, undefined);
  assert.ok(Object.values(result.elements).every((element) => !element.textContent.includes("private")));
});

for (const [name, source] of [
  ["HTTP", "http://spyclash.com/MobileAuthCallback.html?auth_provider=google&access_token=token"],
  ["wrong origin", "https://evil.example/MobileAuthCallback.html?auth_provider=google&access_token=token"],
  ["subdomain", "https://sub.spyclash.com/MobileAuthCallback.html?auth_provider=google&access_token=token"],
  ["credentials", "https://user:password@spyclash.com/MobileAuthCallback.html?auth_provider=google&access_token=token"],
  ["explicit default port", "https://spyclash.com:443/MobileAuthCallback.html?auth_provider=google&access_token=token"],
  ["other port", "https://spyclash.com:8443/MobileAuthCallback.html?auth_provider=google&access_token=token"],
  ["wrong path", "https://spyclash.com/PrivacyPolicy?auth_provider=google&access_token=token"],
  ["wrong path case", "https://spyclash.com/mobileauthcallback.html?auth_provider=google&access_token=token"],
  ["encoded path", "https://spyclash.com/%4DobileAuthCallback.html?auth_provider=google&access_token=token"],
  ["trailing slash", "https://spyclash.com/MobileAuthCallback.html/?auth_provider=google&access_token=token"],
  ["fragment", callback("access_token=token#fragment")],
  ["empty fragment", callback("access_token=token#")],
  ["missing payload", `${base}?auth_provider=google`],
  ["missing provider", `${base}?access_token=token`],
  ["wrong provider", `${base}?auth_provider=apple&access_token=token`],
  ["duplicate token", callback("access_token=one&access_token=two")],
  ["encoded duplicate token", callback("access_token=one&access%5Ftoken=two")],
  ["duplicate provider", callback("access_token=token&auth_provider=google")],
  ["duplicate unrelated field", callback("access_token=token&x=1&x=2")],
  ["token and error", callback("access_token=token&error=access_denied")],
  ["token and empty error", callback("access_token=token&error=")],
  ["token and error description", callback("access_token=token&error_description=private")],
  ["empty token", callback("access_token=")],
  ["trimmed token", callback("access_token=%20token%20")],
  ["newline token", callback("access_token=to%0Aken")],
  ["C1 control token", callback("access_token=to%C2%85ken")],
  ["Unicode format token", callback("access_token=to%E2%80%8Dken")],
  ["empty error", callback("error=")],
  ["trimmed error", callback("error=%20access_denied")],
  ["control error", callback("error=access_denied%00")],
  ["oversized error", callback(`error=${"e".repeat(129)}`)],
]) {
  test(`rejects ${name}, cleans the address, and reveals no fallback credential`, () => {
    assertRejected(source);
  });
}

for (const [error, expected] of [
  ["access_denied", "access_denied"],
  ["USER_CANCELLED", "access_denied"],
  ["invalid_state", "invalid_state"],
  ["state_expired", "session_expired"],
  ["server_error", "temporarily_unavailable"],
  ["provider_private_diagnostic", "authentication_failed"],
  ["__proto__", "authentication_failed"],
]) {
  test(`provider error ${error} forwards only a safe canonical error`, () => {
    const result = run(callback(`error=${error}&error_description=private%20details&return_url=https%3A%2F%2Fevil.example`));
    assert.deepEqual(result.attempts, [{ type: "replace", url: `spyclash://auth?error=${expected}` }]);
    assert.ok(Object.values(result.elements).every((element) => !element.textContent.includes("private")));
  });
}
