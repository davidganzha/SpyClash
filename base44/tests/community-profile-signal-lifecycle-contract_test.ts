import { assertStringIncludes } from "jsr:@std/assert@1";

Deno.test("every CommunityProfileSignal writer and account cleanup share lifecycle ordering", async () => {
  const [
    communitySignal,
    communityMain,
    gameRoomMain,
    gameRoomSignal,
    deleteMain,
    relationshipCleanup,
    reservedAssignment,
  ] = await Promise.all([
    Deno.readTextFile(
      new URL(
        "../functions/communityAction/profile-signal.ts",
        import.meta.url,
      ),
    ),
    Deno.readTextFile(
      new URL("../functions/communityAction/main.ts", import.meta.url),
    ),
    Deno.readTextFile(
      new URL("../functions/gameRoomAction/main.ts", import.meta.url),
    ),
    Deno.readTextFile(
      new URL(
        "../functions/gameRoomAction/community-profile-signal.ts",
        import.meta.url,
      ),
    ),
    Deno.readTextFile(
      new URL("../functions/deleteAccount/main.ts", import.meta.url),
    ),
    Deno.readTextFile(
      new URL(
        "../functions/deleteAccount/relationship-cleanup.ts",
        import.meta.url,
      ),
    ),
    Deno.readTextFile(
      new URL("../../scripts/assign-reserved-spy-id.ts", import.meta.url),
    ),
  ]);

  assertStringIncludes(
    communitySignal,
    "userIDs: [input.profileUserID, ...input.recipientUserIDs]",
  );
  assertStringIncludes(communitySignal, "persist(() =>");
  assertStringIncludes(
    communityMain,
    "lifecycleStore,\n          profileUserID",
  );
  assertStringIncludes(
    reservedAssignment,
    "lifecycleStore: base44.entities.BillingIdentityLifecycle",
  );

  assertStringIncludes(gameRoomMain, "[profileUserID, recipientUserID]");
  assertStringIncludes(gameRoomMain, "beforeSignalWrite: async () =>");
  assertStringIncludes(
    gameRoomMain,
    "assertRoomWriterLeaseForUser(context, profileUserID)",
  );
  assertStringIncludes(
    gameRoomMain,
    "assertRoomWriterLeaseForUser(context, recipientUserID)",
  );
  assertStringIncludes(gameRoomSignal, "await input.beforeWrite?.(");

  assertStringIncludes(
    deleteMain,
    "base44.asServiceRole.entities.CommunityProfileSignal",
  );
  assertStringIncludes(
    relationshipCleanup,
    "recipient_user_id: input.userID",
  );
  assertStringIncludes(
    relationshipCleanup,
    "profile_user_id: input.userID",
  );
});
