import { runWithWallClockDeadline } from "./operation-deadline.ts";

export async function runPostLeaseSignalWithinDeadline(input: {
  timeoutMS: number;
  leasedOperation: () => Promise<boolean>;
  logError?: (message: string, error: unknown) => void;
}): Promise<boolean> {
  try {
    return await runWithWallClockDeadline({
      timeoutMS: input.timeoutMS,
      operation: input.leasedOperation,
      timeoutError: () =>
        Object.assign(new Error("Room signal fanout exceeded its deadline."), {
          status: 503,
          code: "room_signal_deadline",
        }),
    });
  } catch (error) {
    input.logError?.("room signal fanout deferred", error);
    return false;
  }
}
