type Entity = Record<string, unknown>;
const PAGE_SIZE = 5_000;
const WRITE_CONCURRENCY = 4;

function clean(value: unknown): string {
  return String(value ?? "").trim();
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

/** One bounded read per store replaces the former read-per-recipient fanout. */
export async function fanoutProfileUpdate(input: {
  userStore: any;
  signalStore: any;
  profileUserID: string;
  revision?: number;
}): Promise<void> {
  const [recipients, existingSignals] = await Promise.all([
    listAll(input.userStore),
    listAll(input.signalStore),
  ]);
  const signalByRecipient = new Map<string, Entity>();
  for (const signal of existingSignals) {
    const recipientUserID = clean(signal.recipient_user_id);
    if (recipientUserID && !signalByRecipient.has(recipientUserID)) {
      signalByRecipient.set(recipientUserID, signal);
    }
  }
  const revision = input.revision ?? Date.now();

  for (
    let offset = 0;
    offset < recipients.length;
    offset += WRITE_CONCURRENCY
  ) {
    await Promise.all(
      recipients.slice(offset, offset + WRITE_CONCURRENCY).map(
        async (recipient) => {
          const recipientUserID = clean(recipient.id);
          if (!recipientUserID) return;
          const existing = signalByRecipient.get(recipientUserID);
          const signal = {
            recipient_user_id: recipientUserID,
            profile_user_id: input.profileUserID,
            revision,
          };
          if (existing?.id) {
            await input.signalStore.update(existing.id, signal);
          } else {
            await input.signalStore.create(signal);
          }
        },
      ),
    );
  }
}
