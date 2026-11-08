// Models the observed Base44 contract: unknown filter fields produce HTTP 400,
// and writes discard properties absent from the published entity schema.
type Row = Record<string, any>;
type Schema = { name?: string; properties?: Record<string, any> };
const builtins = new Set([
  "id",
  "created_date",
  "updated_date",
  "created_by",
  "created_by_id",
]);
export const canonical: Record<string, Schema> = {};
for await (
  const file of Deno.readDir(new URL("../../entities/", import.meta.url))
) {
  if (!file.isFile || !file.name.endsWith(".jsonc")) continue;
  const schema = JSON.parse(
    await Deno.readTextFile(
      new URL(`../../entities/${file.name}`, import.meta.url),
    ),
  );
  canonical[schema.name] = schema;
}
const observed = JSON.parse(
  await Deno.readTextFile(new URL("./live-four-schemas.json", import.meta.url)),
);
const repairFields: Record<string, string[]> = JSON.parse(
  await Deno.readTextFile(
    new URL(
      "../../../QA/deck-loading-400-20261108/fields.json",
      import.meta.url,
    ),
  ),
);
export const fixture: {
  user: Row;
  schemas: Record<string, Schema>;
  stores: Record<string, Store>;
  calls: { entity: string; operation: string; query?: Row; skip?: number }[];
} = { user: {}, schemas: {}, stores: {}, calls: [] };

export function resetFixture(repaired = false) {
  fixture.schemas = structuredClone({ ...canonical, ...observed });
  if (repaired) {
    for (const [name, fields] of Object.entries(repairFields)) {
      for (const field of fields) {
        fixture.schemas[name].properties![field] = structuredClone(
          canonical[name].properties![field],
        );
      }
    }
  }
  fixture.stores = {};
  fixture.calls = [];
  fixture.user = {
    id: "fixture-user",
    email: "fixture@example.test",
    display_name: "Fixture",
    spy_id: "123-456",
  };
  entity("User").rows = [structuredClone(fixture.user)];
}

function known(name: string, key: string) {
  if (builtins.has(key)) return true;
  if (name === "User" && ["email", "full_name", "role"].includes(key)) {
    return true;
  }
  return Object.hasOwn(
    fixture.schemas[name]?.properties || {},
    key.split(".")[0],
  );
}
function requireFilter(name: string, query: Row) {
  for (const [key, value] of Object.entries(query)) {
    if (["$or", "$and"].includes(key)) {
      for (const branch of value) requireFilter(name, branch);
    } else if (!known(name, key)) {
      throw Object.assign(new Error("Request failed with status code 400"), {
        status: 400,
        data: {
          error: {
            code: "unknown_filter_field",
            message: `Unknown field ${key}`,
            details: { field: key, entity: name },
          },
        },
      });
    }
  }
}
function matches(row: Row, query: Row): boolean {
  return Object.entries(query).every(([key, wanted]) => {
    if (key === "$and") return wanted.every((q: Row) => matches(row, q));
    if (key === "$or") return wanted.some((q: Row) => matches(row, q));
    const actual = key.split(".").reduce((v, part) => v?.[part], row);
    if (
      wanted !== null && typeof wanted === "object" && !Array.isArray(wanted)
    ) {
      return Object.entries(wanted).every(([op, value]: [string, any]) => {
        if (op === "$exists") return (actual !== undefined) === value;
        if (op === "$lt") return actual < value;
        if (op === "$lte") return actual <= value;
        if (op === "$gt") return actual > value;
        if (op === "$gte") return actual >= value;
        if (op === "$ne") return actual !== value;
        if (op === "$in") return value.includes(actual);
        throw new Error(`Unsupported fixture query operator ${op}`);
      });
    }
    return Array.isArray(actual) ? actual.includes(wanted) : actual === wanted;
  });
}
export class Store {
  rows: Row[] = [];
  constructor(readonly name: string) {}
  private persisted(data: Row) {
    return structuredClone(
      Object.fromEntries(
        Object.entries(data).filter(([key]) => known(this.name, key)),
      ),
    );
  }
  async filter(query: Row, sort = "created_date", limit = 100, skip = 0) {
    fixture.calls.push({
      entity: this.name,
      operation: "filter",
      query: structuredClone(query),
      skip,
    });
    requireFilter(this.name, query);
    const field = sort.replace(/^-/, "");
    const direction = sort.startsWith("-") ? -1 : 1;
    const rows = this.rows.filter((row) => matches(row, query)).sort((a, b) =>
      String(a[field] ?? "").localeCompare(String(b[field] ?? "")) * direction
    );
    return structuredClone(rows.slice(skip, skip + limit));
  }
  list(sort?: string, limit?: number, skip?: number) {
    return this.filter({}, sort, limit, skip);
  }
  async get(id: string) {
    return structuredClone(this.rows.find((row) => row.id === id) || null);
  }
  async create(data: Row) {
    fixture.calls.push({ entity: this.name, operation: "create" });
    const row = {
      id: crypto.randomUUID(),
      created_date: new Date().toISOString(),
      updated_date: new Date().toISOString(),
      ...this.persisted(data),
    };
    this.rows.push(row);
    return structuredClone(row);
  }
  async update(id: string, data: Row) {
    const row = this.rows.find((r) => r.id === id);
    if (!row) throw new Error(`Missing fixture ${this.name} row ${id}`);
    Object.assign(row, this.persisted(data), {
      updated_date: new Date().toISOString(),
    });
    return structuredClone(row);
  }
  async updateMany(query: Row, update: Row) {
    requireFilter(this.name, query);
    const rows = this.rows.filter((row) => matches(row, query));
    for (const row of rows) {
      Object.assign(row, this.persisted(update.$set || {}));
      for (const [key, value] of Object.entries(update.$inc || {})) {
        if (known(this.name, key)) row[key] = (row[key] || 0) + Number(value);
      }
      for (const key of Object.keys(update.$unset || {})) delete row[key];
      row.updated_date = new Date().toISOString();
    }
    return { updated: rows.length };
  }
  async delete(id: string) {
    this.rows = this.rows.filter((r) => r.id !== id);
    return { success: true };
  }
}
export function entity(name: string): Store {
  if (!fixture.schemas[name]) {
    throw new Error(`Undeclared fixture entity ${name}`);
  }
  return fixture.stores[name] ||= new Store(name);
}
export function createClient(_config: unknown): any {
  return { auth: { me: async () => structuredClone(fixture.user) } };
}
export function createClientFromRequest(_request: Request): any {
  return {
    auth: { me: async () => structuredClone(fixture.user) },
    asServiceRole: {
      entities: new Proxy({}, { get: (_target, name) => entity(String(name)) }),
      functions: {
        invoke: () => {
          throw new Error("Unexpected outbound function call");
        },
      },
    },
  };
}
