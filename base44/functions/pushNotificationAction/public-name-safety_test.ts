import { assertEquals } from "jsr:@std/assert@1";
import { safePushActorName } from "./public-name-safety.ts";

Deno.test("push actor names reject objectionable variants at the projection boundary", () => {
  assertEquals(safePushActorName("  Signal   Raven  "), "Signal Raven");
  for (
    const value of [
      "ZALUPA",
      "ЗАЛУПА",
      "zalup",
      "залуп",
      "za.lu-pa",
      "za lu pa",
      "zal upa",
      "zal u p a",
      "за лу па",
      "zаlupa",
      "3a1up4",
      "zаluрa",
      "z@lup@",
      "za|upa",
      "z a l u p a",
      "з а л у п а",
      "z4lup4",
      "f.u.c.k",
      "k1ll yourself",
    ]
  ) {
    assertEquals(safePushActorName(value), "An operative");
  }
  assertEquals(safePushActorName("Pizza Lupin"), "Pizza Lupin");
});
