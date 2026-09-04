import { publishMembershipSignal } from "./membership-signal.ts";
function assert(value: unknown) {
  if (!value) throw new Error("assertion failed");
}
Deno.test("membership realtime hint contains no billing data and uses the owner lease", async () => {
  let guarded = false;
  let written: Record<string, unknown> = {};
  const store = {
    filter: () => Promise.resolve([{ id: "existing" }]),
    update: (_id: string, hint: Record<string, unknown>) => {
      assert(guarded);
      written = hint;
      return Promise.resolve(hint);
    },
  };
  assert(
    await publishMembershipSignal({
      store,
      userID: "owner",
      beforePersist: async () => {
        guarded = true;
      },
    }),
  );
  assert(written.user_id === "owner");
  assert(Object.keys(written).sort().join(",") === "change_id,user_id");
});
Deno.test("membership signal never writes after the deletion lease changes", async () => {
  let writes = 0;
  const store = {
    filter: () => Promise.resolve([]),
    create: () => {
      writes++;
    },
  };
  assert(
    !await publishMembershipSignal({
      store,
      userID: "owner",
      beforePersist: async () => {
        throw new Error("deleting");
      },
    }),
  );
  assert(writes === 0);
});
Deno.test("a missed realtime hint cannot undo a verified purchase", async () => {
  const store = { filter: () => Promise.reject(new Error("offline")) };
  assert(
    !await publishMembershipSignal({
      store,
      userID: "owner",
      beforePersist: async () => {},
    }),
  );
});
