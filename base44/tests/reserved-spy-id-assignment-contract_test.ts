import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

const wrapperURL = new URL(
  "../../scripts/run-base44-reserved-spy-id-assignment.sh",
  import.meta.url,
);
const assignmentURL = new URL(
  "../../scripts/assign-reserved-spy-id.ts",
  import.meta.url,
);
const communityURL = new URL(
  "../functions/communityAction/community.ts",
  import.meta.url,
);
const communityMainURL = new URL(
  "../functions/communityAction/main.ts",
  import.meta.url,
);

function assertBefore(source: string, earlier: string, later: string) {
  const earlierIndex = source.indexOf(earlier);
  const laterIndex = source.indexOf(later);
  assert(earlierIndex >= 0, `missing guard: ${earlier}`);
  assert(laterIndex >= 0, `missing boundary: ${later}`);
  assert(earlierIndex < laterIndex, `${earlier} must occur before ${later}`);
}

Deno.test("067-067 is reserved from ordinary community allocation", async () => {
  const [community, main] = await Promise.all([
    Deno.readTextFile(communityURL),
    Deno.readTextFile(communityMainURL),
  ]);
  assertStringIncludes(
    community,
    'const RESERVED_MANUAL_SPY_IDS = new Set(["067-067"])',
  );
  assertStringIncludes(community, "export function isReservedManualSpyID");
  assertStringIncludes(main, "if (isReservedManualSpyID(candidate)) continue");
  assertBefore(
    main,
    "if (isReservedManualSpyID(candidate)) continue",
    "const holders = await usersWithSpyID(base44, candidate)",
  );
});

Deno.test("reserved SPY ID implementation is admin-only, digest-bound, leased, and postflighted", async () => {
  const source = await Deno.readTextFile(assignmentURL);
  const friendshipWrite = "base44.entities.Friendship.update(patch.id";
  const userWrite = "base44.entities.User.update(targetUserID";

  assertStringIncludes(
    source,
    'const EXPECTED_APP_ID = "69a0e57fa939f578082f8091"',
  );
  assertStringIncludes(
    source,
    'const EXPECTED_ACTION = "PARTNER_NOTE_67_ASSIGN_RESERVED_SPY_ID_067_067"',
  );
  assertStringIncludes(source, 'const RESERVED_SPY_ID = "067-067"');
  assertStringIncludes(
    source,
    'clean(operator?.role).toLocaleLowerCase() !== "admin"',
  );
  assertStringIncludes(source, "SPYCLASH_RESERVED_SPY_ID_EXPECTED_PLAN_DIGEST");
  assertStringIncludes(source, "lockedPlan.planDigest !== expectedPlanDigest");
  assertStringIncludes(source, "withCommunityWriteLeases");
  assertStringIncludes(source, "BillingIdentityLifecycle");
  assertStringIncludes(source, "reserved_spy_id_other_holders");
  assertStringIncludes(source, "postflight_unique_owner: true");
  assertStringIncludes(source, "postflight_friendship_projection: true");
  assertStringIncludes(source, "fanoutProfileUpdate");
  assertBefore(
    source,
    "expectedPlanDigest !== initialPlan.planDigest",
    friendshipWrite,
  );
  assertBefore(
    source,
    "lockedPlan.planDigest !== expectedPlanDigest",
    friendshipWrite,
  );
  assertBefore(source, friendshipWrite, userWrite);
  assertBefore(
    source,
    userWrite,
    "Reserved SPY ID postflight verification failed",
  );
  assertEquals(source.includes("console.log(operator"), false);
  assertEquals(source.includes("console.log(target"), false);
  assertEquals(source.includes("base44.entities.User.updateMany"), false);
});

Deno.test("reserved SPY ID wrapper defaults to dry-run and gates production apply", async () => {
  const source = await Deno.readTextFile(wrapperURL);
  const applyBoundary = 'run_assignment apply "$PLAN_DIGEST"';

  assertStringIncludes(source, "MODE=dry-run");
  assertStringIncludes(source, "--expected-current-spy-id");
  assertStringIncludes(source, 'STAGE="$CUTOVER_DIR/reserved-spy-id-067-067"');
  assertStringIncludes(
    source,
    'PRODUCTION_LOCK_DIR="$CUTOVER_DIR/.production-mutation.lock"',
  );
  assertStringIncludes(source, "run_assignment dry-run");
  assertStringIncludes(
    source,
    "Live state changed after review; run a new dry-run.",
  );
  assertStringIncludes(source, "BASE44_CONFIRM_RESERVED_SPY_ID_TARGET_USER_ID");
  assertStringIncludes(source, "BASE44_CONFIRM_RESERVED_SPY_ID_PLAN_DIGEST");
  assertStringIncludes(
    source,
    "BASE44_CONFIRM_RESERVED_SPY_ID_POLICY_DEPLOYED",
  );
  assertStringIncludes(source, "mutation-started-postflight-required");
  assertStringIncludes(source, "completed-postflight-verified");
  assertStringIncludes(
    source,
    "acquire_production_lock\nwrite_attempt mutation-started-postflight-required",
  );
  assertBefore(source, "BASE44_CONFIRM_ACTION:-}", applyBoundary);
  assertBefore(source, "BASE44_CONFIRM_APP_ID:-}", applyBoundary);
  assertBefore(
    source,
    "BASE44_CONFIRM_RESERVED_SPY_ID_PLAN_DIGEST:-}",
    applyBoundary,
  );
  assertBefore(
    source,
    'run_assignment dry-run "" "$WORK/preflight.raw"',
    applyBoundary,
  );
  assertBefore(
    source,
    "write_attempt mutation-started-postflight-required",
    applyBoundary,
  );
  assertEquals(source.includes("base44 deploy"), false);
  assertEquals(source.includes("functions deploy"), false);
  assertEquals(source.includes("entities push"), false);
  assertEquals(source.includes("--force"), false);
});
