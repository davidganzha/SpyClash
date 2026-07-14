import {
  acquireBillingWriterLease,
  assertBillingWriterLease,
  type BillingIdentityLease,
  billingIdentitySubjectKey,
  releaseBillingWriterLease,
} from "./billing-identity-lifecycle.ts";

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

export function uniqueStableUserIDs(values: readonly unknown[]): string[] {
  return [...new Set(values.map(clean).filter(Boolean))].sort();
}

export type RoomWriteLeaseContext = {
  lifecycleStore: any;
  userIDs: string[];
  leases: BillingIdentityLease[];
};

function roomMembershipChanged(): Error {
  return Object.assign(
    new Error("Room membership changed while acquiring lifecycle leases."),
    { status: 409, code: "room_membership_changed" },
  );
}

export function assertExactRoomLeaseCoverage(
  context: RoomWriteLeaseContext,
  currentUserIDs: readonly unknown[],
): void {
  const current = uniqueStableUserIDs(currentUserIDs);
  if (
    current.length !== context.userIDs.length ||
    current.some((value, index) => value !== context.userIDs[index])
  ) {
    throw roomMembershipChanged();
  }
}

export async function assertRoomWriteLeases(
  context: RoomWriteLeaseContext,
): Promise<void> {
  for (const lease of context.leases) {
    await assertBillingWriterLease(context.lifecycleStore, lease);
  }
}

export async function assertRoomWriterLeaseForUser(
  context: RoomWriteLeaseContext,
  userIDValue: unknown,
): Promise<void> {
  const userID = clean(userIDValue);
  const index = context.userIDs.indexOf(userID);
  if (!userID || index < 0 || !context.leases[index]) {
    throw roomMembershipChanged();
  }
  const expectedSubjectKey = await billingIdentitySubjectKey(userID);
  if (context.leases[index].subjectKey !== expectedSubjectKey) {
    throw roomMembershipChanged();
  }
  await assertBillingWriterLease(
    context.lifecycleStore,
    context.leases[index],
  );
}

export async function withRoomWriteLeases<T>(input: {
  lifecycleStore: any;
  userIDs: readonly unknown[];
  action: (context: RoomWriteLeaseContext) => Promise<T>;
}): Promise<T> {
  const userIDs = uniqueStableUserIDs(input.userIDs);
  if (!userIDs.length) {
    throw Object.assign(
      new Error("A stable room writer identity is required."),
      {
        status: 401,
        code: "incomplete_identity",
      },
    );
  }

  const context: RoomWriteLeaseContext = {
    lifecycleStore: input.lifecycleStore,
    userIDs,
    leases: [],
  };
  let actionError: unknown;
  try {
    for (const userID of userIDs) {
      context.leases.push(
        await acquireBillingWriterLease(input.lifecycleStore, userID),
      );
    }
    return await input.action(context);
  } catch (error) {
    actionError = error;
    throw error;
  } finally {
    const releaseFailures: unknown[] = [];
    for (const lease of [...context.leases].reverse()) {
      try {
        await releaseBillingWriterLease(input.lifecycleStore, lease);
      } catch (error) {
        releaseFailures.push(error);
      }
    }
    if (!actionError && releaseFailures.length) throw releaseFailures[0];
    if (releaseFailures.length) {
      console.error("gameRoomAction lease release failed", releaseFailures);
    }
  }
}
