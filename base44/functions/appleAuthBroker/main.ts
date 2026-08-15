import {
  createRemoteJWKSet,
  importJWK,
  importPKCS8,
  type JWK,
  type JWTPayload,
  jwtVerify,
  SignJWT,
} from "npm:jose@5.10.0";
import { createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import {
  type AppleCredentialIdentityWriter,
  type AppleCredentialIssuanceBoundary,
  assertTrackedAppleSignInCredential,
  persistPendingAppleSignInCredential,
  withAppleCredentialIdentityWriter,
  withAppleCredentialIssuanceBoundary,
} from "./apple-sign-in-credential.ts";
import { publicAppleCredentialBrokerError } from "./apple-credential-error-policy.ts";
import { appleCodeExchangeTokenOutcome } from "./apple-code-exchange.ts";
import { compensateUntrackedAppleRefreshToken } from "./apple-token-compensation.ts";
import { upstreamProviderFromBase44State } from "./provider.ts";
import {
  type GoogleTransactionChannel,
  googleTransactionChannelFromClaim,
} from "./confirmation.ts";
import {
  fallbackGoogleTransactionHandoff,
  primaryGoogleTransactionHandoff,
} from "./handoff.ts";
import { requestForBase44ServiceRole } from "./service-role-request.ts";
import {
  clearUpstreamFallbackTransactionCookie,
  clearUpstreamTransactionCookie,
  cookieValue,
  createUpstreamTransaction,
  randomBase64Url,
  secureEqual,
  sha256Base64Url,
  UPSTREAM_FALLBACK_TRANSACTION_COOKIE,
  UPSTREAM_TRANSACTION_COOKIE,
  upstreamFallbackTransactionCookie,
  upstreamFallbackTransactionMatches,
  upstreamTransactionCookie,
  upstreamTransactionMatches,
} from "./transaction.ts";

const APP_ID = "69a0e57fa939f578082f8091";
const PUBLIC_ORIGIN = "https://spyclash.com";
const ISSUER = `${PUBLIC_ORIGIN}/functions/appleAuthBroker`;
const APPLE_CALLBACK_URL = "https://spyclash.com/functions/appleAuthCallback";
const GOOGLE_CALLBACK_URL = "https://spyclash.com/functions/googleAuthCallback";
const BASE44_REDIRECT_URI =
  `https://app.base44.com/api/apps/${APP_ID}/auth/sso/callback`;
const BASE44_SSO_LOGIN_URL =
  `https://spyclash.com/api/apps/${APP_ID}/auth/sso/login`;
const MOBILE_AUTH_CALLBACK_URL =
  `https://spyclash.com/api/apps/${APP_ID}/functions/mobileAuthCallback`;
const USERINFO_AUDIENCE = `${ISSUER}?action=userinfo`;
const APPLE_STATE_AUDIENCE = "spyclash:apple-callback";
const GOOGLE_STATE_AUDIENCE = "spyclash:google-callback";
const NATIVE_TICKET_AUDIENCE = "spyclash:native-bootstrap";
const EXPECTED_APPLE_NATIVE_CLIENT_ID = "com.spyclash.ios";
const NATIVE_COOKIE = "__Host-SpyClashNativeOIDC";
const APPLE_ISSUER = "https://appleid.apple.com";
const APPLE_TOKEN_ENDPOINT = "https://appleid.apple.com/auth/token";
const APPLE_AUTH_ENDPOINT = "https://appleid.apple.com/auth/authorize";
const APPLE_JWKS = createRemoteJWKSet(
  new URL("https://appleid.apple.com/auth/keys"),
);
const GOOGLE_ISSUERS = ["https://accounts.google.com", "accounts.google.com"];
const GOOGLE_TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token";
const GOOGLE_AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth";
const GOOGLE_JWKS = createRemoteJWKSet(
  new URL("https://www.googleapis.com/oauth2/v3/certs"),
);

const MAX_BODY_BYTES = 64 * 1024;
const AUTHORIZATION_CODE_TTL_SECONDS = 75;
const ACCESS_TOKEN_TTL_SECONDS = 300;
const ID_TOKEN_TTL_SECONDS = 300;
const APPLE_STATE_TTL_SECONDS = 300;
const GOOGLE_STATE_TTL_SECONDS = 300;
const NATIVE_TICKET_TTL_SECONDS = 90;

type Profile = {
  sub: string;
  email: string;
  emailVerified: boolean;
  name: string;
  isPrivateEmail: boolean;
  authTime: number;
};

type UpstreamAuthProvider = "apple" | "google";

type OidcRequest = {
  clientId: string;
  redirectUri: string;
  state: string;
  nonce?: string;
  scope: string;
  codeChallenge?: string;
  codeChallengeMethod?: "S256";
};

class BrokerError extends Error {
  constructor(
    readonly code: string,
    readonly status = 400,
    message = code,
  ) {
    super(message);
    this.name = "BrokerError";
  }
}

class AppleCodeExchangeError extends BrokerError {
  constructor(
    code: string,
    status: number,
    readonly tokenOutcome: "not_issued" | "unknown",
  ) {
    super(code, status);
    this.name = "AppleCodeExchangeError";
  }
}

let brokerKeysPromise: ReturnType<typeof loadBrokerKeys> | undefined;
let applePrivateKeyPromise: ReturnType<typeof loadApplePrivateKey> | undefined;

function requiredEnv(name: string, trim = true) {
  const raw = Deno.env.get(name);
  if (raw === undefined || raw.trim() === "") {
    throw new BrokerError("server_configuration_error", 500, `Missing ${name}`);
  }
  return trim ? raw.trim() : raw;
}

function decodeBase64Utf8(value: string, name: string) {
  try {
    const normalized = value
      .replace(/\s/g, "")
      .replace(/-/g, "+")
      .replace(/_/g, "/");
    const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
    const binary = atob(padded);
    const bytes = Uint8Array.from(
      binary,
      (character) => character.charCodeAt(0),
    );
    return new TextDecoder().decode(bytes);
  } catch {
    throw new BrokerError(
      "server_configuration_error",
      500,
      `${name} is not valid base64`,
    );
  }
}

async function sha256Hex(value: string) {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
  );
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}

function publicJwkOnly(raw: JWK): JWK {
  if (raw.kty === "RSA" && raw.n && raw.e) {
    return { kty: "RSA", n: raw.n, e: raw.e };
  }
  if (raw.kty === "EC" && raw.crv === "P-256" && raw.x && raw.y) {
    return { kty: "EC", crv: "P-256", x: raw.x, y: raw.y };
  }
  throw new BrokerError(
    "server_configuration_error",
    500,
    "SPYCLASH_OIDC_PUBLIC_JWK must be an RSA or P-256 public JWK",
  );
}

