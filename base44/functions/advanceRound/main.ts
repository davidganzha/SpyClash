import { retiredAdvanceRoundResponse } from "./retired.ts";

// This legacy endpoint previously mutated GameRoom directly and bypassed the
// lifecycle/role checks in gameRoomAction. Keep the deployed name fail-closed
// so old clients receive an explicit migration error instead of a hidden write.
Deno.serve(() => retiredAdvanceRoundResponse());
