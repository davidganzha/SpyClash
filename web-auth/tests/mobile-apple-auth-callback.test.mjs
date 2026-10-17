import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import { isMobileAppleAuthCallbackRoute, parseMobileAppleAuthCallbackURL } from "../src/lib/mobileAppleAuthCallback.js";

const moduleSource = readFileSync(new URL("../src/lib/mobileAppleAuthCallback.js", import.meta.url), "utf8");
const script = moduleSource.replace(/^export (?=function )/gm, "");
const base = "https://spyclash.com/MobileAppleAuthCallback.html";
const callback = query => `${base}?auth_provider=apple&${query}`;

function mount(source, { historyThrows = false, navigationThrows = false, language = "en-GB" } = {}) {
  let address = new URL(source), href = source;
  const events = [], attempts = [], elements = {};
  const forbidden = () => { throw new Error("Forbidden browser capability"); };
  function createElement(tagName) {
    events.push("UI");
    let id = "";
    const element = { tagName, style: {}, children: [], textContent: "", hidden: false };
    Object.defineProperty(element, "id", { get: () => id, set: value => { id = value; elements[id] = element; } });
    Object.defineProperty(element, "innerHTML", { get: forbidden, set: forbidden });
    element.append = (...children) => { element.children.push(...children); };
    element.replaceChildren = (...children) => { element.children = children; };
    return element;
  }
  const root = createElement("div"); root.id = "root";
  const document = { documentElement: {}, body: createElement("body"), createElement, getElementById: id => elements[id] };
  events.length = 0;
  const window = {
    navigator: { language },
    location: {
      get href() { return href; }, get origin() { return address.origin; }, get pathname() { return address.pathname; },
      replace(value) { events.push("navigate"); attempts.push(value); if (navigationThrows) throw new Error("Gesture required"); },
    },
    history: { replaceState(_state, _title, value) {
      events.push("clear"); if (historyThrows) throw new Error("Cleanup unavailable");
      address = new URL(value); href = value;
    } },
  };
  for (const name of ["localStorage", "sessionStorage", "indexedDB", "caches"]) Object.defineProperty(window, name, { get: forbidden });
  const context = vm.createContext({ URL, TextEncoder, Map, window, document, fetch: forbidden, XMLHttpRequest: forbidden, console: { log: forbidden, error: forbidden } });
  vm.runInContext(script, context);
  const remount = () => vm.runInContext("mountMobileAppleAuthCallback(document, window)", context);
  remount();
  return { get address() { return address; }, document, elements, events, attempts, remount };
}

test("Apple helper is isolated from SDK, storage, network and HTML interpolation", () => {
  assert.equal((moduleSource.match(/^export function /gm) || []).length, 3);
  assert.doesNotMatch(moduleSource, /\b(?:import|fetch|XMLHttpRequest|WebSocket|localStorage|sessionStorage|indexedDB|console|innerHTML|outerHTML)\b/);
});

test("Apple route is exact and does not claim Google's callback", () => {
  for (const [pathname, expected] of [["/MobileAppleAuthCallback.html", true], ["/MobileAuthCallback.html", false], ["/mobileappleauthcallback.html", false], ["/%4DobileAppleAuthCallback.html", false], ["/MobileAppleAuthCallback.html/", false], ["/home", false]]) {
    assert.equal(isMobileAppleAuthCallbackRoute({ pathname }), expected);
  }
});

test("fresh query token returns only to fixed Apple native destination after URL clearing", () => {
  const token = "fixture+token/&error=access_denied<fixture>";
  const result = mount(callback(`access_token=${encodeURIComponent(token)}&redirect_uri=https%3A%2F%2Fevil.example`));
  assert.equal(result.events[0], "clear");
  assert.equal(result.address.href, base);
  assert.deepEqual(result.attempts, [`spyclash://auth?auth_provider=apple&access_token=${encodeURIComponent(token)}`]);
  assert.deepEqual([...new URL(result.attempts[0]).searchParams], [["auth_provider", "apple"], ["access_token", token]]);
  assert.equal(result.elements["open-app"].href, result.attempts[0]);
  assert.equal(result.elements["open-app"].hidden, false);
  assert.ok(Object.values(result.elements).every(element => !element.textContent.includes(token)));
});

