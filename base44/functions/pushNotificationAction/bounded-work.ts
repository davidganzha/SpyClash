export type BoundedWorkResult<T> = {
  completed: T[];
  unstarted: T[];
};

export type DeadlineResult<T> =
  | { timedOut: false; value: T }
  | { timedOut: true };

export function clampDeadline(
  value: unknown,
  budgetMs: number,
  now = Date.now(),
): number {
  const requested = Number(value);
  return Number.isFinite(requested) && requested > 0
    ? Math.min(requested, now + budgetMs)
    : now + budgetMs;
}

export async function runWithinDeadline<T>(input: {
  deadlineEpochMs: number;
  operation: () => Promise<T>;
  nowEpochMs?: () => number;
}): Promise<DeadlineResult<T>> {
  const nowEpochMs = input.nowEpochMs || Date.now;
  const remaining = Math.floor(input.deadlineEpochMs - nowEpochMs());
  if (remaining <= 0) return { timedOut: true };

  let timeoutID: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<DeadlineResult<T>>((resolve) => {
    timeoutID = setTimeout(() => resolve({ timedOut: true }), remaining);
  });
  const operation = input.operation().then((value) => ({
    timedOut: false as const,
    value,
  }));
  try {
    return await Promise.race([operation, timeout]);
  } finally {
    if (timeoutID !== undefined) clearTimeout(timeoutID);
  }
}

export async function runBounded<T>(input: {
  items: readonly T[];
  concurrency: number;
  deadlineEpochMs: number;
  worker: (item: T) => Promise<void>;
  nowEpochMs?: () => number;
}): Promise<BoundedWorkResult<T>> {
  const items = [...input.items];
  const completed: T[] = [];
  let nextIndex = 0;
  const nowEpochMs = input.nowEpochMs || Date.now;
  const concurrency = Math.max(
    1,
    Math.min(items.length || 1, input.concurrency),
  );

  const runner = async () => {
    while (nowEpochMs() < input.deadlineEpochMs) {
      const index = nextIndex;
      if (index >= items.length) return;
      nextIndex += 1;
      const item = items[index];
      await input.worker(item);
      completed.push(item);
    }
  };
  await Promise.all(Array.from({ length: concurrency }, () => runner()));
  return { completed, unstarted: items.slice(nextIndex) };
}
