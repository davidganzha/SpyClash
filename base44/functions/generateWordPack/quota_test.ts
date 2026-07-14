import {
  canonicalQuotaRecord,
  normalizedQuotaCount,
  quotaKey,
  totalQuotaUsage,
  utcUsageDate,
} from "./quota.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("quota keys are scoped to authenticated user and UTC date", () => {
  const now = new Date("2026-07-13T23:59:59Z");
  assert(utcUsageDate(now) === "2026-07-13", "UTC usage date drifted");
  assert(
    quotaKey("user-123", now) === "user-123:2026-07-13",
    "quota key drifted",
  );
});

Deno.test("duplicate quota rows are summed fail-closed", () => {
  const usage = totalQuotaUsage([
    { generations_used: 4 },
    { generations_used: 3 },
    { generations_used: -100 },
    { generations_used: Number.NaN },
  ]);
  assert(usage === 7, "duplicate rows reduced or reset authoritative usage");
  assert(
    normalizedQuotaCount("9.9") === 9,
    "quota count normalization drifted",
  );
});

Deno.test("canonical quota record is deterministic", () => {
  const canonical = canonicalQuotaRecord([
    { id: "new", created_date: "2026-07-13T12:00:01Z" },
    { id: "old", created_date: "2026-07-13T12:00:00Z" },
  ]);
  assert(canonical?.id === "old", "oldest quota record must remain canonical");
});

Deno.test("canonical quota record breaks identical timestamps by id", () => {
  const timestamp = "2026-07-13T12:00:00Z";
  const forward = canonicalQuotaRecord([
    { id: "row-b", created_date: timestamp },
    { id: "row-a", created_date: timestamp },
  ]);
  const reverse = canonicalQuotaRecord([
    { id: "row-a", created_date: timestamp },
    { id: "row-b", created_date: timestamp },
  ]);
  assert(forward?.id === "row-a", "forward order selected a different CAS row");
  assert(reverse?.id === "row-a", "reverse order selected a different CAS row");
});
