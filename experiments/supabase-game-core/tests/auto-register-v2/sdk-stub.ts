export class MemoryStore {
  records: Record<string, any>[] = [];
  private nextID = 1;
  failUpdates = false;
  async filter(query: Record<string, unknown>, _sort?: string, limit = 100, skip = 0) {
    return this.records.filter((row) => Object.entries(query).every(([key, value]) => {
      if (value && typeof value === "object" && "$exists" in value) return (key in row) === value.$exists;
      return row[key] === value;
    })).slice(skip, skip + limit).map((row) => ({ ...row }));
  }
  async create(data: Record<string, unknown>) {
    const row = { id: "fixture-" + this.nextID++, created_date: new Date().toISOString(), ...data };
    this.records.push(row);
    return { ...row };
  }
  async updateMany(query: Record<string, unknown>, update: { $set: Record<string, unknown> }) {
    if (this.failUpdates) throw new Error("Synthetic storage outage");
    const matches = await this.filter(query);
    const ids = new Set(matches.map((row) => row.id));
    this.records = this.records.map((row) => ids.has(row.id) ? { ...row, ...update.$set } : row);
    return { success: true, updated: ids.size, has_more: false };
  }
  async delete(id: string) {
    this.records = this.records.filter((row) => row.id !== id);
    return { success: true };
  }
}

export type Fixture = {
  user: { id: string; email: string; [key: string]: unknown };
  registered: boolean;
  rejectUserToken: boolean;
  provisionVisible: boolean;
  invites: { email: string; role: string }[];
  clients: Record<string, unknown>[];
  credentials: MemoryStore;
  lifecycle: MemoryStore;
};
export let fixture: Fixture;
export function resetFixture(overrides: Partial<Fixture> = {}) {
  fixture = {
    user: { id: "verified-user-178", email: "verified@example.test" }, registered: true,
    rejectUserToken: false, provisionVisible: true, invites: [], clients: [],
    credentials: new MemoryStore(), lifecycle: new MemoryStore(), ...overrides,
  };
}
export function createClient(config: Record<string, unknown>): any {
  fixture.clients.push(config);
  if (config.appId !== "69a0e57fa939f578082f8091" || config.serverUrl !== "https://base44.app") {
    throw new Error("Noncanonical SDK destination");
  }
  if (config.token === "fixture-service-token") {
    return {
      entities: { AppleSignInCredential: fixture.credentials, BillingIdentityLifecycle: fixture.lifecycle },
      users: { async inviteUser(email: string, role: string) {
        fixture.invites.push({ email, role });
        if (fixture.provisionVisible) fixture.registered = true;
      } },
    };
  }
  return { auth: { async me() {
    if (fixture.rejectUserToken || config.token !== "fixture-user-token") {
      throw { status: 401 };
    }
    if (!fixture.registered) throw {
      status: 403, data: { extra_data: { reason: "user_not_registered", email: fixture.user.email } },
    };
    return { ...fixture.user };
  } } };
}
