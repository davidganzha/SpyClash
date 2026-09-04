type Entity = Record<string, unknown>;

export type CommunityProfileSignalStore = {
  filter(query: Record<string, unknown>): Promise<Entity[]>;
  create(value: Entity): Promise<unknown>;
  update(id: string, value: Entity): Promise<unknown>;
};

const WRITE_CONCURRENCY = 4;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function unique(values: readonly unknown[]): string[] {
  return [...new Set(values.map(clean).filter(Boolean))];
}

async function writeSignal(input: {
  store: CommunityProfileSignalStore;
  signalByRecipient: Map<string, Entity>;
  recipientUserID: string;
  profileUserID: string;
  revision: number;
  beforeWrite?: (
    recipientUserID: string,
    profileUserID: string,
  ) => void | Promise<void>;
}): Promise<void> {
  const signal = {
    recipient_user_id: input.recipientUserID,
    profile_user_id: input.profileUserID,
    revision: input.revision,
  };
  const existing = input.signalByRecipient.get(input.recipientUserID);
  if (clean(existing?.id)) {
    await input.beforeWrite?.(input.recipientUserID, input.profileUserID);
    await input.store.update(clean(existing?.id), signal);
    input.signalByRecipient.set(input.recipientUserID, {
      ...existing,
      ...signal,
    });
    return;
  }

  try {
    await input.beforeWrite?.(input.recipientUserID, input.profileUserID);
    const created = await input.store.create(signal) as Entity;
    const createdID = clean(created?.id);
    if (!createdID) throw new Error("Community profile signal id missing");
    input.signalByRecipient.set(input.recipientUserID, created);
  } catch (createError) {
    const raced = await input.store.filter({
      recipient_user_id: input.recipientUserID,
    }) || [];
    const writable = raced.find((row) => clean(row?.id));
    if (!writable) throw createError;
    await input.beforeWrite?.(input.recipientUserID, input.profileUserID);
    await input.store.update(clean(writable.id), signal);
    input.signalByRecipient.set(input.recipientUserID, {
      ...writable,
      ...signal,
    });
  }
}

/**
 * CommunityProfileSignal stores one wake-up row per recipient. Updating that
 * row once per affected profile preserves the current iOS event contract;
 * reconnect catch-up still reloads the complete directory if an event is lost.
 * Callers provide only recipients whose identity lifecycle leases they hold.
 */
export async function fanoutCommunityProfileInvalidations(input: {
  signalStore: CommunityProfileSignalStore;
  recipientUserIDs: readonly unknown[];
  profileUserIDs: readonly unknown[];
  revisionBase?: number;
  logError?: (message: string, error: unknown) => void;
  beforeSignalWrite?: (
    recipientUserID: string,
    profileUserID: string,
  ) => void | Promise<void>;
}): Promise<{ attempted: number; succeeded: number; failed: number }> {
  const profileUserIDs = unique(input.profileUserIDs);
  if (!profileUserIDs.length) {
    return { attempted: 0, succeeded: 0, failed: 0 };
  }

  const recipientUserIDs = unique(input.recipientUserIDs);
  if (!recipientUserIDs.length) {
    return { attempted: 0, succeeded: 0, failed: 0 };
  }
  const signalByRecipient = new Map<string, Entity>();
  const unavailableRecipients = new Set<string>();
  for (
    let offset = 0;
    offset < recipientUserIDs.length;
    offset += WRITE_CONCURRENCY
  ) {
    const batch = recipientUserIDs.slice(offset, offset + WRITE_CONCURRENCY);
    const settled = await Promise.allSettled(
      batch.map((recipientUserID) =>
        input.signalStore.filter({ recipient_user_id: recipientUserID })
      ),
    );
    for (const [index, result] of settled.entries()) {
      const recipientUserID = batch[index];
      if (result.status === "rejected") {
        unavailableRecipients.add(recipientUserID);
        input.logError?.(
          "community profile signal read deferred",
          result.reason,
        );
        continue;
      }
      const signal = (result.value || []).find((row) => clean(row?.id));
      if (signal) signalByRecipient.set(recipientUserID, signal);
    }
  }

  const revisionBase = Number.isInteger(input.revisionBase)
    ? Number(input.revisionBase)
    : Date.now();
  const writableRecipients = recipientUserIDs.filter((recipientUserID) =>
    !unavailableRecipients.has(recipientUserID)
  );
  let succeeded = 0;
  let failed = unavailableRecipients.size * profileUserIDs.length;

  // A recipient owns one signal row, so profiles must be written in sequence;
  // recipients within each revision remain safely bounded and concurrent.
  for (const [profileOffset, profileUserID] of profileUserIDs.entries()) {
    for (
      let recipientOffset = 0;
      recipientOffset < writableRecipients.length;
      recipientOffset += WRITE_CONCURRENCY
    ) {
      const settled = await Promise.allSettled(
        writableRecipients
          .slice(recipientOffset, recipientOffset + WRITE_CONCURRENCY)
          .map((recipientUserID) =>
            writeSignal({
              store: input.signalStore,
              signalByRecipient,
              recipientUserID,
              profileUserID,
              revision: revisionBase + profileOffset,
              beforeWrite: input.beforeSignalWrite,
            })
          ),
      );
      for (const result of settled) {
        if (result.status === "fulfilled") {
          succeeded += 1;
        } else {
          failed += 1;
          input.logError?.(
            "community profile signal fanout deferred",
            result.reason,
          );
        }
      }
    }
  }

  return {
    attempted: recipientUserIDs.length * profileUserIDs.length,
    succeeded,
    failed,
  };
}
