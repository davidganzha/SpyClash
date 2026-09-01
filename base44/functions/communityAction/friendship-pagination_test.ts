import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  filterAllFriendships,
  FRIENDSHIP_MAX_PAGES,
  FRIENDSHIP_PAGE_SIZE,
} from "./friendship-pagination.ts";

type Entity = Record<string, unknown>;

function friendship(id: string, status = "accepted"): Entity {
  return {
    id,
    requester_id: "user-a",
    addressee_id: "user-b",
    status,
  };
}

Deno.test("Friendship pagination drains every page with stable deduplication", async () => {
  const firstPage = Array.from(
    { length: FRIENDSHIP_PAGE_SIZE },
    (_, index) => friendship(`friend-${String(index + 100).padStart(3, "0")}`),
  );
  const duplicate = { ...firstPage[50] };
  const calls: Array<Record<string, unknown>> = [];
  const result = await filterAllFriendships(
    {
      filter: (query, sort, limit, skip) => {
        calls.push({ query, sort, limit, skip });
        return Promise.resolve(
          skip === 0 ? firstPage : [duplicate, friendship("friend-050")],
        );
      },
    },
    { requester_id: "user-a" },
  );

  assertEquals(calls, [{
    query: { requester_id: "user-a" },
    sort: "id",
    limit: FRIENDSHIP_PAGE_SIZE,
    skip: 0,
  }, {
    query: { requester_id: "user-a" },
    sort: "id",
    limit: FRIENDSHIP_PAGE_SIZE,
    skip: FRIENDSHIP_PAGE_SIZE,
  }]);
  assertEquals(result.length, FRIENDSHIP_PAGE_SIZE + 1);
  assertEquals(result[0].id, "friend-050");
  assertEquals(result.at(-1)?.id, "friend-199");
});

Deno.test("Friendship pagination fails closed on invalid or conflicting pages", async () => {
  const invalidPages: unknown[] = [
    null,
    {},
    Array.from(
      { length: FRIENDSHIP_PAGE_SIZE + 1 },
      (_, index) => friendship(`oversized-${index}`),
    ),
    [null],
    [{ requester_id: "user-a" }],
  ];
  for (const page of invalidPages) {
    const error = await assertRejects(
      () =>
        filterAllFriendships(
          { filter: () => Promise.resolve(page) },
          { requester_id: "user-a" },
        ),
      Error,
    );
    assertEquals((error as Error & { status?: number }).status, 503);
  }

  let calls = 0;
  const error = await assertRejects(
    () =>
      filterAllFriendships(
        {
          filter: () => {
            calls += 1;
            if (calls === 1) {
              return Promise.resolve([
                friendship("shared", "accepted"),
                ...Array.from(
                  { length: FRIENDSHIP_PAGE_SIZE - 1 },
                  (_, index) => friendship(`first-${index}`),
                ),
              ]);
            }
            return Promise.resolve([friendship("shared", "blocked")]);
          },
        },
        { requester_id: "user-a" },
      ),
    Error,
    "conflicting record id shared",
  );
  assertEquals((error as Error & { status?: number }).status, 503);
});

Deno.test("Friendship pagination fails closed at its page ceiling", async () => {
  let calls = 0;
  const error = await assertRejects(
    () =>
      filterAllFriendships(
        {
          filter: (_query, _sort, limit, skip) => {
            calls += 1;
            return Promise.resolve(
              Array.from(
                { length: limit },
                (_, index) => friendship(`friend-${skip + index}`),
              ),
            );
          },
        },
        { requester_id: "user-a" },
      ),
    Error,
    `${FRIENDSHIP_MAX_PAGES}-page safety ceiling`,
  );
  assertEquals((error as Error & { status?: number }).status, 503);
  assertEquals(calls, FRIENDSHIP_MAX_PAGES);
});