async function loadBrokerKeys() {
  const keyId = requiredEnv("SPYCLASH_OIDC_KEY_ID");
  const privatePem = decodeBase64Utf8(
    requiredEnv("SPYCLASH_OIDC_PRIVATE_KEY_PEM_B64"),
    "SPYCLASH_OIDC_PRIVATE_KEY_PEM_B64",
  );
  if (!privatePem.includes("-----BEGIN PRIVATE KEY-----")) { // gitleaks:allow -- validates a PEM header literal, not a key.
    throw new BrokerError(
      "server_configuration_error",
      500,
      "SPYCLASH_OIDC_PRIVATE_KEY_PEM_B64 must decode to a PKCS#8 private key",
    );
  }

  let parsed: JWK;
  try {
    parsed = JSON.parse(requiredEnv("SPYCLASH_OIDC_PUBLIC_JWK")) as JWK;
  } catch {
    throw new BrokerError(
      "server_configuration_error",
      500,
      "SPYCLASH_OIDC_PUBLIC_JWK is not valid JSON",
    );
  }

  if (parsed.kid && parsed.kid !== keyId) {
    throw new BrokerError(
      "server_configuration_error",
      500,
      "SPYCLASH_OIDC_PUBLIC_JWK kid does not match SPYCLASH_OIDC_KEY_ID",
    );
  }

  const publicJwk = publicJwkOnly(parsed);
  const algorithm = publicJwk.kty === "RSA" ? "RS256" : "ES256";
  const [privateKey, publicKey] = await Promise.all([
    importPKCS8(privatePem, algorithm),
    importJWK(publicJwk, algorithm),
  ]);

  const advertisedJwk: JWK = {
    ...publicJwk,
    alg: algorithm,
    kid: keyId,
    use: "sig",
  };

  // Fail closed if an operator accidentally supplies a public key that does
  // not correspond to the signing key.
  const probe = await new SignJWT({ token_use: "key_probe" })
    .setProtectedHeader({ alg: algorithm, kid: keyId, typ: "JWT" })
    .setIssuer(ISSUER)
    .setAudience("spyclash:key-probe")
    .setIssuedAt()
    .setExpirationTime("30s")
    .sign(privateKey);
  await jwtVerify(probe, publicKey, {
    algorithms: [algorithm],
    issuer: ISSUER,
    audience: "spyclash:key-probe",
  });

  return { privateKey, publicKey, publicJwk: advertisedJwk, algorithm, keyId };
}

function brokerKeys() {
  brokerKeysPromise ??= loadBrokerKeys();
  return brokerKeysPromise;
}

function loadApplePrivateKey() {
  const pem = decodeBase64Utf8(
    requiredEnv("APPLE_PRIVATE_KEY_P8_B64"),
    "APPLE_PRIVATE_KEY_P8_B64",
  );
  if (!pem.includes("-----BEGIN PRIVATE KEY-----")) {
    throw new BrokerError(
      "server_configuration_error",
      500,
      "APPLE_PRIVATE_KEY_P8_B64 must decode to an Apple PKCS#8 .p8 key",
    );
  }
  return importPKCS8(pem, "ES256");
}

function applePrivateKey() {
  applePrivateKeyPromise ??= loadApplePrivateKey();
  return applePrivateKeyPromise;
}

function assertMethod(req: Request, ...allowed: string[]) {
  if (!allowed.includes(req.method)) {
    throw new BrokerError("method_not_allowed", 405);
  }
}

function validateBase44RedirectUri(value: string) {
  if (value !== BASE44_REDIRECT_URI) {
    throw new BrokerError("invalid_redirect_uri", 400);
  }
  return value;
}

function bounded(value: string | null, name: string, max: number) {
  if (!value || value.length > max) {
    throw new BrokerError(`invalid_${name}`, 400);
  }
  return value;
}

async function readBodyParams(req: Request) {
  const declaredLength = Number(req.headers.get("content-length") || "0");
  if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES) {
    throw new BrokerError("request_too_large", 413);
  }

  const body = await req.text();
  if (new TextEncoder().encode(body).byteLength > MAX_BODY_BYTES) {
    throw new BrokerError("request_too_large", 413);
  }

  const contentType = (req.headers.get("content-type") || "").toLowerCase();
  if (contentType.includes("application/json")) {
    let parsed: Record<string, unknown>;
    try {
      parsed = JSON.parse(body) as Record<string, unknown>;
    } catch {
      throw new BrokerError("invalid_json", 400);
    }
    const params = new URLSearchParams();
    for (const [key, value] of Object.entries(parsed)) {
      if (value === undefined || value === null) continue;
      params.set(
        key,
        typeof value === "string" ? value : JSON.stringify(value),
      );
    }
    return params;
  }

  return new URLSearchParams(body);
}

async function requestParams(req: Request) {
  const result = new URLSearchParams(new URL(req.url).searchParams);
  if (req.method !== "GET" && req.method !== "HEAD") {
    const body = await readBodyParams(req);
    for (const [key, value] of body) result.set(key, value);
  }
  return result;
}

function normalizeScope(raw: string | null) {
  const requested = (raw || "openid email profile")
    .split(/\s+/)
    .filter(Boolean);
  if (!requested.includes("openid")) {
    throw new BrokerError("invalid_scope", 400);
  }
  const allowed = new Set(["openid", "email", "profile"]);
  if (requested.some((scope) => !allowed.has(scope))) {
    throw new BrokerError("invalid_scope", 400);
  }
  return [...new Set(requested)].join(" ");
}

function pkceFields(challenge: string | null, method: string | null) {
  if (!challenge && !method) return {};
  if (
    !challenge ||
    method !== "S256" ||
    challenge.length < 43 ||
    challenge.length > 128 ||
    !/^[A-Za-z0-9_-]+$/.test(challenge)
  ) {
    throw new BrokerError("invalid_request", 400);
  }
  return {
    codeChallenge: challenge,
    codeChallengeMethod: "S256" as const,
  };
}

function nativeCookie(ticket: string) {
  return `${NATIVE_COOKIE}=${ticket}; Max-Age=${NATIVE_TICKET_TTL_SECONDS}; Path=/; HttpOnly; Secure; SameSite=Lax`;
}

function clearNativeCookie() {
  return `${NATIVE_COOKIE}=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=Lax`;
}

function baseHeaders() {
  return {
    "Cache-Control": "no-store",
    Pragma: "no-cache",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
  };
}

type ResponseCookies = string | readonly string[] | undefined;

function appendResponseCookies(headers: Headers, cookies: ResponseCookies) {
  if (!cookies) return;
  for (const cookie of typeof cookies === "string" ? [cookies] : cookies) {
    headers.append("Set-Cookie", cookie);
  }
}

function cookieList(cookies: ResponseCookies) {
  if (!cookies) return [];
  return typeof cookies === "string" ? [cookies] : [...cookies];
}

function redirect(location: string, cookies?: ResponseCookies) {
  const headers = new Headers({ ...baseHeaders(), Location: location });
  appendResponseCookies(headers, cookies);
  return new Response(null, { status: 302, headers });
}

function json(value: unknown, status = 200, extraHeaders?: HeadersInit) {
  return Response.json(value, {
    status,
    headers: {
      ...baseHeaders(),
      ...Object.fromEntries(new Headers(extraHeaders)),
    },
  });
}

function requireStringClaim(payload: JWTPayload, claim: string, max = 4096) {
  const value = payload[claim];
  if (typeof value !== "string" || value.length === 0 || value.length > max) {
    throw new BrokerError("invalid_token", 401);
  }
  return value;
}

function booleanClaim(value: unknown) {
  return value === true || value === "true" || value === 1 || value === "1";
}

function cleanName(value: string | undefined, fallbackEmail: string) {
  const withoutControls = Array.from(value || "", (character) => {
    const code = character.charCodeAt(0);
    return code <= 31 || code === 127 ? " " : character;
  }).join("");
  const clean = withoutControls
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 120);
  return clean || fallbackEmail.split("@")[0].slice(0, 120) ||
    "SpyClash Player";
}

