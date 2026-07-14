export type EntitlementRecord = {
  id?: string;
  source_key?: string;
  status?: string;
  expires_at?: string;
  provider_event_at?: string;
  last_verified_at?: string;
  created_date?: string;
};

const GRANTING_STATUSES = new Set(["active", "trialing", "grace_period"]);

function freshness(record: EntitlementRecord): number {
  for (const value of [
    record.provider_event_at,
    record.last_verified_at,
    record.created_date,
  ]) {
    const timestamp = Date.parse(value || "");
    if (Number.isFinite(timestamp)) return timestamp;
  }
  return Number.NEGATIVE_INFINITY;
}

export function hasActiveMembership(
  records: EntitlementRecord[],
  now = new Date(),
): boolean {
  const canonical = new Map<string, EntitlementRecord>();
  const unkeyed: EntitlementRecord[] = [];
  for (const record of records) {
    const key = record.source_key || record.id;
    if (!key) {
      unkeyed.push(record);
      continue;
    }
    const current = canonical.get(key);
    if (!current || freshness(record) > freshness(current)) {
      canonical.set(key, record);
    }
  }

  return [...canonical.values(), ...unkeyed].some((record) => {
    if (!GRANTING_STATUSES.has(String(record.status || ""))) return false;
    const expiry = Date.parse(record.expires_at || "");
    return Number.isFinite(expiry) && expiry > now.getTime();
  });
}
