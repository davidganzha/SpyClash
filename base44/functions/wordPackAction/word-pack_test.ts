import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  ownsWordPack,
  uniqueWordPacks,
  wordPackForClient,
  wordPackWritePayload,
} from "./word-pack.ts";

Deno.test("word pack ownership prefers stable user id and falls back only for legacy rows", () => {
  const user = { id: "user-1", email: "Agent@Example.com" };
  assertEquals(
    ownsWordPack(
      { owner_user_id: "user-1", owner_email: "old@example.com" },
      user,
    ),
    true,
  );
  assertEquals(
    ownsWordPack(
      { owner_user_id: "other", owner_email: "agent@example.com" },
      user,
    ),
    false,
  );
  assertEquals(ownsWordPack({ owner_email: "agent@example.com" }, user), true);
});

Deno.test("word pack writes override forged ownership and reject objectionable content", () => {
  assertEquals(
    wordPackWritePayload(
      {
        name: "Cinema",
        category: "Movies",
        words: ["Alien", "Arrival", "Alien"],
        owner_user_id: "attacker",
        owner_email: "attacker@example.com",
        is_public: true,
      },
      { id: "user-1", email: "owner@example.com" },
    ),
    {
      name: "Cinema",
      category: "Movies",
      words: ["Alien", "Arrival"],
      owner_user_id: "user-1",
      owner_email: "owner@example.com",
      is_public: false,
    },
  );
  assertThrows(() =>
    wordPackWritePayload(
      { name: "Cinema", words: ["Alien", "k1ll yourself"] },
      { id: "user-1", email: "owner@example.com" },
    )
  );
});

Deno.test("word pack projections are bounded and duplicate ids are removed", () => {
  const records = uniqueWordPacks([
    { id: "a", name: "A" },
    { id: "a", name: "forged duplicate" },
    { id: "b", name: "B" },
  ]);
  assertEquals(records.length, 2);
  assertEquals(
    wordPackForClient({
      id: "a",
      name: " A ",
      category: " Test ",
      words: [" One ", "", null],
      owner_email: "owner@example.com",
      owner_user_id: "hidden",
      secret: "hidden",
    }),
    {
      id: "a",
      name: "A",
      category: "Test",
      words: ["One"],
      owner_email: "owner@example.com",
      is_public: false,
      created_date: "",
      updated_date: "",
    },
  );
});