function nameFromInput(params: URLSearchParams) {
  const explicit = params.get("full_name") || params.get("name");
  if (explicit && !explicit.trim().startsWith("{")) return explicit;

  const user = params.get("user");
  if (user) {
    try {
      const parsed = JSON.parse(user) as {
        name?: { firstName?: string; lastName?: string };
        given_name?: string;
        family_name?: string;
        full_name?: string;
      };
      if (parsed.full_name) return parsed.full_name;
      const first = parsed.name?.firstName || parsed.given_name || "";
      const last = parsed.name?.lastName || parsed.family_name || "";
      const combined = `${first} ${last}`.trim();
      if (combined) return combined;
    } catch {
      // Apple supplies the user JSON only on first authorization. Malformed
      // optional profile data must not weaken token validation.
    }
  }

  const first = params.get("given_name") || "";
  const last = params.get("family_name") || "";
  return `${first} ${last}`.trim() || undefined;
}

async function signBrokerJwt(
  claims: JWTPayload,
  audience: string,
  ttlSeconds: number,
) {
  const keys = await brokerKeys();
  return new SignJWT(claims)
    .setProtectedHeader({ alg: keys.algorithm, kid: keys.keyId, typ: "JWT" })
    .setIssuer(ISSUER)
    .setAudience(audience)
    .setIssuedAt()
    .setJti(randomBase64Url(18))
    .setExpirationTime(Math.floor(Date.now() / 1000) + ttlSeconds)
    .sign(keys.privateKey);
}

async function verifyBrokerJwt(
  token: string,
  audience: string,
  tokenUse: string,
) {
  if (token.length > 20_000) throw new BrokerError("invalid_token", 401);
  const keys = await brokerKeys();
  const verified = await jwtVerify(token, keys.publicKey, {
    algorithms: [keys.algorithm],
    issuer: ISSUER,
    audience,
    clockTolerance: 5,
  });
  if (verified.payload.token_use !== tokenUse) {
    throw new BrokerError("invalid_token", 401);
  }
  return verified.payload;
}

async function createAppleClientSecret(clientId: string) {
  const [privateKey, teamId, keyId] = await Promise.all([
    applePrivateKey(),
    Promise.resolve(requiredEnv("APPLE_TEAM_ID")),
    Promise.resolve(requiredEnv("APPLE_KEY_ID")),
  ]);
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyId, typ: "JWT" })
    .setIssuer(teamId)
    .setSubject(clientId)
    .setAudience(APPLE_ISSUER)
    .setIssuedAt(now)
    .setExpirationTime(now + 300)
    .sign(privateKey);
}

async function redeemAppleCode(
  code: string,
  clientId: string,
  redirectUri?: string,
  hooks: {
    beforeRequest?: () => void;
    onRefreshToken?: (refreshToken: string) => void;
  } = {},
) {
  bounded(code, "authorization_code", 4096);
  const clientSecret = await createAppleClientSecret(clientId);
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    client_id: clientId,
    client_secret: clientSecret,
  });
  if (redirectUri) body.set("redirect_uri", redirectUri);

  hooks.beforeRequest?.();
  const response = await fetch(APPLE_TOKEN_ENDPOINT, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body,
  });

  let data: Record<string, unknown>;
  try {
    data = await response.json() as Record<string, unknown>;
  } catch {
    throw new AppleCodeExchangeError(
      "apple_token_exchange_failed",
      502,
      appleCodeExchangeTokenOutcome(response, undefined),
    );
  }
  const refreshToken = typeof data.refresh_token === "string"
    ? data.refresh_token.trim()
    : "";
  if (refreshToken) hooks.onRefreshToken?.(refreshToken);
  if (
    !response.ok || typeof data.id_token !== "string" ||
    !refreshToken
  ) {
    throw new AppleCodeExchangeError(
      "invalid_grant",
      response.ok ? 502 : 400,
      appleCodeExchangeTokenOutcome(response, data),
    );
  }
  return { ...data, refresh_token: refreshToken } as Record<string, unknown> & {
    id_token: string;
    refresh_token: string;
  };
}

type AppleCredentialStores = {
  credentialStore: any;
  lifecycleStore: any;
};

function appleCredentialStores(req: Request): AppleCredentialStores {
  const base44 = createClientFromRequest(requestForBase44ServiceRole(req));
  return {
    credentialStore: base44.asServiceRole.entities.AppleSignInCredential,
    lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
  };
}

async function persistAppleCredential(
  stores: AppleCredentialStores,
  redeemed: { refresh_token: string },
  profile: Profile,
  clientID: string,
  issuanceBoundary?: AppleCredentialIssuanceBoundary,
) {
  return await persistPendingAppleSignInCredential({
    store: stores.credentialStore,
    lifecycleStore: stores.lifecycleStore,
    email: profile.email,
    subject: profile.sub,
    clientID,
    refreshToken: redeemed.refresh_token,
    issuanceBoundary,
  });
}

async function verifyAppleIdentityToken(
  token: string,
  clientId: string,
  expectedNonce: string,
) {
  if (!token || token.length > 20_000) {
    throw new BrokerError("invalid_apple_identity_token", 401);
  }
  const verified = await jwtVerify(token, APPLE_JWKS, {
    algorithms: ["RS256"],
    issuer: APPLE_ISSUER,
    audience: clientId,
    clockTolerance: 5,
    requiredClaims: ["sub", "nonce", "iat", "exp"],
  });
  const nonce = requireStringClaim(verified.payload, "nonce", 512);
  if (!await secureEqual(nonce, expectedNonce)) {
    throw new BrokerError("invalid_apple_nonce", 401);
  }
  return verified.payload;
}

async function redeemGoogleCode(code: string) {
  bounded(code, "authorization_code", 4096);
  const clientId = requiredEnv("GOOGLE_OAUTH_CLIENT_ID");
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    client_id: clientId,
    client_secret: requiredEnv("google_oauth_client_secret", false),
    redirect_uri: GOOGLE_CALLBACK_URL,
  });

  const response = await fetch(GOOGLE_TOKEN_ENDPOINT, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body,
  });

  let data: Record<string, unknown>;
  try {
    data = await response.json() as Record<string, unknown>;
  } catch {
    throw new BrokerError("google_token_exchange_failed", 502);
  }
  if (!response.ok || typeof data.id_token !== "string") {
    throw new BrokerError("invalid_grant", 400);
  }
  return data as Record<string, unknown> & { id_token: string };
}

async function verifyGoogleIdentityToken(
  token: string,
  expectedNonce: string,
) {
  if (!token || token.length > 20_000) {
    throw new BrokerError("invalid_google_identity_token", 401);
  }
  const clientId = requiredEnv("GOOGLE_OAUTH_CLIENT_ID");
  const verified = await jwtVerify(token, GOOGLE_JWKS, {
    algorithms: ["RS256"],
    issuer: GOOGLE_ISSUERS,
    audience: clientId,
    clockTolerance: 5,
    requiredClaims: ["sub", "email", "nonce", "iat", "exp"],
  });
  if (
    verified.payload.azp !== undefined &&
    (typeof verified.payload.azp !== "string" ||
      !await secureEqual(verified.payload.azp, clientId))
  ) {
    throw new BrokerError("invalid_google_presenter", 401);
  }
  const nonce = requireStringClaim(verified.payload, "nonce", 512);
  if (!await secureEqual(nonce, expectedNonce)) {
    throw new BrokerError("invalid_google_nonce", 401);
  }
  return verified.payload;
}

