export class OperationDeadlineError extends Error {
  code: string;
  status: number;

  constructor(message: string, code = "operation_deadline_exceeded") {
    super(message);
    this.name = "OperationDeadlineError";
    this.code = code;
    this.status = 503;
  }
}

export async function runWithWallClockDeadline<T>(input: {
  timeoutMS: number;
  operation: () => Promise<T>;
  timeoutError?: () => Error;
}): Promise<T> {
  const timeoutMS = Math.max(1, Math.floor(Number(input.timeoutMS) || 1));
  let timeoutID: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_resolve, reject) => {
    timeoutID = setTimeout(() => {
      reject(
        input.timeoutError?.() ||
          new OperationDeadlineError("The operation exceeded its deadline."),
      );
    }, timeoutMS);
  });

  try {
    return await Promise.race([
      Promise.resolve().then(input.operation),
      deadline,
    ]);
  } finally {
    if (timeoutID !== undefined) clearTimeout(timeoutID);
  }
}
