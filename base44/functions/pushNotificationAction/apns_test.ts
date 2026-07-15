import { assertEquals } from "jsr:@std/assert@1";
import { sendAlertPush, sendLiveActivityPush } from "./apns.ts";

Deno.test("local APNs topic misconfiguration never revokes valid client tokens", async () => {
  const previous = Deno.env.get("APNS_TOPIC");
  Deno.env.set("APNS_TOPIC", "com.example.wrong-topic");
  try {
    const common = {
      token: "ab".repeat(32),
      environment: "sandbox" as const,
      bundleID: "com.spyclash.app",
      collapseID: "test",
      expiration: 0,
      payload: { aps: {} },
    };
    const alert = await sendAlertPush(common);
    const activity = await sendLiveActivityPush(common);
    assertEquals(alert, {
      delivered: false,
      retryable: true,
      invalidateToken: false,
      reason: "topic_mismatch",
    });
    assertEquals(activity, alert);
  } finally {
    if (previous === undefined) Deno.env.delete("APNS_TOPIC");
    else Deno.env.set("APNS_TOPIC", previous);
  }
});