function profileFromApple(
  payload: JWTPayload,
  requestedName?: string,
): Profile {
  const sub = requireStringClaim(payload, "sub", 512);
  const email = requireStringClaim(payload, "email", 320).toLowerCase();
  if (!email.includes("@")) throw new BrokerError("invalid_apple_email", 401);
  const emailVerified = booleanClaim(payload.email_verified);
  if (!emailVerified) {
    throw new BrokerError("unverified_apple_email", 401);
  }
  const authTime = typeof payload.auth_time === "number"
    ? Math.floor(payload.auth_time)
    : Math.floor(Date.now() / 1000);
  return {
    sub,
    email,
    emailVerified,
    name: cleanName(requestedName, email),
    isPrivateEmail: booleanClaim(payload.is_private_email),
    authTime,
  };
}

function profileFromGoogle(payload: JWTPayload): Profile {
  const providerSub = requireStringClaim(payload, "sub", 512);
  const email = requireStringClaim(payload, "email", 320).toLowerCase();
  if (!email.includes("@")) throw new BrokerError("invalid_google_email", 401);
  const emailVerified = booleanClaim(payload.email_verified);
  if (!emailVerified) {
    throw new BrokerError("unverified_google_email", 401);
  }
  const explicitName = typeof payload.name === "string"
    ? payload.name
    : [payload.given_name, payload.family_name]
      .filter((value): value is string => typeof value === "string")
      .join(" ");
  const authTime = typeof payload.auth_time === "number"
    ? Math.floor(payload.auth_time)
    : Math.floor(Date.now() / 1000);
  return {
    sub: `google:${providerSub}`,
    email,
    emailVerified,
    name: cleanName(explicitName, email),
    isPrivateEmail: false,
    authTime,
  };
}

async function assertSameAppleIdentity(left: JWTPayload, right: JWTPayload) {
  const leftSub = requireStringClaim(left, "sub", 512);
  const rightSub = requireStringClaim(right, "sub", 512);
  if (!await secureEqual(leftSub, rightSub)) {
    throw new BrokerError("apple_identity_mismatch", 401);
  }
}

function issueAuthorizationCode(
  profile: Profile,
  oidc: OidcRequest,
  upstreamProvider: UpstreamAuthProvider,
  appleClientID?: string,
) {
  return signBrokerJwt(
    {
      token_use: "authorization_code",
      upstream_provider: upstreamProvider,
      apple_client_id: upstreamProvider === "apple" ? appleClientID : undefined,
      sub: profile.sub,
      email: profile.email,
      email_verified: profile.emailVerified,
      name: profile.name,
      is_private_email: profile.isPrivateEmail,
      auth_time: profile.authTime,
      client_id: oidc.clientId,
      redirect_uri: oidc.redirectUri,
      nonce: oidc.nonce,
      scope: oidc.scope,
      code_challenge: oidc.codeChallenge,
      code_challenge_method: oidc.codeChallengeMethod,
    },
    oidc.clientId,
    AUTHORIZATION_CODE_TTL_SECONDS,
  );
}

async function authorizationSuccess(
  profile: Profile,
  oidc: OidcRequest,
  upstreamProvider: UpstreamAuthProvider,
  appleClientID?: string,
  cookies?: ResponseCookies,
) {
  const code = await issueAuthorizationCode(
    profile,
    oidc,
    upstreamProvider,
    appleClientID,
  );
  const location = new URL(oidc.redirectUri);
  location.searchParams.set("code", code);
  location.searchParams.set("state", oidc.state);
  return redirect(location.toString(), cookies);
}

function authorizationError(
  oidc: OidcRequest,
  code: string,
  cookies: ResponseCookies,
) {
  const location = new URL(oidc.redirectUri);
  location.searchParams.set("error", code);
  location.searchParams.set("state", oidc.state);
  return redirect(location.toString(), cookies);
}

function oidcRequestFromPayload(payload: JWTPayload): OidcRequest {
  return {
    clientId: requireStringClaim(payload, "client_id", 512),
    redirectUri: validateBase44RedirectUri(
      requireStringClaim(payload, "redirect_uri", 2048),
    ),
    state: requireStringClaim(payload, "oidc_state", 4096),
    nonce: typeof payload.oidc_nonce === "string"
      ? payload.oidc_nonce
      : undefined,
    scope: normalizeScope(
      typeof payload.scope === "string"
        ? payload.scope
        : "openid email profile",
    ),
    ...pkceFields(
      typeof payload.code_challenge === "string"
        ? payload.code_challenge
        : null,
      typeof payload.code_challenge_method === "string"
        ? payload.code_challenge_method
        : null,
    ),
  };
}

function oidcStateClaims(oidc: OidcRequest): JWTPayload {
  return {
    flow: "oidc",
    client_id: oidc.clientId,
    redirect_uri: oidc.redirectUri,
    oidc_state: oidc.state,
    oidc_nonce: oidc.nonce,
    scope: oidc.scope,
    code_challenge: oidc.codeChallenge,
    code_challenge_method: oidc.codeChallengeMethod,
  };
}

async function beginAppleAuthorization(
  oidc: OidcRequest,
  cookies?: ResponseCookies,
) {
  const transaction = await createUpstreamTransaction();
  const appleNonce = await sha256Base64Url(randomBase64Url());
  const state = await signBrokerJwt(
    {
      ...oidcStateClaims(oidc),
      token_use: "apple_state",
      apple_nonce: appleNonce,
      browser_transaction_hash: transaction.secretHash,
    },
    APPLE_STATE_AUDIENCE,
    APPLE_STATE_TTL_SECONDS,
  );

  const appleURL = new URL(APPLE_AUTH_ENDPOINT);
  appleURL.searchParams.set("client_id", requiredEnv("APPLE_WEB_CLIENT_ID"));
  appleURL.searchParams.set("redirect_uri", APPLE_CALLBACK_URL);
  appleURL.searchParams.set("response_type", "code id_token");
  appleURL.searchParams.set("response_mode", "form_post");
  appleURL.searchParams.set("scope", "name email");
  appleURL.searchParams.set("state", state);
  appleURL.searchParams.set("nonce", appleNonce);
  return redirect(appleURL.toString(), [
    upstreamTransactionCookie(transaction.secret, APPLE_STATE_TTL_SECONDS),
    ...cookieList(cookies),
  ]);
}

async function beginGoogleAuthorization(
  oidc: OidcRequest,
) {
  const issued = await issueGoogleAuthorizationState(oidc, "primary");
  return primaryGoogleTransactionHandoff(
    googleTransactionConfirmationURL(issued.state).toString(),
    upstreamTransactionCookie(
      issued.transactionSecret,
      GOOGLE_STATE_TTL_SECONDS,
      "None",
    ),
  );
}

async function issueGoogleAuthorizationState(
  oidc: OidcRequest,
  transactionChannel: GoogleTransactionChannel,
) {
  const transaction = await createUpstreamTransaction();
  const googleNonce = randomBase64Url();
  const state = await signBrokerJwt(
    {
      ...oidcStateClaims(oidc),
      token_use: "google_state",
      upstream_provider: "google",
      google_nonce: googleNonce,
      browser_transaction_hash: transaction.secretHash,
      browser_transaction_channel: transactionChannel,
    },
    GOOGLE_STATE_AUDIENCE,
    GOOGLE_STATE_TTL_SECONDS,
  );

  return {
    state,
    transactionSecret: transaction.secret,
  };
}

