// Entitlement rows are admin-only. Publish a minimal owner-readable hint instead
// of weakening their RLS or exposing transaction/account-binding identifiers.
export async function publishMembershipSignal(input: {
  store: any;
  userID: string;
  beforePersist: () => Promise<void>;
}): Promise<boolean> {
  try {
    const records = await input.store.filter(
      { user_id: input.userID },
      "created_date",
      1,
      0,
    );
    const hint = { user_id: input.userID, change_id: crypto.randomUUID() };
    // The existing Apple binding lease also excludes account-deletion cleanup.
    await input.beforePersist();
    if (records[0]?.id) await input.store.update(records[0].id, hint);
    else await input.store.create(hint);
    return true;
  } catch {
    // Delivery failure cannot invalidate an already committed purchase. Clients
    // also refresh on activation and periodically to recover missed signals.
    return false;
  }
}