test("literal plus matches native URLComponents semantics", () => {
  assert.equal(parseMobileAppleAuthCallbackURL(callback("access_token=fixture+token")), "spyclash://auth?auth_provider=apple&access_token=fixture%2Btoken");
});

test("only inert fragments can accompany a valid query", () => {
  for (const suffix of ["", "#", "#_", "#_=_"]) {
    assert.equal(parseMobileAppleAuthCallbackURL(callback("access_token=fixture") + suffix), "spyclash://auth?auth_provider=apple&access_token=fixture");
  }
  for (const suffix of ["#access_token=fixture", "#auth_provider=apple", "#error=access_denied", "#_=_&access_token=fixture", "#%5F=%5F", "##", "#_ ", "#_\n", "#_\u200B"]) {
    assert.equal(parseMobileAppleAuthCallbackURL(callback("access_token=fixture") + suffix), null);
  }
});

for (const [name, source] of [
  ["HTTP", callback("access_token=fixture").replace("https:", "http:")],
  ["foreign host", callback("access_token=fixture").replace("spyclash.com", "evil.example")],
  ["subdomain", callback("access_token=fixture").replace("spyclash.com", "sub.spyclash.com")],
  ["credentials", callback("access_token=fixture").replace("https://", "https://user:pass@")],
  ["explicit default port", callback("access_token=fixture").replace("spyclash.com", "spyclash.com:443")],
  ["other port", callback("access_token=fixture").replace("spyclash.com", "spyclash.com:8443")],
  ["wrong path", callback("access_token=fixture").replace("MobileAppleAuthCallback", "MobileAuthCallback")],
  ["encoded path", callback("access_token=fixture").replace("MobileApple", "%4DobileApple")],
  ["duplicate provider", callback("access_token=fixture&auth_provider=apple")],
  ["encoded duplicate token", callback("access_token=one&access%5Ftoken=two")],
  ["duplicate unknown field", callback("access_token=fixture&x=one&x=two")],
  ["wrong provider", `${base}?auth_provider=google&access_token=fixture`],
  ["missing provider", `${base}?access_token=fixture`],
  ["missing payload", `${base}?auth_provider=apple`],
  ["mixed token error", callback("access_token=fixture&error=access_denied")],
  ["token with description", callback("access_token=fixture&error_description=private")],
  ["empty token", callback("access_token=")],
  ["trimmed token", callback("access_token=%20fixture%20")],
  ["empty unrelated name", callback("access_token=fixture&=value")],
  ["valueless unrelated field", callback("access_token=fixture&extra")],
  ["empty unrelated value", callback("access_token=fixture&extra=")],
  ["trimmed unrelated name", callback("access_token=fixture&%20extra=value")],
  ["control unrelated value", callback("access_token=fixture&extra=x%00y")],
  ["format token", callback("access_token=fi%E2%80%8Dxture")],
  ["control error description", callback("error=access_denied&error_description=x%0Ay")],
  ["invalid percent encoding", callback("access_token=fixture%ZZ")],
  ["malformed UTF8", callback("access_token=%C3%28")],
]) {
  test(`rejects ${name} without returning or displaying callback data`, () => {
    assert.equal(parseMobileAppleAuthCallbackURL(source), null);
    const result = mount(source);
    assert.equal(result.address.search, ""); assert.equal(result.address.hash, "");
    assert.deepEqual(result.attempts, []);
    assert.equal(result.elements["open-app"].hidden, true);
    assert.equal(result.elements["open-app"].href, undefined);
    assert.match(result.elements.diagnostic.textContent, /^Support code: SCA-WEB1-\d{2}$/);
    assert.ok(Object.values(result.elements).every(element => !element.textContent.includes("private")));
  });
}