function googleTransactionConfirmationURL(state: string) {
  const confirmationURL = new URL(ISSUER);
  confirmationURL.searchParams.set("action", "confirm-google-transaction");
  confirmationURL.searchParams.set("state", state);
  return confirmationURL;
}

function googleAuthorizationURL(state: string, statePayload: JWTPayload) {
  const googleURL = new URL(GOOGLE_AUTH_ENDPOINT);
  googleURL.searchParams.set(
    "client_id",
    requiredEnv("GOOGLE_OAUTH_CLIENT_ID"),
  );
  googleURL.searchParams.set("redirect_uri", GOOGLE_CALLBACK_URL);
  googleURL.searchParams.set("response_type", "code");
  googleURL.searchParams.set("scope", "openid email profile");
  googleURL.searchParams.set("state", state);
  googleURL.searchParams.set(
    "nonce",
    requireStringClaim(statePayload, "google_nonce", 512),
  );
  googleURL.searchParams.set("prompt", "select_account");
  return googleURL;
}

async function verifiedGoogleAuthorizationState(rawState: string | null) {
  const state = bounded(rawState, "state", 20_000);
  let statePayload: JWTPayload;
  try {
    statePayload = await verifyBrokerJwt(
      state,
      GOOGLE_STATE_AUDIENCE,
      "google_state",
    );
  } catch {
    console.error("appleAuthBroker Google state rejected", {
      reason: "state_jwt_invalid",
    });
    throw new BrokerError("invalid_state", 400);
  }

  let oidc: OidcRequest;
  try {
    oidc = oidcRequestFromPayload(statePayload);
  } catch {
    console.error("appleAuthBroker Google state rejected", {
      reason: "state_claims_invalid",
    });
    throw new BrokerError("invalid_state", 400);
  }

  if (!await secureEqual(oidc.clientId, requiredEnv("sso_client_id"))) {
    console.error("appleAuthBroker Google state rejected", {
      reason: "client_id_mismatch",
    });
    throw new BrokerError("invalid_state", 400);
  }
  if (
    statePayload.flow !== "oidc" ||
    statePayload.upstream_provider !== "google"
  ) {
    console.error("appleAuthBroker Google state rejected", {
      reason: "provider_claims_invalid",
    });
    throw new BrokerError("invalid_state", 400);
  }

  const transactionChannel = googleTransactionChannelFromClaim(
    statePayload.browser_transaction_channel,
  );
  if (!transactionChannel) {
    console.error("appleAuthBroker Google state rejected", {
      reason: "transaction_channel_invalid",
    });
    throw new BrokerError("invalid_state", 400);
  }

  return { state, statePayload, oidc, transactionChannel };
}

async function handleConfirmGoogleTransaction(
  req: Request,
  params: URLSearchParams,
) {
  assertMethod(req, "GET");
  const verified = await verifiedGoogleAuthorizationState(params.get("state"));
  const expectedHash = verified.statePayload.browser_transaction_hash;
  if (typeof expectedHash !== "string") {
    console.error("appleAuthBroker Google transaction rejected", {
      reason: "transaction_hash_missing",
    });
    throw new BrokerError("invalid_state", 400);
  }

  const cookieHeader = req.headers.get("cookie");
  const matches = verified.transactionChannel === "primary"
    ? await upstreamTransactionMatches(cookieHeader, expectedHash)
    : await upstreamFallbackTransactionMatches(cookieHeader, expectedHash);
  if (matches) {
    return redirect(
      googleAuthorizationURL(
        verified.state,
        verified.statePayload,
      ).toString(),
    );
  }

  const cookieName = verified.transactionChannel === "primary"
    ? UPSTREAM_TRANSACTION_COOKIE
    : UPSTREAM_FALLBACK_TRANSACTION_COOKIE;
  const cookiePresent = Boolean(
    cookieValue(cookieHeader, cookieName),
  );
  if (verified.transactionChannel === "fallback") {
    console.error("appleAuthBroker Google transaction confirmation failed", {
      reason: cookiePresent
        ? "fallback_cookie_mismatch"
        : "fallback_cookie_missing",
      cookie_present: cookiePresent,
      transaction_channel: verified.transactionChannel,
    });
    return authorizationError(
      verified.oidc,
      "temporarily_unavailable",
      googleCallbackTerminalCookies(),
    );
  }

  console.error("appleAuthBroker Google transaction confirmation retry", {
    reason: cookiePresent
      ? "transaction_cookie_mismatch"
      : "transaction_cookie_missing",
    transaction_channel: verified.transactionChannel,
  });
  const replacement = await issueGoogleAuthorizationState(
    verified.oidc,
    "fallback",
  );
  return fallbackGoogleTransactionHandoff(
    googleTransactionConfirmationURL(replacement.state).toString(),
    upstreamFallbackTransactionCookie(
      replacement.transactionSecret,
      GOOGLE_STATE_TTL_SECONDS,
    ),
  );
}

async function handleAuthorize(req: Request, params: URLSearchParams) {
  assertMethod(req, "GET");
  const configuredClientId = requiredEnv("sso_client_id");
  const clientId = bounded(params.get("client_id"), "client_id", 512);
  if (!await secureEqual(clientId, configuredClientId)) {
    throw new BrokerError("unauthorized_client", 401);
  }
  if (params.get("response_type") !== "code") {
    throw new BrokerError("unsupported_response_type", 400);
  }

  const oidc: OidcRequest = {
    clientId,
    redirectUri: validateBase44RedirectUri(
      bounded(params.get("redirect_uri"), "redirect_uri", 2048),
    ),
    state: bounded(params.get("state"), "state", 4096),
    nonce: params.get("nonce") || undefined,
    scope: normalizeScope(params.get("scope")),
    ...pkceFields(
      params.get("code_challenge"),
      params.get("code_challenge_method"),
    ),
  };
  if (oidc.nonce && oidc.nonce.length > 512) {
    throw new BrokerError("invalid_nonce", 400);
  }

  const upstreamProvider = upstreamProviderFromBase44State(
    oidc.state,
    APP_ID,
    PUBLIC_ORIGIN,
  );
  const ticket = cookieValue(req.headers.get("cookie"), NATIVE_COOKIE);
  if (upstreamProvider === "apple" && ticket) {
    try {
      const payload = await verifyBrokerJwt(
        ticket,
        NATIVE_TICKET_AUDIENCE,
        "native_ticket",
      );
      const profile: Profile = {
        sub: requireStringClaim(payload, "sub", 512),
        email: requireStringClaim(payload, "email", 320),
        emailVerified: booleanClaim(payload.email_verified),
        name: cleanName(
          typeof payload.name === "string" ? payload.name : undefined,
          requireStringClaim(payload, "email", 320),
        ),
        isPrivateEmail: booleanClaim(payload.is_private_email),
        authTime: typeof payload.auth_time === "number"
          ? payload.auth_time
          : Math.floor(Date.now() / 1000),
      };
      const appleClientID = requireStringClaim(
        payload,
        "apple_client_id",
        255,
      );
      if (
        !await secureEqual(appleClientID, requiredEnv("APPLE_NATIVE_CLIENT_ID"))
      ) {
        throw new BrokerError("invalid_native_ticket", 401);
      }
      return authorizationSuccess(
        profile,
        oidc,
        "apple",
        appleClientID,
        clearNativeCookie(),
      );
    } catch {
      // Invalid or expired bootstrap cookies do not reveal validation details;
      // clear them and continue with a normal Apple authorization.
    }
  }

  if (upstreamProvider === "google") {
    // The native bootstrap ticket is ignored for Google and expires after 90
    // seconds. Keeping this response to one application-owned Set-Cookie avoids
    // giving edge proxies another cookie to fold into the transaction header.
    return beginGoogleAuthorization(oidc);
  }

  const cookie = ticket ? clearNativeCookie() : undefined;
  return beginAppleAuthorization(oidc, cookie);
}

