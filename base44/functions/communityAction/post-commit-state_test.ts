import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { loadPostCommitState } from "./post-commit-state.ts";

Deno.test("post-commit projection retries reads without replaying the mutation", async () => {
  let loads = 0;
  const delays: number[] = [];

  const state = await loadPostCommitState({
    load: () => {
      loads += 1;
      if (loads < 3) throw new Error("brief read failure");
      return Promise.resolve({ status: "accepted" });
    },
    delay: (milliseconds) => {
      delays.push(milliseconds);
      return Promise.resolve();
    },
  });

  assertEquals(state, { status: "accepted" });
  assertEquals(loads, 3);
  assertEquals(delays, [75, 225]);
});

Deno.test("post-commit projection preserves the final read failure", async () => {
  const expected = new Error("projection unavailable");
  const error = await assertRejects(() =>
    loadPostCommitState({
      load: () => Promise.reject(expected),
      delay: () => Promise.resolve(),
    })
  );
  assertEquals(error, expected);
});
