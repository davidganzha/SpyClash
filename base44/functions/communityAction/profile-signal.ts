import { withCommunityWriteLeases } from "./community-write-lifecycle.ts";

type Entity = Record<string, unknown>;
type Persist = <T>(writer: () => Promise<T>) => Promise<T>;

const PAGE_SIZE = 5_000;
const WRITE_CONCURRENCY = 4;
const RETRY_DELAYS_MILLISECONDS = [75, 225];

export type ProfileSignalFanoutResult = {
  attempted: number;
  succeeded: number;
  failed: number;
  failedRecipientUserIDs: string[];
};

export type ProfileSignalWriteLeaseRunner = (input: {
  userIDs: readonly unknown[];
  action: (guard: { persist: Persist }) => Promise<void>;
}) => Promise<void>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function unique(values: readonly unknown[]): string[] {
  return [...new Set(values.map(clean).filter(Boolean))];
}

async function defaultDelay(milliseconds: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}

async function listAll(store: any): Promise<Entity[]> {
  const rows: Entity[] = [];
  for (let skip = 0;; skip += PAGE_SIZE) {
    const page: Entity[] = await store.list(
      "created_date",
      PAGE_SIZE,
      skip,
    ) || [];
    rows.push(...page);
    if (page.length < PAGE_SIZE) return rows;
  }
}

async function writeSignal(input: {
  signalStore: any;
  signalByRecipient: Map<string, Entity>;
  recipientUserID: string;
  profileUserID: string;
  revision: number;
}): Promise<void> {
  const signal = {
    recipient_user_id: input.recipientUserID,
    profile_user_id: input.profileUserID,
    revision: input.revision,
  };
  const existing = input.signalByRecipient.get(input.recipientUserID);
  const existingID = clean(existing?.id);
  if (existingID) {
    await input.signalStore.update(existingID, signal);
    input.signalByRecipient.set(input.recipientUserID, {
      ...existing,
      ...signal,
    });
    return;
  }

  try {
    const created = await input.signalStore.create(signal) as Entity;
    const createdID = clean(created?.id);
    if (!createdID) throw new Error("Community profile signal id missing");
    input.signalByRecipient.set(input.recipientUserID, {
      ...created,
      ...signal,
    });
  } catch (createError) {
    // Create may have raced another profile update or succeeded before its
    // response was lost. Reconcile the recipient's singleton row before retrying.
    const raced: Entity[] = await input.signalStore.filter({
      recipient_user_id: input.recipientUserID,
    }) || [];
    const writable = raced.find((row) => clean(row?.id));
    if (!writable) throw createError;
    await input.signalStore.update(clean(writable.id), signal);
    input.signalByRecipient.set(input.recipientUserID, {
      ...writable,
      ...signal,
    });
  }
}

async function writeBatch(input: {
  recipientUserIDs: string[];
  profileUserID: string;
  revision: number;
  signalStore: any;
  signalByRecipient: Map<string, Entity>;
  runWithWriteLeases: ProfileSignalWriteLeaseRunner;
}): Promise<Array<{ recipientUserID: string; error: unknown }>> {
  let settled: PromiseSettledResult<void>[] | undefined;
  try {
    await input.runWithWriteLeases({
      userIDs: [input.profileUserID, ...input.recipientUserIDs],
      action: async ({ persist }) => {
        settled = await Promise.allSettled(
          input.recipientUserIDs.map((recipientUserID) =>
            persist(() =>
              writeSignal({
                signalStore: input.signalStore,
                signalByRecipient: input.signalByRecipient,
                recipientUserID,
                profileUserID: input.profileUserID,
                revision: input.revision,
              })
            )
          ),
        );
      },
    });
  } catch (error) {
    // A deleting recipient can prevent a multi-user lease scope from opening.
    // Mark the whole batch for singleton retry so unrelated recipients continue.
    return input.recipientUserIDs.map((recipientUserID) => ({
      recipientUserID,
      error,
    }));
  }

  return (settled || []).flatMap((result, index) =>
    result.status === "rejected"
      ? [{
        recipientUserID: input.recipientUserIDs[index],
        error: result.reason,
      }]
      : []
  );
}

/**
 * Writes one wake-up row per community member. Every raw identity stored in a
 * signal is protected by its billing lifecycle writer lease, so deleteAccount
 * either follows and removes the row or prevents the row from being written.
 */
export async function fanoutProfileUpdate(input: {
  userStore: any;
  signalStore: any;
  lifecycleStore?: any;
  profileUserID: string;
  revision?: number;
  runWithWriteLeases?: ProfileSignalWriteLeaseRunner;
  delay?: (milliseconds: number) => Promise<void>;
  logError?: (message: string, error: unknown) => void;
}): Promise<ProfileSignalFanoutResult> {
  const profileUserID = clean(input.profileUserID);
  if (!profileUserID) throw new Error("A profile signal owner is required");
  if (!input.lifecycleStore && !input.runWithWriteLeases) {
    throw new Error("A profile signal lifecycle store is required");
  }

  const [recipients, existingSignals] = await Promise.all([
    listAll(input.userStore),
    listAll(input.signalStore),
  ]);
  const recipientUserIDs = unique(recipients.map((recipient) => recipient.id));
  const signalByRecipient = new Map<string, Entity>();
  for (const signal of existingSignals) {
    const recipientUserID = clean(signal.recipient_user_id);
    if (recipientUserID && !signalByRecipient.has(recipientUserID)) {
      signalByRecipient.set(recipientUserID, signal);
    }
  }

  const revision = input.revision ?? Date.now();
  const delay = input.delay || defaultDelay;
  const runWithWriteLeases = input.runWithWriteLeases ||
    ((scope) =>
      withCommunityWriteLeases({
        lifecycleStore: input.lifecycleStore,
        userIDs: scope.userIDs,
        attempts: 1,
        action: scope.action,
      }));

  let failures: Array<{ recipientUserID: string; error: unknown }> = [];
  for (
    let offset = 0;
    offset < recipientUserIDs.length;
    offset += WRITE_CONCURRENCY
  ) {
    failures.push(
      ...await writeBatch({
        recipientUserIDs: recipientUserIDs.slice(
          offset,
          offset + WRITE_CONCURRENCY,
        ),
        profileUserID,
        revision,
        signalStore: input.signalStore,
        signalByRecipient,
        runWithWriteLeases,
      }),
    );
  }

  // Retry only failed recipients as singleton lease scopes. This both isolates a
  // concurrently deleting account and recovers brief entity/create races without
  // replaying recipients that already received the revision.
  for (const milliseconds of RETRY_DELAYS_MILLISECONDS) {
    if (!failures.length) break;
    await delay(milliseconds);
    const retryFailures: typeof failures = [];
    for (const failure of failures) {
      retryFailures.push(
        ...await writeBatch({
          recipientUserIDs: [failure.recipientUserID],
          profileUserID,
          revision,
          signalStore: input.signalStore,
          signalByRecipient,
          runWithWriteLeases,
        }),
      );
    }
    failures = retryFailures;
  }

  for (const failure of failures) {
    input.logError?.("community profile signal fanout deferred", failure.error);
  }
  const failedRecipientUserIDs = unique(
    failures.map((failure) => failure.recipientUserID),
  );
  return {
    attempted: recipientUserIDs.length,
    succeeded: recipientUserIDs.length - failedRecipientUserIDs.length,
    failed: failedRecipientUserIDs.length,
    failedRecipientUserIDs,
  };
}
