const SUPPORTED_PROVIDERS = new Set(["apple", "google"]);

export function buildSocialLoginUrl({ provider, appId, origin }) {
  if (!SUPPORTED_PROVIDERS.has(provider)) {
    throw new Error(`Unsupported social auth provider: ${String(provider)}`);
  }
  if (typeof appId !== "string" || !/^[A-Za-z0-9_-]+$/.test(appId)) {
    throw new Error("Invalid Base44 app id.");
  }

  const appOrigin = new URL(origin);
  if (appOrigin.username || appOrigin.password || appOrigin.pathname !== "/" || appOrigin.search || appOrigin.hash) {
    throw new Error("Invalid application origin.");
  }

  const returnUrl = new URL("/home", appOrigin);
  if (provider === "google") {
    returnUrl.searchParams.set("auth_provider", "google");
  }

  const loginUrl = new URL(`/api/apps/${appId}/auth/sso/login`, appOrigin);
  loginUrl.searchParams.set("app_id", appId);
  loginUrl.searchParams.set("from_url", returnUrl.toString());
  return loginUrl.toString();
}
