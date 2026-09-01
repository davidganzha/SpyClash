import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  filterAllRoomInvites,
  loadIncomingRoomInvites,
  ROOM_INVITE_MAX_PAGES,
  ROOM_INVITE_PAGE_SIZE,
  ROOM_INVITE_RESULT_LIMIT,
} from "./room-invite-pagination.ts";

type Entity = Record<string, unknown>;

function invite(
  id: string,
  status = "pending",
  senderUserID = "user-a",
  createdAt = "2026-09-01T00:00:00.000Z",
): Entity {
  return {
    id,
    sender_user_id: senderUserID,
    recipient_user_id: "user-b",
    status,
    room_id: "room-1",
    room_code: "ALPHA1",
    created_at: createdAt,
  };
}

Deno.test("RoomInvite pagination drains every page with stable deduplication", async () => {
  const firstPage = Array.from(
    { length: ROOM_INVITE_PAGE_SIZE },
    (_, index) => invite(`invite-${String(index + 100).padStart(3, "0")}`),
  );
  const duplicate = { ...firstPage[50] };
  const calls: Array<Record<string, unknown>> = [];
  const result = await filterAllRoomInvites(
    {
      filter: (query, sort, limit, skip) => {
        calls.push({ query, sort, limit, skip });
        return Promise.resolve(
          skip === 0 ? firstPage : [duplicate, invite("invite-050")],
        );
      },
    },
    { recipient_user_id: "user-b", status: "pending" },
  );

  assertEquals(calls, [{
    query: { recipient_user_id: "user-b", status: "pending" },
    sort: "id",
    limit: ROOM_INVITE_PAGE_SIZE,
    skip: 0,
  }, {
    query: { recipient_user_id: "user-b", status: "pending" },
    sort: "id",
    limit: ROOM_INVITE_PAGE_SIZE,
    skip: ROOM_INVITE_PAGE_SIZE,
  }]);
  assertEquals(result.length, ROOM_INVITE_PAGE_SIZE + 1);
  assertEquals(result[0].id, "invite-050");
  assertEquals(result.at(-1)?.id, "invite-199");
});

Deno.test("incoming RoomInvite loading crosses page 50 and filters non-friends", async () => {
  const records = [
    ...Array.from(
      { length: ROOM_INVITE_PAGE_SIZE },
      (_, index) =>
        invite(
          `non-friend-${String(index).padStart(3, "0")}`,
          "pending",
          `stranger-${index}`,
          `2026-08-31T23:${String(index % 60).padStart(2, "0")}:00.000Z`,
        ),
    ),
    invite(
      "visible-after-first-page",
      "accepted",
      "friend-a",
      "2026-09-01T01:00:00.000Z",
    ),
  ];
  const calls: Array<Record<string, unknown>> = [];
  const result = await loadIncomingRoomInvites(
    {
      filter: (query, sort, limit, skip) => {
        calls.push({ query, sort, limit, skip });
        return Promise.resolve(records.slice(skip, skip + limit));
      },
    },
    "user-b",
    [{
      id: "friendship-a",
      requester_id: "friend-a",
      addressee_id: "user-b",
      status: "accepted",
    }],
  );

  assertEquals(calls.map((call) => call.query), [
    {
      recipient_user_id: "user-b",
      status: ["pending", "accepted"],
    },
    {
      recipient_user_id: "user-b",
      status: ["pending", "accepted"],
    },
  ]);
  assertEquals(result.map((item) => item.id), ["visible-after-first-page"]);
});

Deno.test("incoming RoomInvite loading returns only the newest bounded results", async () => {
  const records = Array.from(
    { length: ROOM_INVITE_RESULT_LIMIT + 1 },
    (_, index) =>
      invite(
        `invite-${String(index).padStart(3, "0")}`,
        "pending",
        "friend-a",
        new Date(Date.UTC(2026, 8, 1, 0, 0, index)).toISOString(),
      ),
  );
  const result = await loadIncomingRoomInvites(
    {
      filter: (_query, _sort, limit, skip) =>
        Promise.resolve(records.slice(skip, skip + limit)),
    },
    "user-b",
    [{
      id: "friendship-a",
      requester_id: "friend-a",
      addressee_id: "user-b",
      status: "accepted",
    }],
  );

  assertEquals(result.length, ROOM_INVITE_RESULT_LIMIT);
  assertEquals(result[0].id, "invite-100");
  assertEquals(result.at(-1)?.id, "invite-001");
});

Deno.test("RoomInvite pagination fails closed on invalid or conflicting pages", async () => {
  const invalidPages: unknown[] = [
    null,
    {},
    Array.from(
      { length: ROOM_INVITE_PAGE_SIZE + 1 },
      (_, index) => invite(`oversized-${index}`),
    ),
    [null],
    [{ recipient_user_id: "user-b" }],
  ];
  for (const page of invalidPages) {
    const error = await assertRejects(
      () =>
        filterAllRoomInvites(
          { filter: () => Promise.resolve(page) },
          { recipient_user_id: "user-b" },
        ),
      Error,
    );
    assertEquals((error as Error & { status?: number }).status, 503);
  }

  let calls = 0;
  const error = await assertRejects(
    () =>
      filterAllRoomInvites(
        {
          filter: () => {
            calls += 1;
            if (calls === 1) {
              return Promise.resolve([
                invite("shared", "pending"),
                ...Array.from(
                  { length: ROOM_INVITE_PAGE_SIZE - 1 },
                  (_, index) => invite(`first-${index}`),
                ),
              ]);
            }
            return Promise.resolve([invite("shared", "accepted")]);
          },
        },
        { recipient_user_id: "user-b" },
      ),
    Error,
    "conflicting record id shared",
  );
  assertEquals((error as Error & { status?: number }).status, 503);
});

Deno.test("RoomInvite pagination fails closed at its page ceiling", async () => {
  let calls = 0;
  const error = await assertRejects(
    () =>
      filterAllRoomInvites(
        {
          filter: (_query, _sort, limit, skip) => {
            calls += 1;
            return Promise.resolve(
              Array.from(
                { length: limit },
                (_, index) => invite(`invite-${skip + index}`),
              ),
            );
          },
        },
        { recipient_user_id: "user-b" },
      ),
    Error,
    `${ROOM_INVITE_MAX_PAGES}-page safety ceiling`,
  );
  assertEquals((error as Error & { status?: number }).status, 503);
  assertEquals(calls, ROOM_INVITE_MAX_PAGES);
});
