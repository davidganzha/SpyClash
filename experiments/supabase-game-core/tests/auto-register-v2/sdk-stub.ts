export const SUPPORT_ACCESS_DENIED = "You need to access this app through the support panel first. Please go to the support panel and click on a ticket for this app to grant temporary access.";

export function sdkError(status: number, message: string) {
  return Object.assign(new Error(message), {
    name: "Base44Error", status, data: { detail: message },
  });
}

type StoreName = "AppleSignInCredential" | "BillingIdentityLifecycle";
type StoreCall = { store: StoreName; operation: "filter" | "create" | "updateMany" | "delete" };

export class MemoryStore {
  records: Record<string, any>[] = [];
  private nextID = 1;
  failUpdates = false;
  filterFaults: unknown[] = [];
  persistentFilterFault: unknown;
  filterCalls = 0;
  updateManyCalls = 0;
  afterUpdateMany?: (query: Record<string, unknown>, update: { $set: Record<string, unknown> }) => void;
  constructor(private readonly name: StoreName = "AppleSignInCredential") {}
  private matching(query: Record<string, unknown>, limit = 100, skip = 0) {
    return this.records.filter((row) => Object.entries(query).every(([key, value]) => {
      if (value && typeof value === "object" && "$exists" in value) return (key in row) === value.$exists;
      return row[key] === value;
    })).slice(skip, skip + limit).map((row) => ({ ...row }));
  }
  async filter(query: Record<string, unknown>, _sort?: string, limit = 100, skip = 0) {
    this.filterCalls++;
    fixture.serviceCalls.push({ store: this.name, operation: "filter" });
    const fault = this.filterFaults.length ? this.filterFaults.shift() : this.persistentFilterFault;
    if (fault !== undefined) throw fault;
    return this.matching(query, limit, skip);
  }
  async create(data: Record<string, unknown>) {
    fixture.serviceCalls.push({ store: this.name, operation: "create" });
    const row = { id: "fixture-" + this.nextID++, created_date: new Date().toISOString(), ...data };
    this.records.push(row);
    return { ...row };
  }
  async updateMany(query: Record<string, unknown>, update: { $set: Record<string, unknown> }) {
    this.updateManyCalls++;
    fixture.serviceCalls.push({ store: this.name, operation: "updateMany" });
    if (this.failUpdates) throw new Error("Synthetic storage outage");
    // The SDK sends one PATCH; its backend match is not another SDK filter.
    const matches = this.matching(query);
    const ids = new Set(matches.map((row) => row.id));
    this.records = this.records.map((row) => ids.has(row.id) ? { ...row, ...update.$set } : row);
    this.afterUpdateMany?.(query, update);
    return { success: true, updated: ids.size, has_more: false };
  }
  async delete(id: string) {
    fixture.serviceCalls.push({ store: this.name, operation: "delete" });
    this.records = this.records.filter((row) => row.id !== id);
    return { success: true };
  }
}

export type Fixture = {
  user: { id: string; email: string; [key: string]: unknown };
  registered: boolean;
  rejectUserToken: boolean;
  userAuthError?: unknown;
  userAuthCalls: number;
  provisionVisible: boolean;
  invites: { email: string; role: string }[];
  clients: Record<string, unknown>[];
  serviceCalls: StoreCall[];
  credentials: MemoryStore;
  lifecycle: MemoryStore;
};
export let fixture: Fixture;
export function resetFixture(overrides: Partial<Fixture> = {}) {
  fixture = {
    user: { id: "verified-user-178", email: "verified@example.test" }, registered: true,
    rejectUserToken: false, userAuthCalls: 0, provisionVisible: true, invites: [], clients: [], serviceCalls: [],
    credentials: new MemoryStore("AppleSignInCredential"), lifecycle: new MemoryStore("BillingIdentityLifecycle"), ...overrides,
  };
}
export function resetStoreObservations() {
  fixture.serviceCalls = [];
  for (const store of [fixture.credentials, fixture.lifecycle]) {
    store.filterCalls = 0;
    store.updateManyCalls = 0;
  }
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
    fixture.userAuthCalls++;
    if (fixture.userAuthError !== undefined) throw fixture.userAuthError;
    if (fixture.rejectUserToken || config.token !== "fixture-user-token") {
      throw { status: 401 };
    }
    if (!fixture.registered) throw {
      status: 403, data: { extra_data: { reason: "user_not_registered", email: fixture.user.email } },
    };
    return { ...fixture.user };
  } } };
}
