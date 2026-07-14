import { assertEquals } from "jsr:@std/assert@1";
import { deletionFailureDisposition } from "./deletion-state-machine.ts";

Deno.test("failure before content cleanup may restore a live account", () => {
  assertEquals(
    deletionFailureDisposition(false),
    "rollback_before_cleanup",
  );
});

Deno.test("failure after any content cleanup retains deleting for idempotent retry", () => {
  assertEquals(
    deletionFailureDisposition(true),
    "retain_deleting_for_retry",
  );
});
