import {
  assert,
  assertEquals,
  assertRejects,
  assertStringIncludes,
} from "jsr:@std/assert@1";
import { errors, generateKeyPair, jwtVerify, SignJWT } from "npm:jose@5.10.0";
import {
  freshGoogleLoginURL,
  googleStateFailureResponse,
  googleStateJWTFailureReason,
} from "./google-state-recovery.ts";

const ISSUER = "https://spyclash.com/functions/appleAuthBroker";
const AUDIENCE = "spyclash:google-callback";
const ISSUED_AT = 1_788_679_200;
const STATE_TTL_SECONDS = 300;

async function testState() {
  const { publicKey, privateKey } = await generateKeyPair("ES256");
  const state = await new SignJWT({ token_use: "google_state" })
    .setProtectedHeader({ alg: "ES256" })
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setIssuedAt(ISSUED_AT)
    .setExpirationTime(ISSUED_AT + STATE_TTL_SECONDS)
    .sign(privateKey);
  const verify = (token: string, elapsedSeconds: number) =>
    jwtVerify(token, publicKey, {
      algorithms: ["ES256"],
      issuer: ISSUER,
      audience: AUDIENCE,
      clockTolerance: 5,
      currentDate: new Date((ISSUED_AT + elapsedSeconds) * 1000),
    });
  return { state, verify };
}

Deno.test("signed Google state expires at the existing TTL plus clock tolerance", async () => {
  const { state, verify } = await testState();
  await verify(state, STATE_TTL_SECONDS + 4);
  for (const elapsed of [STATE_TTL_SECONDS + 5, 6 * 60 * 60]) {
    const error = await assertRejects(
      () => verify(state, elapsed),
      errors.JWTExpired,
    );
    assertEquals(googleStateJWTFailureReason(error), "state_jwt_expired");
  }
});

Deno.test("an expired-looking state with a bad signature is invalid, not expired", async () => {
  const { state, verify } = await testState();
  const pieces = state.split(".");
  pieces[2] = (pieces[2][0] === "A" ? "B" : "A") + pieces[2].slice(1);
  const error = await assertRejects(
    () => verify(pieces.join("."), 6 * 60 * 60),
    errors.JWSSignatureVerificationFailed,
  );
  assertEquals(googleStateJWTFailureReason(error), "state_jwt_invalid");
  assertEquals(
    googleStateJWTFailureReason({ code: "ERR_JWT_EXPIRED", claim: "exp" }),
    "state_jwt_invalid",
  );
  assertEquals(
    googleStateJWTFailureReason(new Error("JWTExpired")),
    "state_jwt_invalid",
  );
});

function response(
  accept: string | undefined,
  action = "google-callback",
  method = "GET",
) {
  const headers = new Headers({ "Accept-Language": "ru-RU,ru;q=0.9" });
  if (accept !== undefined) headers.set("Accept", accept);
  return googleStateFailureResponse({
    request: new Request(
      "https://spyclash.com/functions/appleAuthBroker?action=google-callback",
      { headers, method },
    ),
    action,
    reason: "state_jwt_expired",
  });
}

Deno.test("browser callback and confirmation offer explicit app and website restart choices", async () => {
  for (const action of ["google-callback", "confirm-google-transaction"]) {
    const result = response("text/html,application/xhtml+xml;q=0.9", action);
    assertEquals(result.status, 400);
    assertStringIncludes(result.headers.get("Content-Type")!, "text/html");
    const body = await result.text();
    assertStringIncludes(body, "Сеанс входа истёк");
    assertStringIncludes(body, "Войти в приложение");
    assertStringIncludes(body, "Войти на сайт");
    const links = [...body.matchAll(/href="([^"]+)"/g)].map((match) =>
      match[1].replaceAll("&amp;", "&")
    );
    assertEquals(links, [
      freshGoogleLoginURL("app"),
      freshGoogleLoginURL("website"),
    ]);
    assertEquals(result.headers.get("Location"), null);
    assert(!body.includes("<script"));
    assert(!body.includes("http-equiv"));
  }
});

Deno.test("JSON API and unsupported requests retain the invalid_state JSON contract", async () => {
  for (
    const accept of [
      undefined,
      "application/json",
      "*/*",
      "text/html;q=0,application/json",
    ]
  ) {
    const result = response(accept);
    assertEquals(result.status, 400);
    assertStringIncludes(
      result.headers.get("Content-Type")!,
      "application/json",
    );
    assertEquals(await result.json(), {
      error: "invalid_state",
      error_description: "invalid state",
    });
  }
  for (
    const [action, method] of [["token", "GET"], ["google-callback", "POST"]]
  ) {
    assertStringIncludes(
      response("text/html", action, method).headers.get("Content-Type")!,
      "application/json",
    );
  }
});

Deno.test("untrusted callback parameters and Referer cannot alter restart destinations or HTML", async () => {
  const marker = 'UNTRUSTED<script>alert(1)</script>"';
  const url = new URL("https://spyclash.com/functions/appleAuthBroker");
  for (
    const name of [
      "state",
      "code",
      "redirect_uri",
      "from_url",
      "error_description",
    ]
  ) {
    url.searchParams.set(name, "https://evil.example/" + marker);
  }
  const result = googleStateFailureResponse({
    request: new Request(url, {
      headers: {
        Accept: "text/html",
        Referer: "https://evil.example/",
        "Accept-Language": "__proto__",
      },
    }),
    action: "google-callback",
    reason: "state_jwt_invalid",
  });
  const body = await result.text();
  assertStringIncludes(body, "This sign-in could not be verified");
  assert(!body.includes("has expired"));
  assert(!body.includes("UNTRUSTED"));
  assert(!body.includes("evil.example"));
  for (const target of ["app", "website"] as const) {
    const login = new URL(freshGoogleLoginURL(target));
    assertEquals(login.origin, "https://spyclash.com");
    assertEquals(
      login.pathname,
      "/api/apps/69a0e57fa939f578082f8091/auth/sso/login",
    );
    assertEquals([...login.searchParams.keys()].sort(), ["app_id", "from_url"]);
    const from = new URL(login.searchParams.get("from_url")!);
    assertEquals(from.origin, "https://spyclash.com");
    assertEquals(from.search, "?auth_provider=google");
    assertEquals(
      from.pathname,
      target === "app"
        ? "/api/apps/69a0e57fa939f578082f8091/functions/mobileAuthCallback"
        : "/",
    );
  }
});

Deno.test("Google recovery clears only the two transaction cookies and is never cached or framed", () => {
  const result = response("text/html");
  const cookies = result.headers.getSetCookie();
  assertEquals(cookies.length, 2);
  assert(
    cookies.every((cookie) =>
      cookie.includes("Max-Age=0") && cookie.includes("Secure") &&
      cookie.includes("SameSite=None")
    ),
  );
  assert(cookies[0].startsWith("__Host-SpyClashOAuthTransaction="));
  assertStringIncludes(cookies[0], "Path=/; HttpOnly");
  assert(cookies[1].startsWith("__Secure-SpyClashOAuthTransactionFallback="));
  assertStringIncludes(cookies[1], "Path=/functions/");
  assertEquals(result.headers.get("Cache-Control"), "no-store");
  assertEquals(result.headers.get("Referrer-Policy"), "no-referrer");
  assertStringIncludes(
    result.headers.get("Content-Security-Policy")!,
    "default-src 'none'",
  );
  assertStringIncludes(
    result.headers.get("Content-Security-Policy")!,
    "frame-ancestors 'none'",
  );
});
