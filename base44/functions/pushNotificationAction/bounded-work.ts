export type BoundedWorkResult<T> = {
  completed: T[];
  unstarted: T[];
};

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

export async function runBounded<T>(input: {
  items: readonly T[];
  concurrency: number;
  deadlineEpochMs: number;
  worker: (item: T) => Promise<void>;
}): Promise<BoundedWorkResult<T>> {
  const items = [...input.items];
  const completed: T[] = [];
  let nextIndex = 0;
  const concurrency = Math.max(
    1,
    Math.min(items.length || 1, input.concurrency),
  );

  const runner = async () => {
    while (Date.now() < input.deadlineEpochMs) {
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