test("query name and value bounds use UTF8 bytes like native policy", () => {
  for (const [token, accepted] of [["a".repeat(20000), true], ["a".repeat(20001), false], ["é".repeat(10000), true], ["é".repeat(10001), false]]) {
    assert.equal(parseMobileAppleAuthCallbackURL(callback(`access_token=${encodeURIComponent(token)}`)) !== null, accepted);
  }
  for (const [name, accepted] of [["n".repeat(128), true], ["n".repeat(129), false], ["é".repeat(64), true], ["é".repeat(65), false]]) {
    assert.equal(parseMobileAppleAuthCallbackURL(callback(`access_token=fixture&${encodeURIComponent(name)}=value`)) !== null, accepted);
  }
});

test("provider errors forward only a bounded safe code and explicit Apple marker", () => {
  for (const [error, expected] of [["access_denied", "access_denied"], ["user_cancelled", "access_denied"], ["state_expired", "session_expired"], ["server_error", "temporarily_unavailable"], ["invalid_state", "invalid_state"], ["private-message", "authentication_failed"], ["__proto__", "authentication_failed"]]) {
    const result = mount(callback(`error=${error}&error_description=private-detail&return_url=https%3A%2F%2Fevil.example`));
    assert.deepEqual(result.attempts, [`spyclash://auth?auth_provider=apple&error=${expected}`]);
    assert.ok(Object.values(result.elements).every(element => !element.textContent.includes("private")));
  }
});

test("cleanup failure stops handoff; repeat mount and reload cannot replay a credential", () => {
  const failed = mount(callback("access_token=fixture"), { historyThrows: true });
  assert.deepEqual(failed.attempts, []); assert.equal(failed.events[0], "clear");
  assert.equal(failed.elements["open-app"].href, undefined);
  assert.equal(failed.elements.diagnostic.textContent, "Support code: SCA-WEB1-07");
  const first = mount(callback("access_token=fixture"));
  first.remount(); assert.equal(first.attempts.length, 1); assert.equal(first.elements["open-app"].href, undefined);
  assert.deepEqual(mount(first.address.href).attempts, []);
});

test("Russian copy and gesture link work without reflecting credentials", () => {
  const result = mount(callback("access_token=fixture"), { language: "ru-RU", navigationThrows: true });
  assert.equal(result.document.documentElement.lang, "ru");
  assert.equal(result.elements["open-app"].textContent, "Открыть SpyClash");
  assert.equal(result.elements["open-app"].hidden, false);
  assert.equal(result.elements["open-app"].href, result.attempts[0]);
});

test("shared entrypoint routes Apple and Google separately before normal bootstrap", () => {
  const main = readFileSync(new URL("../src/main.jsx", import.meta.url), "utf8")
    .replace(/^import .*;\n/gm, "").replace("import('./bootstrap.jsx')", "bootstrap()");
  for (const [pathname, expected] of [["/MobileAppleAuthCallback.html", "apple"], ["/MobileAuthCallback.html", "google"], ["/home", "website"]]) {
    const calls = [];
    vm.runInNewContext(main, { window: { location: { pathname } }, document: {}, isMobileAppleAuthCallbackRoute,
      isMobileAuthCallbackRoute: location => location.pathname === "/MobileAuthCallback.html",
      mountMobileAppleAuthCallback: () => calls.push("apple"), mountMobileAuthCallback: () => calls.push("google"), bootstrap: () => calls.push("website") });
    assert.deepEqual(calls, [expected]);
  }
});

test("inline index bootstrap touches no storage, cache, URL or service workers on either callback", () => {
  const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");
  const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(match => match[1]);
  assert.equal(scripts.length, 2);
  for (const pathname of ["/MobileAppleAuthCallback.html", "/MobileAuthCallback.html"]) {
    const forbidden = () => { throw new Error("Callback triggered normal web bootstrap"); };
    const window = { location: { pathname }, history: { replaceState: forbidden } };
    Object.defineProperty(window, "caches", { get: forbidden });
    const navigator = {}; Object.defineProperty(navigator, "serviceWorker", { get: forbidden });
    const context = { window, navigator, URL, localStorage: { removeItem: forbidden }, caches: { keys: forbidden } };
    for (const source of scripts) vm.runInNewContext(source, context);
  }
});
