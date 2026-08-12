import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  announcementCopy,
  decodeCursor,
  encodeCursor,
  language,
  localizedAnnouncement,
  optionalActionDeepLink,
  requireRequestID,
} from "./contracts.ts";

Deno.test("announcement input is bounded plain text with complete translations", () => {
  assertEquals(
    requireRequestID("123e4567-e89b-42d3-a456-426614174000"),
    "123e4567-e89b-42d3-a456-426614174000",
  );
  assertEquals(announcementCopy({ title_en: "Build 29", body_en: "Ready" }), {
    title_en: "Build 29",
    body_en: "Ready",
    title_ru: "",
    body_ru: "",
    title_es: "",
    body_es: "",
    title_uk: "",
    body_uk: "",
  });
  assertThrows(() =>
    announcementCopy({
      title_en: "<b>Unsafe</b>",
      body_en: "Body",
    })
  );
  assertThrows(() =>
    announcementCopy({
      title_en: "Title",
      body_en: "Body",
      title_ru: "Заголовок",
    })
  );
  assertThrows(() =>
    announcementCopy({
      title_en: "Title",
      body_en: "Body",
      title_uk: "Заголовок",
    })
  );
});

Deno.test("Ukrainian locale is normalized and localized independently", () => {
  assertEquals(language("uk-UA"), "uk");
  assertEquals(language("uk_UA"), "uk");
  assertEquals(
    localizedAnnouncement({
      title_en: "Title",
      body_en: "Body",
      title_uk: "Заголовок",
      body_uk: "Текст",
    }, "uk-UA"),
    { title: "Заголовок", body: "Текст" },
  );
});

Deno.test("notification cursor is opaque and deep links stay inside SpyClash", () => {
  const cursor = encodeCursor("2026-07-27T12:00:00.000Z", "global:one");
  assertEquals(decodeCursor(cursor), [
    "2026-07-27T12:00:00.000Z",
    "global:one",
  ]);
  assertEquals(
    optionalActionDeepLink("spyclash://notifications?id=one"),
    "spyclash://notifications?id=one",
  );
  assertThrows(() => optionalActionDeepLink("https://phishing.example"));
});
