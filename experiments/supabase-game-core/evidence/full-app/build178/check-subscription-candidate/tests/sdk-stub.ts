export type Fixture = {
  user: unknown;
  authError?: boolean;
  entitlements: unknown[];
  grants: unknown[];
  quota: unknown[];
  errors: Set<string>;
  calls: string[];
};

export let fixture: Fixture;

export function resetFixture(overrides: Partial<Fixture> = {}) {
  fixture = {
    user: { id: "fixture-base44-user", email: "fixture@example.test" },
    entitlements: [], grants: [], quota: [], errors: new Set(), calls: [],
    ...overrides,
  };
}

export function createClientFromRequest(request: Request): any {
  fixture.calls.push("createClient");
  if (request.headers.get("Base44-App-Id") !== "69a0e57fa939f578082f8091" ||
    request.headers.get("Base44-Api-Url") !== "https://base44.app") {
    throw new Error("Expected canonical Base44 SDK destination");
  }
  const store = (name: "entitlements" | "grants" | "quota") => ({
    filter(filter: Record<string, unknown>) {
      fixture.calls.push(name);
      if (name !== "quota" && filter.user_id !== "fixture-base44-user") {
        throw new Error("Unexpected owner filter");
      }
      if (fixture.errors.has(name)) throw new Error("Fixture provider outage");
      return Promise.resolve(fixture[name]);
    },
  });
  return {
    auth: {
      me() {
        fixture.calls.push("auth.me");
        if (fixture.authError || request.headers.get("Authorization") !== "Bearer fixture-user-credential") {
          throw new Error("Fixture authentication failed");
        }
        return Promise.resolve(fixture.user);
      },
    },
    asServiceRole: { entities: {
      Entitlement: store("entitlements"),
      MembershipGrant: store("grants"),
      AiGenerationUsage: store("quota"),
    } },
  };
}
