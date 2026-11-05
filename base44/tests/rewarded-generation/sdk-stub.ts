class Store {
  rows: any[] = [];
  matches(row: any, query: any) {
    return Object.entries(query).every(([key, value]: any) => {
      if (value && typeof value === "object") {
        if ("$exists" in value) return (key in row) === value.$exists;
        if ("$lt" in value) return row[key] < value.$lt;
        if ("$lte" in value) return row[key] <= value.$lte;
        if ("$in" in value) return value.$in.includes(row[key]);
      }
      return row[key] === value;
    });
  }
  async filter(query: any, _sort?: string, limit = 100, skip = 0) {
    return structuredClone(
      this.rows.filter((row) => this.matches(row, query)).slice(
        skip,
        skip + limit,
      ),
    );
  }
  async create(data: any) {
    const row = {
      id: crypto.randomUUID(),
      created_date: new Date().toISOString(),
      ...data,
    };
    this.rows.push(row);
    return structuredClone(row);
  }
  async update(id: string, data: any) {
    const row = this.rows.find((r) => r.id === id);
    if (row) Object.assign(row, data);
    return row || { id, ...data };
  }
  async updateMany(query: any, update: any) {
    const rows = this.rows.filter((row) => this.matches(row, query));
    for (const row of rows) {
      Object.assign(row, update.$set || {});
      for (const [key, value] of Object.entries(update.$inc || {})) {
        row[key] = (row[key] || 0) + Number(value);
      }
    }
    return { updated: rows.length };
  }
  async delete(id: string) {
    this.rows = this.rows.filter((r) => r.id !== id);
    return { success: true };
  }
}
export const fixture: {
  user: any;
  stores: Record<string, Store>;
  calls: number;
  fail: string | null;
} = {
  user: { id: "fixture-user", email: "fixture@example.test" },
  stores: {},
  calls: 0,
  fail: null,
};
export function resetFixture() {
  fixture.stores = {};
  fixture.calls = 0;
  fixture.fail = null;
  fixture.user = { id: "fixture-user", email: "fixture@example.test" };
}
export function entity(name: string): Store {
  return fixture.stores[name] ||= new Store();
}
export function createClientFromRequest(_request: Request): any {
  return {
    auth: { me: async () => fixture.user },
    asServiceRole: {
      entities: new Proxy({}, { get: (_target, name) => entity(String(name)) }),
    },
    integrations: {
      Core: {
        InvokeLLM: async () => {
          fixture.calls++;
          if (fixture.fail === "timeout") {
            throw Object.assign(new Error("request timed out"), {
              name: "TimeoutError",
            });
          }
          if (fixture.fail === "quality") {
            return {
              words: [],
              exhausted: false,
            };
          }
          return {
            draft_words: ["Apple", "Banana", "Pear", "Peach", "Plum"],
            accepted_indices: [0, 1, 2, 3, 4],
            replacement_words: [],
            accepted_replacement_indices: [],
            category: "Fruit",
            exhausted: false,
          };
        },
      },
    },
  };
}
