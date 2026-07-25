import { assertEquals } from "jsr:@std/assert@1";
import { isAdminAutomationUser, scheduledDrainArgs } from "./worker-auth.ts";

Deno.test("scheduled drain only accepts the automation body shape", () => {
  assertEquals(scheduledDrainArgs({ action: "drain" }), null);
  assertEquals(scheduledDrainArgs({ args: { action: "process_event" } }), null);
  assertEquals(scheduledDrainArgs({ args: { action: "drain", limit: 12 } }), {
    action: "drain",
    limit: 12,
  });
});

Deno.test("scheduled drain requires the automation creator to be an admin", () => {
  assertEquals(isAdminAutomationUser(null), false);
  assertEquals(isAdminAutomationUser({ id: "user-1", role: "user" }), false);
  assertEquals(isAdminAutomationUser({ id: "admin-1", role: "admin" }), true);
});
