import { createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import {
  type AdminGrantRecord,
  applyAdminGenerationGrant,
  canGenerate,
  type EntitlementRecord,
  generationUsageMetadata,
  resolveGenerationMembership,
} from "./membership.ts";
import {
  canonicalQuotaRecord,
  quotaKey,
  totalQuotaUsage,
  utcUsageDate,
} from "./quota.ts";
import {
  filterSafeCommunityStrings,
  requireSafeCommunityText,
  safeCommunityTextForDisplay,
} from "./content-safety.ts";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import {
  type GenerationWriteGuard,
  withGenerationWriterLease,
} from "./generation-write-lifecycle.ts";

function errorMessage(error: unknown) {
  return error instanceof Error
    ? error.message
    : String(error || "Internal error");
}

type QuotaReservation = {
  allowed: boolean;
  usedBefore: number;
  usedAfter: number;
  recordId?: string;
};

async function reserveGenerationQuota(
  store: any,
  userId: string,
  tier: "free" | "limitless",
  guard: GenerationWriteGuard,
): Promise<QuotaReservation> {
  const now = new Date();
  const key = quotaKey(userId, now);
  const usageDate = utcUsageDate(now);

  for (let attempt = 0; attempt < 4; attempt += 1) {
    const records = await store.filter(
      { quota_key: key },
      "created_date",
      20,
      0,
    );
    const usedBefore = totalQuotaUsage(records);
    if (!canGenerate(tier, usedBefore)) {
      return { allowed: false, usedBefore, usedAfter: usedBefore };
    }

    const generatedAt = new Date().toISOString();
    const canonical = canonicalQuotaRecord(records);
    if (!canonical?.id) {
      // Initialize at zero, then re-read and reserve through the same atomic
      // compare-and-increment path as every later request. Concurrent first
      // requests may create duplicate zero rows, but none can bypass the cap.
      await guard.boundary(() =>
        store.create({
          quota_key: key,
          user_id: userId,
          usage_date: usageDate,
          generations_used: 0,
        })
      );
      continue;
    }

    const canonicalCount = Number(canonical.generations_used || 0);
    const result: any = await guard.boundary<any>(() =>
      store.updateMany(
        { id: canonical.id, generations_used: canonicalCount },
        {
          $inc: { generations_used: 1 },
          $set: { last_generated_at: generatedAt },
        },
      )
    );
    if (result?.updated === 1) {
      return {
        allowed: true,
        usedBefore,
        usedAfter: usedBefore + 1,
        recordId: canonical.id,
      };
    }
  }

  throw new Error("AI usage changed concurrently. Retry the request.");
}

async function releaseGenerationQuota(
  store: any,
  reservation: QuotaReservation,
  guard: GenerationWriteGuard,
) {
  if (!reservation.allowed || !reservation.recordId) return;
  try {
    await guard.boundary(() =>
      store.updateMany(
        { id: reservation.recordId },
        { $inc: { generations_used: -1 } },
      )
    );
  } catch (error) {
    // Fail closed: an unsuccessful rollback may consume one slot but can never
    // grant additional client-controlled quota.
    console.error(
      "generateWordPack quota rollback error:",
      errorMessage(error),
    );
  }
}

function clampCount(value: unknown) {
  const count = Number(value);
  if (!Number.isFinite(count)) return 12;
  return Math.max(5, Math.min(100, Math.round(count)));
}

function cleanWord(value: unknown) {
  return String(value || "")
    .replace(/^[\s,;.\-–—"'`]+|[\s,;.\-–—"'`]+$/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

function uniqueWords(values: unknown[]) {
  const seen = new Set<string>();
  const words: string[] = [];

  for (const rawValue of values || []) {
    const pieces = String(rawValue || "").split(/[,;]/);
    for (const piece of pieces) {
      const word = cleanWord(piece);
      const key = word.toLowerCase();
      if (!word || seen.has(key)) continue;
      seen.add(key);
      words.push(word);
    }
  }

  return words;
}

function removeExcludedWords(values: unknown[], excludedWords: string[]) {
  const excluded = new Set(excludedWords.map((word) => word.toLowerCase()));
  return uniqueWords(values).filter((word) =>
    !excluded.has(word.toLowerCase())
  );
}

async function invokeWordPackLLM(
  base44: any,
  theme: string,
  count: number,
  alreadyUsed: string[] = [],
  guard: GenerationWriteGuard,
): Promise<{ words?: unknown[]; category?: unknown }> {
  const exclusions = alreadyUsed.length
    ? `\n\nDO NOT repeat any of these already-used items: ${
      alreadyUsed.join(", ")
    }.`
    : "";

  return await guard.boundary<any>(() =>
    base44.integrations.Core.InvokeLLM({
      prompt:
        `You are setting up a Spyfall-style social deduction party game. The theme/category is: "${theme}".

Generate exactly ${count} specific, well-known, recognizable items from this theme.

Requirements:
- Use the SAME LANGUAGE as the theme input. If the theme is Russian, respond in Russian; if English, respond in English.
- For proper names from games, movies, brands, products, songs, and characters, prefer the official/original name unless a famous official localization exists.
- Items must be concrete nouns or names that work as secret words in a party deduction game.
- Items must be widely recognizable and relevant as of 2024-2025.
- Exclude profanity, hate speech, sexual or exploitative material, threats, harassment, and encouragement of self-harm.
- No explanations, numbering, generic placeholders, or duplicates.
- If you cannot safely reach ${count} without inventing, return fewer real items.${exclusions}

Return ONLY JSON: {"words": [...unique strings...], "category": "short display category"}`,
      add_context_from_internet: true,
      response_json_schema: {
        type: "object",
        properties: {
          words: {
            type: "array",
            items: { type: "string" },
          },
          category: { type: "string" },
        },
      },
    })
  );
}

function lifecycleHTTPStatus(error: unknown): number {
  if (!(error instanceof BillingIdentityLifecycleError)) {
    return Number((error as { status?: number })?.status || 500);
  }
  return ["deletion_in_progress", "active_lease", "cas_contention"].includes(
      error.code,
    )
    ? 409
    : 503;
}

Deno.serve(async (req) => {
  try {
    const base44 = createClientFromRequest(req);
    const user = await base44.auth.me();

    if (!user?.id) {
      return Response.json({ error: "Unauthorized" }, { status: 401 });
    }

    const body = await req.json().catch(() => ({}));
    const theme = requireSafeCommunityText(
      cleanWord(body?.theme).slice(0, 80),
      "Theme",
    );
    const count = clampCount(body?.count);
    const excludedWords = filterSafeCommunityStrings(uniqueWords(
      Array.isArray(body?.exclude_words) ? body.exclude_words : [],
    )).slice(0, 200);

    if (!theme) {
      return Response.json({ error: "Theme is required" }, { status: 400 });
    }

    let entitlements: EntitlementRecord[] = [];
    let entitlementReadError: unknown = null;
    try {
      entitlements = await base44.asServiceRole.entities.Entitlement.filter(
        { user_id: user.id },
        "-last_verified_at",
        100,
        0,
      );
    } catch (error) {
      entitlementReadError = error;
      console.error(
        "generateWordPack membership verification error:",
        errorMessage(error),
      );
    }

    let adminGrants: AdminGrantRecord[] = [];
    let adminGrantReadError: unknown = null;
    try {
      adminGrants = await base44.asServiceRole.entities.MembershipGrant.filter(
        { user_id: user.id },
        "-created_date",
        100,
        0,
      );
    } catch (error) {
      adminGrantReadError = error;
      console.error("generateWordPack grant read error:", errorMessage(error));
    }

    const membership = applyAdminGenerationGrant(
      resolveGenerationMembership(entitlements),
      adminGrants,
    );
    if (!membership.active && (entitlementReadError || adminGrantReadError)) {
      return Response.json({
        error: "Membership could not be verified. Try again shortly.",
        code: "membership_unavailable",
        active: false,
        tier: null,
        status: "unknown",
        benefits: null,
        retryable: true,
      }, { status: 503 });
    }
    return await withGenerationWriterLease({
      lifecycleStore: base44.asServiceRole.entities.BillingIdentityLifecycle,
      userID: user.id,
      action: async (guard) => {
        const quotaStore = base44.asServiceRole.entities.AiGenerationUsage;
        let reservation: QuotaReservation;
        try {
          reservation = await reserveGenerationQuota(
            quotaStore,
            user.id,
            membership.tier,
            guard,
          );
        } catch (error) {
          if (error instanceof BillingIdentityLifecycleError) throw error;
          console.error(
            "generateWordPack quota reservation error:",
            errorMessage(error),
          );
          return Response.json({
            error: "AI usage could not be reserved. Try again shortly.",
            code: "quota_unavailable",
            active: membership.active,
            tier: membership.tier,
            status: "unknown",
            providers: membership.providers,
            benefits: membership.benefits,
            retryable: true,
          }, { status: 503 });
        }
        const usage = generationUsageMetadata(
          membership.tier,
          reservation.usedBefore,
        );

        if (!reservation.allowed) {
          return Response.json(
            {
              error: "Daily AI generation limit reached. Try again tomorrow.",
              code: "daily_ai_limit_reached",
              active: membership.active,
              tier: membership.tier,
              status: membership.active ? "active" : "inactive",
              providers: membership.providers,
              benefits: membership.benefits,
              ...usage,
            },
            { status: 429 },
          );
        }

        let words: string[];
        let category: string;
        try {
          const firstPass = await invokeWordPackLLM(
            base44,
            theme,
            count,
            excludedWords,
            guard,
          );
          words = filterSafeCommunityStrings(
            removeExcludedWords(firstPass?.words || [], excludedWords),
          );
          category = safeCommunityTextForDisplay(
            cleanWord(firstPass?.category),
            theme,
          );

          if (words.length < count && words.length < count * 0.8) {
            const secondPass = await invokeWordPackLLM(
              base44,
              theme,
              count - words.length,
              [...excludedWords, ...words],
              guard,
            );
            words = filterSafeCommunityStrings(removeExcludedWords(
              [...words, ...(secondPass?.words || [])],
              excludedWords,
            ));
          }

          words = words.slice(0, count);
          if (words.length < 2) {
            await releaseGenerationQuota(quotaStore, reservation, guard);
            return Response.json({
              error: "AI did not return enough playable words.",
            }, { status: 502 });
          }
        } catch (error) {
          await releaseGenerationQuota(quotaStore, reservation, guard);
          throw error;
        }

        const generationCount = reservation.usedAfter;
        try {
          // Compatibility/display mirror only. The admin-only quota entity
          // above remains authoritative.
          await guard.boundary(() =>
            base44.auth.updateMe({
              ai_generations_today: generationCount,
              last_ai_generation_date: new Date().toISOString(),
            })
          );
        } catch (error) {
          if (error instanceof BillingIdentityLifecycleError) throw error;
          console.error(
            "generateWordPack usage mirror error:",
            errorMessage(error),
          );
        }

        return Response.json({
          name: category,
          category,
          words,
          active: membership.active,
          tier: membership.tier,
          status: membership.active ? "active" : "inactive",
          providers: membership.providers,
          benefits: membership.benefits,
          ...generationUsageMetadata(membership.tier, generationCount),
        });
      },
    });
  } catch (error) {
    console.error("generateWordPack error:", errorMessage(error));
    const status = lifecycleHTTPStatus(error);
    return Response.json({ error: errorMessage(error) }, {
      status: status >= 400 && status < 600 ? status : 500,
    });
  }
});