async function authenticateOidcClient(req: Request, params: URLSearchParams) {
  let suppliedId = params.get("client_id") || "";
  let suppliedSecret = params.get("client_secret") || "";
  const authorization = req.headers.get("authorization");

  if (authorization?.startsWith("Basic ")) {
    try {
      const decoded = atob(authorization.slice(6).trim());
      const separator = decoded.indexOf(":");
      if (separator < 0) throw new Error("invalid basic auth");
      const decodePart = (value: string) => {
        try {
          return decodeURIComponent(value);
        } catch {
          return value;
        }
      };
      const basicId = decodePart(decoded.slice(0, separator));
      const basicSecret = decodePart(decoded.slice(separator + 1));
      if (suppliedId && !await secureEqual(suppliedId, basicId)) {
        throw new BrokerError("invalid_client", 401);
      }
      suppliedId = basicId;
      suppliedSecret = basicSecret;
    } catch (error) {
      if (error instanceof BrokerError) throw error;
      throw new BrokerError("invalid_client", 401);
    }
  }

  const expectedId = requiredEnv("sso_client_id");
  const expectedSecret = requiredEnv("sso_client_secret", false);
  if (
    !suppliedId ||
    !suppliedSecret ||
    !await secureEqual(suppliedId, expectedId) ||
    !await secureEqual(suppliedSecret, expectedSecret)
  ) {
    throw new BrokerError("invalid_client", 401);
  }
  return expectedId;
}

async function handleToken(req: Request, params: URLSearchParams) {
  assertMethod(req, "POST");
  const clientId = await authenticateOidcClient(req, params);
  if (params.get("grant_type") !== "authorization_code") {
    throw new BrokerError("unsupported_grant_type", 400);
  }

  const redirectUri = validateBase44RedirectUri(
    bounded(params.get("redirect_uri"), "redirect_uri", 2048),
  );
  const code = bounded(params.get("code"), "authorization_code", 20_000);
  let payload: JWTPayload;
  try {
    payload = await verifyBrokerJwt(code, clientId, "authorization_code");
  } catch {
    throw new BrokerError("invalid_grant", 400);
  }

  if (
    !await secureEqual(
      requireStringClaim(payload, "client_id", 512),
      clientId,
    ) ||
    !await secureEqual(
      requireStringClaim(payload, "redirect_uri", 2048),
      redirectUri,
    )
  ) {
    throw new BrokerError("invalid_grant", 400);
  }

  if (typeof payload.code_challenge === "string") {
    if (payload.code_challenge_method !== "S256") {
      throw new BrokerError("invalid_grant", 400);
    }
    const verifier = bounded(
      params.get("code_verifier"),
      "code_verifier",
      128,
    );
    if (
      verifier.length < 43 ||
      !/^[A-Za-z0-9._~-]+$/.test(verifier) ||
      !await secureEqual(
        await sha256Base64Url(verifier),
        payload.code_challenge,
      )
    ) {
      throw new BrokerError("invalid_grant", 400);
    }
  }

  const upstreamProvider = requireStringClaim(
    payload,
    "upstream_provider",
    16,
  );
  if (upstreamProvider !== "apple" && upstreamProvider !== "google") {
    throw new BrokerError("invalid_grant", 400);
  }

  const sub = requireStringClaim(payload, "sub", 512);
  const email = requireStringClaim(payload, "email", 320);
  const name = cleanName(
    typeof payload.name === "string" ? payload.name : undefined,
    email,
  );
  const scope = typeof payload.scope === "string"
    ? normalizeScope(payload.scope)
    : "openid email profile";
  const commonClaims: JWTPayload = {
    sub,
    email,
    email_verified: booleanClaim(payload.email_verified),
    name,
    is_private_email: booleanClaim(payload.is_private_email),
    auth_time: typeof payload.auth_time === "number"
      ? payload.auth_time
      : Math.floor(Date.now() / 1000),
    scope,
  };

  const issueTokens = async () => {
    const accessToken = await signBrokerJwt(
      { ...commonClaims, token_use: "access_token" },
      USERINFO_AUDIENCE,
      ACCESS_TOKEN_TTL_SECONDS,
    );
    const idToken = await signBrokerJwt(
      {
        ...commonClaims,
        token_use: "id_token",
        nonce: typeof payload.nonce === "string" ? payload.nonce : undefined,
      },
      clientId,
      ID_TOKEN_TTL_SECONDS,
    );

    return json({
      access_token: accessToken,
      token_type: "Bearer",
      expires_in: ACCESS_TOKEN_TTL_SECONDS,
      id_token: idToken,
      scope,
    });
  };

  if (upstreamProvider === "google") return await issueTokens();

  const appleClientID = requireStringClaim(payload, "apple_client_id", 255);
  const allowedAppleClientIDs = [
    requiredEnv("APPLE_NATIVE_CLIENT_ID"),
    requiredEnv("APPLE_WEB_CLIENT_ID"),
  ];
  let allowedAppleClientID = false;
  for (const expectedClientID of allowedAppleClientIDs) {
    if (await secureEqual(appleClientID, expectedClientID)) {
      allowedAppleClientID = true;
      break;
    }
  }
  if (!allowedAppleClientID) throw new BrokerError("invalid_grant", 400);

  const stores = appleCredentialStores(req);
  try {
    return await withAppleCredentialIdentityWriter({
      lifecycleStore: stores.lifecycleStore,
      email,
      operation: async (identityWriter: AppleCredentialIdentityWriter) => {
        await assertTrackedAppleSignInCredential({
          store: stores.credentialStore,
          lifecycleStore: stores.lifecycleStore,
          email,
          subject: sub,
          clientID: appleClientID,
          identityWriter,
        });
        return await issueTokens();
      },
    });
  } catch (error) {
    const publicError = publicAppleCredentialBrokerError(error);
    if (publicError) {
      throw new BrokerError(
        publicError.code,
        publicError.status,
      );
    }
    throw error;
  }
}

async function handleUserinfo(req: Request) {
  assertMethod(req, "GET", "POST");
  const authorization = req.headers.get("authorization") || "";
  if (!authorization.startsWith("Bearer ")) {
    throw new BrokerError("invalid_token", 401);
  }
  const token = authorization.slice(7).trim();
  let payload: JWTPayload;
  try {
    payload = await verifyBrokerJwt(token, USERINFO_AUDIENCE, "access_token");
  } catch {
    throw new BrokerError("invalid_token", 401);
  }

  return json({
    sub: requireStringClaim(payload, "sub", 512),
    email: requireStringClaim(payload, "email", 320),
    email_verified: booleanClaim(payload.email_verified),
    name: cleanName(
      typeof payload.name === "string" ? payload.name : undefined,
      requireStringClaim(payload, "email", 320),
    ),
  });
}

