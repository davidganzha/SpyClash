type Delay = (milliseconds: number) => Promise<void>;

const POST_COMMIT_STATE_RETRY_DELAYS_MILLISECONDS = [75, 225];

async function defaultDelay(milliseconds: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}

/**
 * A social mutation is already committed before its full projection is read.
 * Retry only that read so a brief entity failure does not turn a successful
 * write into an ambiguous 503 and a stale user-visible replay.
 */
export async function loadPostCommitState<T>(input: {
  load: () => Promise<T>;
  delay?: Delay;
}): Promise<T> {
  const delay = input.delay || defaultDelay;
  let lastError: unknown;

  for (
    let attempt = 0;
    attempt <= POST_COMMIT_STATE_RETRY_DELAYS_MILLISECONDS.length;
    attempt += 1
  ) {
    try {
      return await input.load();
    } catch (error) {
      lastError = error;
      if (attempt === POST_COMMIT_STATE_RETRY_DELAYS_MILLISECONDS.length) {
        break;
      }
      await delay(POST_COMMIT_STATE_RETRY_DELAYS_MILLISECONDS[attempt]);
    }
  }

  throw lastError;
}
