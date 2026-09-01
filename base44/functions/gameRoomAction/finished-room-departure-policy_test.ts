import { assertEquals } from "jsr:@std/assert@1";
import { hostDepartureUsesMembershipTransition } from "./finished-room-departure-policy.ts";

function room(status: string, players = [
  { email: "host@example.com" },
  { email: "guest@example.com" },
]) {
  return {
    status,
    host_email: "host@example.com",
    players,
    game_started_at: status === "playing" ? "2026-09-01T12:00:00.000Z" : "",
  };
}

Deno.test("finished host departure transfers membership while another player remains", () => {
  assertEquals(
    hostDepartureUsesMembershipTransition(
      room("finished"),
      " HOST@EXAMPLE.COM ",
    ),
    true,
  );
});

Deno.test("empty finished room and ordinary host lobby close retain deletion semantics", () => {
  assertEquals(
    hostDepartureUsesMembershipTransition(
      room("finished", [{ email: "host@example.com" }]),
      "host@example.com",
    ),
    false,
  );
  assertEquals(
    hostDepartureUsesMembershipTransition(room("waiting"), "host@example.com"),
    false,
  );
});

Deno.test("non-host and active host departures use the membership transition", () => {
  assertEquals(
    hostDepartureUsesMembershipTransition(
      room("finished"),
      "guest@example.com",
    ),
    true,
  );
  assertEquals(
    hostDepartureUsesMembershipTransition(room("playing"), "host@example.com"),
    true,
  );
});
