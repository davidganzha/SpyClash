import { hasActiveMembership } from "./membership-guard.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("purchase guard uses the newest row for each provider source", () => {
  const records = [
    {
      id: "old",
      source_key: "stripe:sub_123",
      status: "active",
      expires_at: "2026-07-20T12:00:00Z",
      provider_event_at: "2026-07-13T12:00:00Z",
    },
    {
      id: "new",
      source_key: "stripe:sub_123",
      status: "canceled",
      expires_at: "2026-07-20T12:00:00Z",
      provider_event_at: "2026-07-13T13:00:00Z",
    },
  ];
  assert(
    !hasActiveMembership(records, new Date("2026-07-13T14:00:00Z")),
    "stale duplicate incorrectly blocked a new purchase",
  );
});

Deno.test("purchase guard blocks any current Apple or Stripe grant", () => {
  assert(
    hasActiveMembership([{
      source_key: "apple:original-123",
      status: "grace_period",
      expires_at: "2026-07-20T12:00:00Z",
    }], new Date("2026-07-13T14:00:00Z")),
    "active provider grant did not block a second purchase",
  );
});
