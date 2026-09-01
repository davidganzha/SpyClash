import { clean } from "./contracts.ts";

type Entity = Record<string, any>;

function objectValue(value: unknown): Entity | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Entity
    : null;
}

export function finishedProfileRepairAlreadyCompleted(
  room: Entity,
): boolean {
  if (clean(room?.status).toLowerCase() !== "finished") return false;

  const matchID = clean(room?.match_id);
  const sourceEventID = clean(room?.game_finished_event_id);
  const terminalIntent = objectValue(room?.terminal_intent);
  const dispatch = objectValue(terminalIntent?.profile_side_effect_dispatch);

  return Boolean(matchID) && Boolean(sourceEventID) &&
    clean(terminalIntent?.match_id) === matchID &&
    clean(dispatch?.event_id) === sourceEventID &&
    clean(dispatch?.state).toLowerCase() === "completed";
}
