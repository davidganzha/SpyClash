import { assertEquals } from "jsr:@std/assert@1";
import {
  CASADA_BENEFITS,
  CASADA_COMPATIBILITY_EXPIRY,
  casadaCheckoutRetirement,
} from "./casada-checkout.ts";

Deno.test("CASADA retires checkout before any billing provider call", () => {
  const retirement = casadaCheckoutRetirement();
  assertEquals(retirement?.status, 409);
  assertEquals(retirement?.body, {
    error: "Full access is already included. Checkout is not required.",
    code: "casada_checkout_retired",
    active: true,
    tier: "limitless",
    protocol: "casada",
    providers: ["casada"],
    expires_at: CASADA_COMPATIBILITY_EXPIRY,
    benefits: CASADA_BENEFITS,
    checkout_required: false,
  });
  assertEquals(
    retirement?.body.error.toLowerCase().includes("casada"),
    false,
  );
});
