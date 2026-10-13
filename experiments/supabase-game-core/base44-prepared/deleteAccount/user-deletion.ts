type Entity = Record<string, unknown>;

function clean(value: unknown): string {
  return String(value || "").trim();
}

function errorMessage(error: unknown): string {
  return error instanceof Error
    ? error.message
    : String(error || "Unknown error");
}

export type UserDeletionFailureCode = "confirmed_present" | "ambiguous";

export class UserDeletionFailure extends Error {
  constructor(
    public readonly code: UserDeletionFailureCode,
    message: string,
  ) {
    super(message);
    this.name = "UserDeletionFailure";
  }
}

/**
 * Deletes the Base44 User and reconciles a lost delete response with an exact
 * read. Returning means the record is confirmed absent. An ambiguous failure
 * must stay fail-closed: callers must not restore already-redacted identity.
 */
export async function deleteUserRecord(
  userStore: any,
  userID: string,
): Promise<void> {
  const stableUserID = clean(userID);
  if (!stableUserID) {
    throw new UserDeletionFailure(
      "confirmed_present",
      "A stable user id is required for deletion",
    );
  }

  try {
    await userStore.delete(stableUserID);
    return;
  } catch (deleteError) {
    let records: Entity[];
    try {
      records = await userStore.filter(
        { id: stableUserID },
        "created_date",
        2,
        0,
      ) || [];
    } catch (confirmationError) {
      throw new UserDeletionFailure(
        "ambiguous",
        `User deletion response and confirmation were both lost: ${
          errorMessage(deleteError)
        }; ${errorMessage(confirmationError)}`,
      );
    }

    if (!records.some((record) => clean(record?.id) === stableUserID)) {
      // Delete applied and only its response was lost.
      return;
    }

    throw new UserDeletionFailure(
      "confirmed_present",
      `User record still exists after delete failed: ${
        errorMessage(deleteError)
      }`,
    );
  }
}
