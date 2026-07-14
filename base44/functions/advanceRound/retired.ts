export function retiredAdvanceRoundResponse(): Response {
  return Response.json(
    {
      error: "advanceRound is retired. Use gameRoomAction/advance_question.",
      code: "endpoint_retired",
    },
    { status: 410 },
  );
}
