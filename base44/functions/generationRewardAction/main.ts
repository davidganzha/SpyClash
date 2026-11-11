import { createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import {
  canonicalBase44Request,
  hasTrustedBase44Context,
} from "./base44-context.ts";
import {
  applyAdminGenerationGrant,
  applyCasadaGenerationAccess,
  resolveGenerationMembership,
} from "./membership.ts";
import { withGenerationWriterLease } from "./generation-write-lifecycle.ts";
import { verifyAdMobCallback } from "./admob-ssv.ts";
import { isUnityCallback, unityAttemptFields, verifyUnityCallback } from "./unity-ssv.ts";
import {
  configuredRewardAdUnit,
  enrollRewardGeneration,
  rewardedGenerationEnabledForUser,
  GenerationRewardError,
  generationRewardStatus,
  grantVerifiedGenerationReward,
  isGenerationRewardTester,
  prepareRewardAttempt,
  rewardAttempt,
  rewardedGenerationEnabled,
  rewardUUID,
} from "./generation-rewards.ts";

Deno.serve(async (req) => {
  try {
    if (!["GET", "POST"].includes(req.method)) {
      return Response.json({ error: "Method not allowed" }, { status: 405 });
    }
    if (req.method === "POST" && !hasTrustedBase44Context(req)) {
      return Response.json({ error: "Unauthorized" }, { status: 401 });
    }
    const base44 = createClientFromRequest(canonicalBase44Request(req));
    const entities = base44.asServiceRole.entities;
    if (req.method === "GET") {
      // Continue validating already-issued attempts when rollout is disabled.
      // Disabling new offers must never erase a reward someone has earned.
      const unity = isUnityCallback(req.url);
      let callback;
      if (unity) {
        const verified = verifyUnityCallback(req.url, Deno.env.toObject());
        // SID is a server-issued random attempt capability, not an account ID.
        if (verified.customData.split(".")[1] !== "legacy") {
          throw new GenerationRewardError("invalid_reward_claim", "Invalid reward destination.", 400);
        }
        const rows = await entities.GenerationReward.filter({ custom_data: verified.customData }, "created_date", 2, 0);
        if (rows.length !== 1 || !rows[0]?.user_id) {
          throw new GenerationRewardError("invalid_reward_claim", "Unknown reward attempt.", 400);
        }
        // Unity supplies no event timestamp: the first authenticated delivery must
        // arrive during the issued 24-hour window. Exact duplicates remain safe.
        callback = { ...verified, userID: rows[0].user_id, timestamp: Date.now() };
      } else {
        callback = await verifyAdMobCallback(req.url);
      }
      const attemptID = rewardUUID(callback.customData.split(".")[0]);
      const issued = await rewardAttempt(
        entities.GenerationReward,
        callback.userID,
        attemptID,
      );
      if (!issued || issued.custom_data !== callback.customData) {
        throw new GenerationRewardError(
          "invalid_reward_claim",
          "Invalid generation reward callback.",
          400,
        );
      }
      const result = await withGenerationWriterLease({
          lifecycleStore: entities.BillingIdentityLifecycle,
          userID: callback.userID,
          action: async (guard) =>
            await grantVerifiedGenerationReward({
              store: entities.GenerationReward,
              guard,
              callback,
            }),
        });
      return unity ? new Response("1", { headers: { "Content-Type": "text/plain", "Cache-Control": "no-store" } }) : Response.json(result);
    }
    const user = await base44.auth.me();
    if (!user?.id) {
      return Response.json({ error: "Unauthorized" }, { status: 401 });
    }
    const body = await req.json().catch(() => ({}));
    if (!["status", "prepare", "claim_status"].includes(body.action)) {
      throw new GenerationRewardError(
        "invalid_action",
        "Unknown generation reward action.",
        400,
      );
    }
    const [entitlements, grants] = await Promise.all([
      entities.Entitlement.filter(
        { user_id: user.id },
        "-last_verified_at",
        100,
        0,
      ),
      entities.MembershipGrant.filter(
        { user_id: user.id },
        "-created_date",
        100,
        0,
      ),
    ]);
    if (entitlements.length === 100 || grants.length === 100) {
      throw new GenerationRewardError(
        "membership_unavailable",
        "Membership could not be verified.",
        503,
      );
    }
    const verified = applyAdminGenerationGrant(
      resolveGenerationMembership(entitlements),
      grants,
    );
    const adUnit = configuredRewardAdUnit();
    return Response.json(
      await withGenerationWriterLease({
        lifecycleStore: entities.BillingIdentityLifecycle,
        userID: user.id,
        action: async (guard) => {
          if (body.action === "status") await enrollRewardGeneration({
            store: entities.GenerationRewardEnrollment, guard, userID: user.id,
            supportedProvider: body.supported_reward_provider, clientBuild: body.client_build,
          });
          const enabled = await rewardedGenerationEnabledForUser(entities.GenerationRewardEnrollment, user.id);
          const membership = enabled ? verified : applyCasadaGenerationAccess(verified);
          const status = await generationRewardStatus({
            rewardStore: entities.GenerationReward,
            quotaStore: entities.AiGenerationUsage,
            userID: user.id,
            unlimited: membership.active,
            enabled,
            testUser: !enabled && isGenerationRewardTester(user.id),
            adUnit,
          });
          if (body.action === "status") return status;
          if (body.action === "claim_status") {
            const row = await rewardAttempt(
              entities.GenerationReward,
              user.id,
              rewardUUID(body.attempt_id),
            );
            if (!row) {
              throw new GenerationRewardError(
                "reward_not_found",
                "This generation reward was not found.",
                404,
              );
            }
            return {
              ...status,
              state: row.state !== "pending"
                ? "earned"
                : Date.now() > Date.parse(row.issued_at) + 86_700_000
                ? "expired"
                : "pending",
              attempt_id: row.attempt_id,
            };
          }
          const testOffer = !enabled && "test_ad_available" in status &&
            status.test_ad_available === true;
          if ((!enabled && !testOffer) || !adUnit) {
            throw new GenerationRewardError(
              "reward_ads_unavailable",
              "Rewarded ads are not available yet.",
              503,
            );
          }
          if (
            !testOffer && (membership.active || (status.free_remaining ?? 0) > 0 ||
              status.bonus_credits > 0)
          ) {
            throw new GenerationRewardError(
              "reward_not_needed",
              "A generation is already available. No ad is needed.",
            );
          }
          const prepared = await prepareRewardAttempt({
            store: entities.GenerationReward,
            guard,
            userID: user.id,
            requestID: rewardUUID(body.request_id),
            adUnit,
          });
          return { ...status, ...prepared, ...unityAttemptFields(prepared.ad_unit_id, prepared.custom_data) };
        },
      }),
    );
  } catch (error) {
    const status = Number((error as any)?.status || 503);
    const code = String((error as any)?.code || "reward_unavailable");
    return Response.json({
      error: error instanceof Error
        ? error.message
        : "Generation rewards are unavailable.",
      code,
      retryable: status >= 500,
    }, { status: status >= 400 && status <= 599 ? status : 503 });
  }
});