async function handleJwks(req: Request) {
  assertMethod(req, "GET");
  const keys = await brokerKeys();
  return Response.json(
    { keys: [keys.publicJwk] },
    {
      headers: {
        "Cache-Control": "public, max-age=300",
        "Content-Type": "application/json; charset=utf-8",
        "X-Content-Type-Options": "nosniff",
      },
    },
  );
}

async function handleNativeExchange(req: Request, params: URLSearchParams) {
  assertMethod(req, "POST");
  const clientId = requiredEnv("APPLE_NATIVE_CLIENT_ID");
  if (!await secureEqual(clientId, EXPECTED_APPLE_NATIVE_CLIENT_ID)) {
    throw new BrokerError(
      "apple_native_client_misconfigured",
      503,
      "APPLE_NATIVE_CLIENT_ID does not match the current SpyClash iOS app",
    );
  }
  const code = bounded(
    params.get("authorization_code") || params.get("code"),
    "authorization_code",
    4096,
  );
  const identityToken = bounded(
    params.get("identity_token"),
    "identity_token",
    20_000,
  );
  const rawNonce = bounded(
    params.get("raw_nonce") || params.get("nonce"),
    "raw_nonce",
    512,
  );
  // AuthenticationServices receives a lowercase SHA-256 hex nonce from the
  // iOS client and Apple echoes that exact value in the identity token.
  const expectedNonce = await sha256Hex(rawNonce);

  const presentedPayload = await verifyAppleIdentityToken(
    identityToken,
    clientId,
    expectedNonce,
  );
  const requestedName = nameFromInput(params);
  const presentedProfile = profileFromApple(presentedPayload, requestedName);
  const stores = appleCredentialStores(req);
  let exchangeRequestStarted = false;
  let issuedRefreshToken: string | undefined;
  let tokenTracked = false;

  // Persist a deletion-state issuance boundary before asking Apple to mint a
  // refresh token. Unknown exchange/compensation outcomes retain that durable
  // boundary; ordinary writers can never take it over after lease expiry.
  return await withAppleCredentialIssuanceBoundary({
    lifecycleStore: stores.lifecycleStore,
    email: presentedProfile.email,
    onOperationError: async (error) => {
      if (tokenTracked || !exchangeRequestStarted) return "release";
      if (!issuedRefreshToken) {
        return error instanceof AppleCodeExchangeError &&
            error.tokenOutcome === "not_issued"
          ? "release"
          : "retain";
      }
      return await compensateUntrackedAppleRefreshToken({
        refreshToken: issuedRefreshToken,
        clientID: clientId,
        createClientSecret: createAppleClientSecret,
      });
    },
    operation: async (issuanceBoundary) => {
      const redeemed = await redeemAppleCode(code, clientId, undefined, {
        beforeRequest: () => {
          exchangeRequestStarted = true;
        },
        onRefreshToken: (token) => {
          issuedRefreshToken = token;
        },
      });
      const redeemedPayload = await verifyAppleIdentityToken(
        redeemed.id_token,
        clientId,
        expectedNonce,
      );
      await assertSameAppleIdentity(presentedPayload, redeemedPayload);

      const profile = profileFromApple(redeemedPayload, requestedName);
      const storedCredential = await persistAppleCredential(
        stores,
        redeemed,
        profile,
        clientId,
        issuanceBoundary,
      );
      tokenTracked = true;
      const ticket = await signBrokerJwt(
        {
          token_use: "native_ticket",
          sub: profile.sub,
          email: profile.email,
          email_verified: profile.emailVerified,
          name: profile.name,
          is_private_email: profile.isPrivateEmail,
          auth_time: profile.authTime,
          apple_client_id: clientId,
        },
        NATIVE_TICKET_AUDIENCE,
        NATIVE_TICKET_TTL_SECONDS,
      );

      const bootstrapURL = new URL(ISSUER);
      bootstrapURL.searchParams.set("action", "native-bootstrap");
      bootstrapURL.searchParams.set("ticket", ticket);
      return json({
        bootstrap_url: bootstrapURL.toString(),
        binding_ticket: storedCredential.bindingTicket,
        expires_in: NATIVE_TICKET_TTL_SECONDS,
      });
    },
  });
}

async function handleNativeBootstrap(req: Request, params: URLSearchParams) {
  assertMethod(req, "GET");
  const ticket = bounded(params.get("ticket"), "ticket", 20_000);
  await verifyBrokerJwt(ticket, NATIVE_TICKET_AUDIENCE, "native_ticket");

  const ssoURL = new URL(BASE44_SSO_LOGIN_URL);
  ssoURL.searchParams.set("app_id", APP_ID);
  ssoURL.searchParams.set("from_url", MOBILE_AUTH_CALLBACK_URL);
  return redirect(ssoURL.toString(), nativeCookie(ticket));
}

async function assertBrowserTransaction(
  req: Request,
  statePayload: JWTPayload,
  context: "apple_callback" | "google_callback",
  transactionChannel: GoogleTransactionChannel = "primary",
) {
  const expectedHash = statePayload.browser_transaction_hash;
  if (typeof expectedHash !== "string") {
    console.error("appleAuthBroker browser transaction rejected", {
      context,
      reason: "transaction_hash_missing",
    });
    throw new BrokerError("invalid_state", 400);
  }

  const cookieHeader = req.headers.get("cookie");
  const matches = transactionChannel === "primary"
    ? await upstreamTransactionMatches(cookieHeader, expectedHash)
    : await upstreamFallbackTransactionMatches(cookieHeader, expectedHash);
  if (matches) return;

  const cookieName = transactionChannel === "primary"
    ? UPSTREAM_TRANSACTION_COOKIE
    : UPSTREAM_FALLBACK_TRANSACTION_COOKIE;
  console.error("appleAuthBroker browser transaction rejected", {
    context,
    transaction_channel: transactionChannel,
    reason: cookieValue(cookieHeader, cookieName)
      ? "transaction_cookie_mismatch"
      : "transaction_cookie_missing",
  });
  throw new BrokerError("invalid_state", 400);
}

function appleCallbackTerminalCookies() {
  // Some hosting proxies fold Set-Cookie headers. Keep the security-critical
  // transaction clear first so it is still applied by conservative clients.
  return [clearUpstreamTransactionCookie(), clearNativeCookie()];
}

function googleCallbackTerminalCookies() {
  return [
    clearUpstreamTransactionCookie("None"),
    clearUpstreamFallbackTransactionCookie(),
  ];
}

