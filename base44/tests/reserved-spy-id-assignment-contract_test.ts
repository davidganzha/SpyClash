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
  assertStringIncludes(
    source,
    "SPYCLASH_RESERVED_SPY_ID_BILLING_LIFECYCLE_SOURCE_SHA256",
  );
  assertStringIncludes(source, "lockedPlan.planDigest !== expectedPlanDigest");
  assertStringIncludes(source, "withCommunityWriteLeases");
  assertStringIncludes(source, "BillingIdentityLifecycle");
  assertStringIncludes(source, "reserved_spy_id_other_holders");
  assertStringIncludes(source, "const users = await listedRecords(");
  assertStringIncludes(
    source,
    "normalizeSpyID(user?.spy_id) === RESERVED_SPY_ID",
  );
  assertStringIncludes(source, ".match(/^([0-9]{3})[- ]?([0-9]{3})$/)");
  for (const alias of ["067067", "067 067"]) {
    const match = alias.match(/^([0-9]{3})[- ]?([0-9]{3})$/);
    assertEquals(match ? `${match[1]}-${match[2]}` : null, "067-067");
  }
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
  assertEquals(source.includes("{ spy_id: RESERVED_SPY_ID }"), false);
});

Deno.test("reserved SPY ID wrapper defaults to dry-run and gates production apply", async () => {
  const source = await Deno.readTextFile(wrapperURL);
  const applyBoundary = 'run_assignment apply "$PLAN_DIGEST"';

  assertStringIncludes(source, "MODE=dry-run");
  assertStringIncludes(source, "--expected-current-spy-id");
  assertStringIncludes(source, 'STAGE="$CUTOVER_DIR/reserved-spy-id-067-067"');
  assertStringIncludes(
    source,
    "git rev-parse --path-format=absolute --git-common-dir",
  );
  assertStringIncludes(
    source,
    'CANONICAL_GIT_COMMON_DIR=$(CDPATH= cd -- "$GIT_COMMON_DIR" && pwd -P)',
  );
  assertStringIncludes(
    source,
    'CDPATH= cd -- "$CANONICAL_GIT_COMMON_DIR/.." && pwd -P',
  );
  assertStringIncludes(
    source,
    "CANONICAL_REPOSITORY_ROOT/.base44-cutover/.production-mutation.lock",
  );
  assertStringIncludes(
    source,
    'PRODUCTION_LOCK_DIR="$CANONICAL_REPOSITORY_ROOT/.base44-cutover/.production-mutation.lock"',
  );
  assertStringIncludes(source, "run_assignment dry-run");
  assertStringIncludes(source, "BILLING_LIFECYCLE_SOURCE_SHA256");
  assertStringIncludes(
    source,
    'stage_exact_source "$SCRIPT" "$STAGED_SCRIPT"',
  );
  assertStringIncludes(
    source,
    'stage_exact_source "$LIFECYCLE_SCRIPT" "$STAGED_LIFECYCLE_SCRIPT"',
  );
  assertStringIncludes(
    source,
    'stage_exact_source "$BILLING_LIFECYCLE_SCRIPT" "$STAGED_BILLING_LIFECYCLE_SCRIPT"',
  );
  assertStringIncludes(
    source,
    'stage_exact_source "$POLICY_SCRIPT" "$STAGED_POLICY_SCRIPT"',
  );
  assertStringIncludes(
    source,
    'stage_exact_source "$PROFILE_SIGNAL_SCRIPT" "$STAGED_PROFILE_SIGNAL_SCRIPT"',
  );
  assertStringIncludes(source, 'SOURCE_SHA256=$(hash_file "$STAGED_SCRIPT")');
  assertStringIncludes(
    source,
    'LIFECYCLE_SOURCE_SHA256=$(hash_file "$STAGED_LIFECYCLE_SCRIPT")',
  );
  assertStringIncludes(
    source,
    'BILLING_LIFECYCLE_SOURCE_SHA256=$(hash_file "$STAGED_BILLING_LIFECYCLE_SCRIPT")',
  );
  assertStringIncludes(
    source,
    'POLICY_SOURCE_SHA256=$(hash_file "$STAGED_POLICY_SCRIPT")',
  );
  assertStringIncludes(
    source,
    'PROFILE_SIGNAL_SOURCE_SHA256=$(hash_file "$STAGED_PROFILE_SIGNAL_SCRIPT")',
  );
  assertStringIncludes(
    source,
    'LIFECYCLE_URL="file://$STAGED_LIFECYCLE_SCRIPT"',
  );
  assertStringIncludes(
    source,
    'PROFILE_SIGNAL_URL="file://$STAGED_PROFILE_SIGNAL_SCRIPT"',
  );
  assertStringIncludes(source, '< "$STAGED_SCRIPT" > "$run_output" 2>&1');
  assertStringIncludes(source, 'cmp -s "$stage_source" "$stage_destination"');
  assertStringIncludes(source, 'chmod 400 "$stage_destination"');
  assertStringIncludes(
    source,
    'chmod 500 "$SOURCE_STAGE" "$STAGED_COMMUNITY_DIR"',
  );
  assertStringIncludes(source, "npx --yes -p deno@2.9.5 -p base44@0.1.4");
  assertEquals(
    source.split("npx --yes -p deno@2.9.5 -p base44@0.1.4").length - 1,
    2,
  );
  assertStringIncludes(
    source,
    'git -C "$ROOT" worktree list --porcelain',
  );
  assertStringIncludes(source, 'sort -u > "$worktree_roots"');
  assertStringIncludes(
    source,
    'worktree_lock_dir="$worktree_cutover_dir/.production-mutation.lock"',
  );
  assertStringIncludes(
    source,
    'printf \'%s\\n\' "$worktree_lock_dir" >> "$PRODUCTION_LOCK_LIST"',
  );
  assertStringIncludes(
    source,
    '[ "$found_current" -eq 1 ] && [ "$found_canonical" -eq 1 ]',
  );
  assertStringIncludes(source, 'done < "$worktree_roots"');
  assertStringIncludes(source, 'mkdir -p "$CUTOVER_DIR" "$STAGE"');
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
    'acquire_production_locks\nif ! run_assignment dry-run "" "$WORK/preflight.raw"',
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
    "acquire_production_locks\nif ! run_assignment dry-run",
    'run_assignment dry-run "" "$WORK/preflight.raw"',
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
  assertEquals(source.includes('SOURCE_SHA256=$(hash_file "$SCRIPT")'), false);
  assertEquals(
    source.includes(
      'LIFECYCLE_SOURCE_SHA256=$(hash_file "$LIFECYCLE_SCRIPT")',
    ),
    false,
  );
  assertEquals(
    source.includes(
      'BILLING_LIFECYCLE_SOURCE_SHA256=$(hash_file "$BILLING_LIFECYCLE_SCRIPT")',
    ),
    false,
  );
  assertEquals(
    source.includes('POLICY_SOURCE_SHA256=$(hash_file "$POLICY_SCRIPT")'),
    false,
  );
  assertEquals(
    source.includes(
      'PROFILE_SIGNAL_SOURCE_SHA256=$(hash_file "$PROFILE_SIGNAL_SCRIPT")',
    ),
    false,
  );
  assertEquals(source.includes('< "$SCRIPT" > "$run_output"'), false);
  assertEquals(source.includes("-p deno -p base44@0.1.4"), false);
  assertEquals(
    source.includes(
      'mkdir -p "$CUTOVER_DIR" "$STAGE" "$CANONICAL_CUTOVER_DIR"',
    ),
    false,
  );
});
