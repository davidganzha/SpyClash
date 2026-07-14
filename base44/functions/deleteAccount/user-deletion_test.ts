import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { deleteUserRecord, UserDeletionFailure } from "./user-deletion.ts";

Deno.test("successful User delete needs no confirmation read", async () => {
  let filterCalls = 0;
  await deleteUserRecord({
    delete: () => Promise.resolve(),
    filter: () => {
      filterCalls += 1;
      return Promise.resolve([]);
    },
  }, "user-1");

  assertEquals(filterCalls, 0);
});

Deno.test("lost User delete response is reconciled as committed", async () => {
  await deleteUserRecord({
    delete: () => Promise.reject(new Error("response lost")),
    filter: () => Promise.resolve([]),
  }, "user-1");
});

Deno.test("confirmed surviving User record requests deletion retry", async () => {
  const error = await assertRejects(
    () =>
      deleteUserRecord({
        delete: () => Promise.reject(new Error("delete rejected")),
        filter: () => Promise.resolve([{ id: "user-1" }]),
      }, "user-1"),
    UserDeletionFailure,
  );

  assertEquals(error.code, "confirmed_present");
});

Deno.test("unreadable User state remains privacy-safe and ambiguous", async () => {
  const error = await assertRejects(
    () =>
      deleteUserRecord({
        delete: () => Promise.reject(new Error("response lost")),
        filter: () => Promise.reject(new Error("read unavailable")),
      }, "user-1"),
    UserDeletionFailure,
  );

  assertEquals(error.code, "ambiguous");
});