async function handleAppleCallback(req: Request, params: URLSearchParams) {
  assertMethod(req, "POST", "GET");
  const state = bounded(params.get("state"), "state", 20_000);
  let statePayload: JWTPayload;
  try {
    statePayload = await verifyBrokerJwt(
      state,
      APPLE_STATE_AUDIENCE,
      "apple_state",
    );
  } catch {
    throw new BrokerError("invalid_state", 400);
  }
  await assertBrowserTransaction(req, statePayload, "apple_callback");

  const oidc = oidcRequestFromPayload(statePayload);
  if (!await secureEqual(oidc.clientId, requiredEnv("sso_client_id"))) {
    throw new BrokerError("invalid_state", 400);
  }
  if (statePayload.flow !== "oidc") {
    throw new BrokerError("invalid_state", 400);
  }

  const appleError = params.get("error");
  if (appleError) {
    return authorizationError(
      oidc,
      appleError === "user_cancelled_authorize"
        ? "access_denied"
        : "server_error",
      appleCallbackTerminalCookies(),
    );
  }

  try {
    const code = bounded(params.get("code"), "authorization_code", 4096);
    const postedIdToken = bounded(
      params.get("id_token"),
      "identity_token",
      20_000,
    );
    const expectedNonce = requireStringClaim(statePayload, "apple_nonce", 512);
    const clientId = requiredEnv("APPLE_WEB_CLIENT_ID");
    const postedPayload = await verifyAppleIdentityToken(
      postedIdToken,
      clientId,
      expectedNonce,
    );
    const requestedName = nameFromInput(params);
    const postedProfile = profileFromApple(postedPayload, requestedName);
    const stores = appleCredentialStores(req);
    let exchangeRequestStarted = false;
    let issuedRefreshToken: string | undefined;
    let tokenTracked = false;
    return await withAppleCredentialIssuanceBoundary({
      lifecycleStore: stores.lifecycleStore,
      email: postedProfile.email,
      onOperationError: async (error) => {
        if (tokenTracked || !exchangeRequestStarted) return "release";
        if (!issuedRefreshToken) {
          return error instanceof AppleCodeExchangeError &&
              error.tokenOutcome === "not_issued"
            ? "release"
            : "retain";
        }
        return await compensateUntrackedAppleRefreshToken({
          refreshToken: issuedRefreshToken,
          clientID: clientId,
          createClientSecret: createAppleClientSecret,
        });
      },
      operation: async (issuanceBoundary) => {
        const redeemed = await redeemAppleCode(
          code,
          clientId,
          APPLE_CALLBACK_URL,
          {
            beforeRequest: () => {
              exchangeRequestStarted = true;
            },
            onRefreshToken: (token) => {
              issuedRefreshToken = token;
            },
          },
        );
        const redeemedPayload = await verifyAppleIdentityToken(
          redeemed.id_token,
          clientId,
          expectedNonce,
        );
        await assertSameAppleIdentity(postedPayload, redeemedPayload);
        const profile = profileFromApple(redeemedPayload, requestedName);
        // Browser SSO has no authenticated Base44 owner at callback time. The
        // encrypted pending row is intentionally left unowned; deletion finds
        // it by the verified identity key, and a later login rotates it.
        await persistAppleCredential(
          stores,
          redeemed,
          profile,
          clientId,
          issuanceBoundary,
        );
        tokenTracked = true;
        return authorizationSuccess(
          profile,
          oidc,
          "apple",
          clientId,
          appleCallbackTerminalCookies(),
        );
      },
    });
  } catch (error) {
    logCallbackFailure("apple", error);
    return authorizationError(
      oidc,
      "server_error",
      appleCallbackTerminalCookies(),
    );
  }
}

async function handleGoogleCallback(req: Request, params: URLSearchParams) {
  assertMethod(req, "GET");
  const verified = await verifiedGoogleAuthorizationState(params.get("state"));
  const { oidc, statePayload } = verified;
  await assertBrowserTransaction(
    req,
    statePayload,
    "google_callback",
    verified.transactionChannel,
  );

  const googleError = params.get("error");
  if (googleError) {
    return authorizationError(
      oidc,
      googleError === "access_denied" ? "access_denied" : "server_error",
      googleCallbackTerminalCookies(),
    );
  }

  try {
    const code = bounded(params.get("code"), "authorization_code", 4096);
    const expectedNonce = requireStringClaim(
      statePayload,
      "google_nonce",
      512,
    );
    const redeemed = await redeemGoogleCode(code);
    const payload = await verifyGoogleIdentityToken(
      redeemed.id_token,
      expectedNonce,
    );
    const profile = profileFromGoogle(payload);
    return authorizationSuccess(
      profile,
      oidc,
      "google",
      undefined,
      googleCallbackTerminalCookies(),
    );
  } catch (error) {
    logCallbackFailure("google", error);
    return authorizationError(
      oidc,
      "server_error",
      googleCallbackTerminalCookies(),
    );
  }
}

function normalizedInternalErrorCode(error: unknown) {
  const candidate = error instanceof BrokerError
    ? error.code
    : publicAppleCredentialBrokerError(error)?.code ?? "server_error";
  return /^[a-z][a-z0-9_]{0,63}$/.test(candidate) ? candidate : "server_error";
}

function logCallbackFailure(provider: "apple" | "google", error: unknown) {
  console.error("appleAuthBroker upstream callback failed", {
    provider,
    error_code: normalizedInternalErrorCode(error),
  });
}

function normalizedAction(action: string) {
  return new Set([
      "authorize",
      "token",
      "userinfo",
      "jwks",
      "native-exchange",
      "native-bootstrap",
      "confirm-google-transaction",
      "apple-callback",
      "google-callback",
    ]).has(action)
    ? action
    : "unknown";
}

function errorResponse(
  error: unknown,
  action: string,
  cookies?: ResponseCookies,
) {
  const publicAppleError = publicAppleCredentialBrokerError(error);
  const brokerError = error instanceof BrokerError
    ? error
    : publicAppleError
    ? new BrokerError(publicAppleError.code, publicAppleError.status)
    : new BrokerError("server_error", 500);
  const headers = new Headers(baseHeaders());
  if (brokerError.status === 405) {
    headers.set("Allow", action === "userinfo" ? "GET, POST" : "GET");
  }
  if (brokerError.code === "invalid_client") {
    headers.set("WWW-Authenticate", 'Basic realm="SpyClash OIDC"');
  } else if (brokerError.code === "invalid_token") {
    headers.set("WWW-Authenticate", 'Bearer error="invalid_token"');
  }
  appendResponseCookies(headers, cookies);
  return Response.json(
    {
      error: brokerError.code,
      error_description: brokerError.status >= 500
        ? "Authentication service is temporarily unavailable"
        : brokerError.code.replace(/_/g, " "),
    },
    { status: brokerError.status, headers },
  );
}

Deno.serve(async (req) => {
  const action = new URL(req.url).searchParams.get("action") || "";
  try {
    if (req.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "Access-Control-Allow-Origin": "https://spyclash.com",
          "Access-Control-Allow-Headers": "Authorization, Content-Type",
          "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
          "Access-Control-Max-Age": "600",
        },
      });
    }

    const params = await requestParams(req);
    switch (action) {
      case "authorize":
        return await handleAuthorize(req, params);
      case "token":
        return await handleToken(req, params);
      case "userinfo":
        return await handleUserinfo(req);
      case "jwks":
        return await handleJwks(req);
      case "native-exchange":
        return await handleNativeExchange(req, params);
      case "native-bootstrap":
        return await handleNativeBootstrap(req, params);
      case "confirm-google-transaction":
        return await handleConfirmGoogleTransaction(req, params);
      case "apple-callback":
        return await handleAppleCallback(req, params);
      case "google-callback":
        return await handleGoogleCallback(req, params);
      default:
        throw new BrokerError("not_found", 404);
    }
  } catch (error) {
    // Deliberately do not log request bodies, upstream authorization codes,
    // identity tokens, broker codes, tickets, cookies, or configured secrets.
    console.error("appleAuthBroker request failed", {
      action: normalizedAction(action),
      error_code: normalizedInternalErrorCode(error),
    });
    const callbackCookies: ResponseCookies = action === "apple-callback"
      ? clearUpstreamTransactionCookie()
      : action === "google-callback"
      ? googleCallbackTerminalCookies()
      : undefined;
    return errorResponse(error, action, callbackCookies);
  }
});
