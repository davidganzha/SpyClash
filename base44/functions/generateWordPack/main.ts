import { createClientFromRequest } from "npm:@base44/sdk@0.8.31";
import {
  type AdminGrantRecord,
  applyAdminGenerationGrant,
  applyCasadaGenerationAccess,
  canGenerate,
  CASADA_PROTOCOL_ENABLED,
  type EntitlementRecord,
  generationUsageMetadata,
  type MembershipTier,
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
} from "./content-safety.ts";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import {
  type GenerationWriteGuard,
  withGenerationWriterLease,
} from "./generation-write-lifecycle.ts";
import { invokeAIProviderWithRetry } from "./ai-provider-resilience.ts";
import {
  lookupWordPackCache,
  persistWordPackCacheVariant,
  type PreparedWordPackCacheRequest,
  prepareWordPackCacheRequest,
  pruneExpiredWordPackCacheVariants,
  wordPackTelemetryDimensions,
} from "./generation-cache.ts";
import {
  lookupIdempotentWordPackResult,
  persistIdempotentWordPackResult,
  type PreparedWordPackIdempotency,
  prepareWordPackIdempotency,
  pruneExpiredWordPackRequestResults,
  WordPackIdempotencyConflictError,
  WordPackIdempotencyUnavailableError,
} from "./generation-idempotency.ts";
import {
  assertNoKnownNamedThemeDrift,
  BASE44_WORD_PACK_MODEL,
  buildWordPackPrompt,
  createOpenAIWordPackProviderFromEnv,
  type OpenAIWordPackProvider,
  shouldFallbackFromDirectWordPackProvider,
  WORD_PACK_CACHE_VERSION,
  type WordPackGenerationResult,
  wordPackResponseSchema,
} from "./openai-word-pack-provider.ts";
import {
  applyWordPackSelfAudit,
  WordPackQualityGateError,
  type WordPackSelfAuditCandidate,
} from "./word-pack-quality.ts";

function errorMessage(error: unknown) {
  return error instanceof Error
    ? error.message
    : String(error || "Internal error");
}

const STORED_WORD_PACK_CATEGORY = "AI GENERATED";

type QuotaReservation = {
  allowed: boolean;
  usedBefore: number;
  usedAfter: number;
  recordId?: string;
};

type AIInvocationState = {
  directProvider: OpenAIWordPackProvider | null;
  directProviderDisabled: boolean;
  directAttempts: number;
  base44Attempts: number;
  aiDurationMilliseconds: number;
  qualityRejectedCount: number;
  qualityReplacementCount: number;
  fallbackUsed: boolean;
};

async function reserveGenerationQuota(
  store: any,
  userId: string,
  tier: MembershipTier,
  guard: GenerationWriteGuard,
): Promise<QuotaReservation> {
  // CASADA has no daily allowance to reserve. Avoid turning a legacy quota
  // store outage into a generator outage for an authenticated user.
  if (tier === "limitless") {
    return { allowed: true, usedBefore: 0, usedAfter: 0 };
  }

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
      const word = cleanWord(piece).slice(0, 120).trim();
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

function optionalRequestID(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.normalize("NFKC").trim();
  return normalized || null;
}

function createAIInvocationState(): AIInvocationState {
  let directProvider: OpenAIWordPackProvider | null = null;
  let configurationFailed = false;
  try {
    directProvider = createOpenAIWordPackProviderFromEnv();
  } catch (error) {
    configurationFailed = true;
    // A malformed optional direct-provider configuration must not make word
    // generation unavailable. Release checks still prevent shipping it
    // accidentally, while the existing Base44 integration remains usable.
    console.error(
      "generateWordPack direct provider configuration error:",
      errorMessage(error),
    );
  }
  return {
    directProvider,
    directProviderDisabled: configurationFailed,
    directAttempts: 0,
    base44Attempts: 0,
    aiDurationMilliseconds: 0,
    qualityRejectedCount: 0,
    qualityReplacementCount: 0,
    fallbackUsed: configurationFailed,
  };
}

async function currentGenerationCount(store: any, userID: string) {
  const records = await store.filter(
    { quota_key: quotaKey(userID) },
    "created_date",
    20,
    0,
  );
  return totalQuotaUsage(records);
}

async function invokeWordPackLLM(
  base44: any,
  theme: string,
  count: number,
  alreadyUsed: string[] = [],
  guard: GenerationWriteGuard,
  state: AIInvocationState,
): Promise<WordPackGenerationResult> {
  const measured = async <T>(operation: () => Promise<T>): Promise<T> => {
    const startedAt = Date.now();
    try {
      return await operation();
    } finally {
      state.aiDurationMilliseconds += Math.max(0, Date.now() - startedAt);
    }
  };

  if (state.directProvider && !state.directProviderDisabled) {
    try {
      const directResult = await invokeAIProviderWithRetry<
        WordPackGenerationResult
      >({
        operation: () => {
          state.directAttempts += 1;
          return measured(() =>
            guard.boundary(() =>
              state.directProvider!.generate({
                theme,
                count,
                alreadyUsed,
              })
            )
          );
        },
        onRetry: ({ attempt, nextAttempt, delayMilliseconds, error }) => {
          console.warn(
            `generateWordPack direct AI retry ${attempt}->${nextAttempt} after ${delayMilliseconds}ms:`,
            errorMessage(error),
          );
        },
      });
      // Semantic/schema failures do not benefit from repeating the same direct
      // request. The provider marks them non-transient, and this local guard
      // routes known drift immediately to the Base44 fallback instead.
      assertNoKnownNamedThemeDrift(theme, directResult.words);
      state.qualityRejectedCount += directResult.qualityRejectedCount ?? 0;
      state.qualityReplacementCount += directResult.qualityReplacementCount ??
        0;
      return directResult;
    } catch (error) {
      if (!shouldFallbackFromDirectWordPackProvider(error)) throw error;
      state.directProviderDisabled = true;
      state.fallbackUsed = true;
      console.warn(
        "generateWordPack direct provider fallback:",
        errorMessage(error),
      );
    }
  }

  const candidate = await invokeAIProviderWithRetry<WordPackSelfAuditCandidate>(
    {
      operation: () => {
        state.base44Attempts += 1;
        return measured(() =>
          guard.boundary<WordPackSelfAuditCandidate>(() =>
            base44.integrations.Core.InvokeLLM({
              model: BASE44_WORD_PACK_MODEL,
              prompt: buildWordPackPrompt({
                theme,
                count,
                alreadyUsed,
              }),
              response_json_schema: wordPackResponseSchema(theme, count),
            })
          )
        );
      },
      onRetry: ({ attempt, nextAttempt, delayMilliseconds, error }) => {
        console.warn(
          `generateWordPack Base44 AI retry ${attempt}->${nextAttempt} after ${delayMilliseconds}ms:`,
          errorMessage(error),
        );
      },
    },
  );

  const audited = applyWordPackSelfAudit(candidate, count, alreadyUsed);
  state.qualityRejectedCount += audited.rejectedCount;
  state.qualityReplacementCount += audited.replacementCount;
  return {
    words: audited.words,
    category: audited.category,
    exhausted: audited.exhausted,
  };
}

function lifecycleHTTPStatus(error: unknown): number {
  if (!(error instanceof BillingIdentityLifecycleError)) {
    const candidate = Number(
      (error as { status?: number; statusCode?: number })?.status ??
        (error as { statusCode?: number })?.statusCode ??
        500,
    );
    return Number.isInteger(candidate) ? candidate : 500;
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

    const requestID = optionalRequestID(body?.request_id);
    // Legacy clients do not send request_id. Keep their explicit Regenerate
    // behavior fresh instead of unexpectedly replaying a cached pack.
    const preferFresh = body?.prefer_fresh === true || requestID === null;
    const cacheRequest: PreparedWordPackCacheRequest =
      await prepareWordPackCacheRequest({
        userID: user.id,
        theme,
        // The theme wording is the sole language authority. Keep one cache
        // namespace across app/profile locales; translated themes remain
        // isolated by the normalized theme itself.
        language: "und",
        promptVersion: WORD_PACK_CACHE_VERSION,
        requestedCount: count,
        exclusions: excludedWords,
      });
    const idempotency: PreparedWordPackIdempotency | null = requestID
      ? await prepareWordPackIdempotency({
        userID: user.id,
        requestID,
        request: cacheRequest,
      })
      : null;

    let entitlements: EntitlementRecord[] = [];
    let entitlementReadError: unknown = null;
    if (!CASADA_PROTOCOL_ENABLED) {
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
    }

    let adminGrants: AdminGrantRecord[] = [];
    let adminGrantReadError: unknown = null;
    if (!CASADA_PROTOCOL_ENABLED) {
      try {
        adminGrants = await base44.asServiceRole.entities.MembershipGrant
          .filter(
            { user_id: user.id },
            "-created_date",
            100,
            0,
          );
      } catch (error) {
        adminGrantReadError = error;
        console.error(
          "generateWordPack grant read error:",
          errorMessage(error),
        );
      }
    }

    const membership = applyCasadaGenerationAccess(
      applyAdminGenerationGrant(
        resolveGenerationMembership(entitlements),
        adminGrants,
      ),
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
        const cacheStore = base44.asServiceRole.entities.AiWordPackCacheVariant;
        const idempotencyStore =
          base44.asServiceRole.entities.AiWordPackRequestResult;

        if (idempotency) {
          try {
            const replay = await lookupIdempotentWordPackResult({
              store: idempotencyStore,
              identity: idempotency,
            });
            if (replay) {
              let generationCount = Math.max(
                0,
                Math.floor(Number(user.ai_generations_today) || 0),
              );
              try {
                generationCount = await currentGenerationCount(
                  quotaStore,
                  user.id,
                );
              } catch (error) {
                // Replaying an already completed request must not fail merely
                // because the usage display read is briefly unavailable.
                console.error(
                  "generateWordPack replay usage read error:",
                  errorMessage(error),
                );
              }
              console.info(
                "generateWordPack metrics:",
                JSON.stringify({
                  ...wordPackTelemetryDimensions(cacheRequest),
                  returned_count: replay.words.length,
                  cache_hit: false,
                  request_replayed: true,
                  direct_attempts: 0,
                  base44_attempts: 0,
                  base44_model: BASE44_WORD_PACK_MODEL,
                  single_pass_quality_gate: true,
                  exhaustion_verification_used: false,
                  ai_duration_ms: 0,
                  quality_repair_used: false,
                  quality_rejected_count: 0,
                  quality_replacement_count: 0,
                  fallback_used: false,
                  exhausted: replay.exhausted,
                  source: "idempotency",
                }),
              );
              return Response.json({
                name: theme,
                category: theme,
                words: replay.words,
                exhausted: replay.exhausted,
                cache_hit: false,
                request_replayed: true,
                active: membership.active,
                tier: membership.tier,
                protocol: membership.protocol,
                expires_at: membership.expires_at,
                status: membership.active ? "active" : "inactive",
                providers: membership.providers,
                benefits: membership.benefits,
                ...generationUsageMetadata(membership.tier, generationCount),
              });
            }
          } catch (error) {
            if (error instanceof WordPackIdempotencyConflictError) throw error;
            console.error(
              "generateWordPack idempotency lookup error:",
              errorMessage(error),
            );
            // Fail before quota/provider work. Continuing would turn a network
            // retry into a second charged generation.
            throw new WordPackIdempotencyUnavailableError();
          }
        }

        // Legacy metering remains available if CASADA is ever disabled. An
        // exact request_id replay above still bypasses it because that replay
        // is the same logical user action.
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
            protocol: membership.protocol,
            expires_at: membership.expires_at,
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
              protocol: membership.protocol,
              expires_at: membership.expires_at,
              status: membership.active ? "active" : "inactive",
              providers: membership.providers,
              benefits: membership.benefits,
              ...usage,
            },
            { status: 429 },
          );
        }

        let words: string[] = [];
        let category = theme;
        let exhausted = false;
        let cacheHit = false;
        let cacheVariantKey: string | undefined;
        let exhaustionVerificationUsed = false;
        let aiState: AIInvocationState = {
          directProvider: null,
          directProviderDisabled: false,
          directAttempts: 0,
          base44Attempts: 0,
          aiDurationMilliseconds: 0,
          qualityRejectedCount: 0,
          qualityReplacementCount: 0,
          fallbackUsed: false,
        };
        try {
          if (!preferFresh) {
            try {
              const hit = await lookupWordPackCache({
                store: cacheStore,
                request: cacheRequest,
                selectionSeed: requestID ?? cacheRequest.cacheKey,
              });
              if (hit) {
                const safeWords = filterSafeCommunityStrings(
                  removeExcludedWords(hit.words, excludedWords),
                ).slice(0, count);
                if (
                  safeWords.length >= 2 &&
                  (safeWords.length >= count || hit.exhausted)
                ) {
                  words = safeWords;
                  category = theme;
                  exhausted = hit.exhausted;
                  cacheHit = true;
                  cacheVariantKey = hit.variantKey;
                }
              }
            } catch (error) {
              console.error(
                "generateWordPack cache lookup error:",
                errorMessage(error),
              );
            }
          }

          if (!cacheHit) {
            aiState = createAIInvocationState();
            const firstPass = await invokeWordPackLLM(
              base44,
              theme,
              count,
              excludedWords,
              guard,
              aiState,
            );
            words = filterSafeCommunityStrings(
              removeExcludedWords(firstPass?.words || [], excludedWords),
            ).slice(0, count);
            assertNoKnownNamedThemeDrift(theme, words);
            exhausted = firstPass?.exhausted === true && words.length < count;
            if (exhausted) {
              exhaustionVerificationUsed = true;
              const verification = await invokeWordPackLLM(
                base44,
                theme,
                Math.max(2, count - words.length),
                [...excludedWords, ...words],
                guard,
                aiState,
              );
              const additionalWords = filterSafeCommunityStrings(
                removeExcludedWords(
                  verification.words,
                  [...excludedWords, ...words],
                ),
              );
              assertNoKnownNamedThemeDrift(theme, additionalWords);
              words = uniqueWords([...words, ...additionalWords]).slice(
                0,
                count,
              );
              exhausted = verification.exhausted === true &&
                words.length < count;
            }
            category = theme;
            if (words.length < count && !exhausted) {
              throw new WordPackQualityGateError();
            }
          }

          if (words.length < 2) {
            await releaseGenerationQuota(quotaStore, reservation, guard);
            return Response.json({
              error: "AI did not return enough playable words.",
            }, { status: 502 });
          }

          if (!cacheHit) {
            try {
              const cached = await guard.boundary(() =>
                persistWordPackCacheVariant({
                  store: cacheStore,
                  request: cacheRequest,
                  result: {
                    category: STORED_WORD_PACK_CATEGORY,
                    words,
                    exhausted,
                  },
                })
              );
              cacheVariantKey = cached.variant_key;
            } catch (error) {
              console.error(
                "generateWordPack cache persistence error:",
                errorMessage(error),
              );
            }
          }

          if (idempotency) {
            try {
              await guard.boundary(() =>
                persistIdempotentWordPackResult({
                  store: idempotencyStore,
                  identity: idempotency,
                  result: {
                    category: STORED_WORD_PACK_CATEGORY,
                    words,
                    exhausted,
                    cacheVariantKey,
                  },
                })
              );
            } catch (error) {
              if (error instanceof WordPackIdempotencyConflictError) {
                throw error;
              }
              console.error(
                "generateWordPack idempotency persistence error:",
                errorMessage(error),
              );
              throw new WordPackIdempotencyUnavailableError();
            }

            try {
              await guard.boundary(() =>
                pruneExpiredWordPackRequestResults({
                  store: idempotencyStore,
                  userID: user.id,
                  limit: 10,
                })
              );
            } catch (error) {
              console.error(
                "generateWordPack idempotency prune error:",
                errorMessage(error),
              );
            }
          }

          // For idempotent clients this is strictly after the replay result
          // commits, so cleanup latency cannot cause another provider call.
          // Legacy clients also write reusable variants, so they must take
          // part in bounded physical TTL cleanup as well.
          try {
            await guard.boundary(() =>
              pruneExpiredWordPackCacheVariants({
                store: cacheStore,
                userID: user.id,
                limit: 10,
              })
            );
          } catch (error) {
            console.error(
              "generateWordPack cache prune error:",
              errorMessage(error),
            );
          }
        } catch (error) {
          await releaseGenerationQuota(quotaStore, reservation, guard);
          throw error;
        }

        const generationCount = reservation.usedAfter;
        if (membership.tier !== "limitless") {
          try {
            // Compatibility/display mirror only. The admin-only quota entity
            // above remains authoritative.
            await guard.boundary(() =>
              base44.asServiceRole.entities.User.update(user.id, {
                ai_generations_today: generationCount,
                last_ai_generation_date: new Date().toISOString(),
              })
            );
          } catch (error) {
            // This User field is a compatibility/display mirror only. Quota is
            // already committed in the server-owned entity, so a mirror or
            // lease-assertion outage must not replace valid words with a 503.
            console.error(
              "generateWordPack usage mirror error:",
              errorMessage(error),
            );
          }
        }

        const source = cacheHit
          ? "cache"
          : aiState.base44Attempts > 0
          ? "base44_integration"
          : "openai_direct";
        console.info(
          "generateWordPack metrics:",
          JSON.stringify({
            ...wordPackTelemetryDimensions(cacheRequest),
            returned_count: words.length,
            cache_hit: cacheHit,
            request_replayed: false,
            direct_attempts: aiState.directAttempts,
            base44_attempts: aiState.base44Attempts,
            base44_model: BASE44_WORD_PACK_MODEL,
            single_pass_quality_gate: true,
            exhaustion_verification_used: exhaustionVerificationUsed,
            ai_duration_ms: aiState.aiDurationMilliseconds,
            quality_repair_used: aiState.qualityRejectedCount > 0 ||
              aiState.qualityReplacementCount > 0,
            quality_rejected_count: aiState.qualityRejectedCount,
            quality_replacement_count: aiState.qualityReplacementCount,
            fallback_used: aiState.fallbackUsed,
            exhausted,
            source,
          }),
        );

        return Response.json({
          name: category,
          category,
          words,
          exhausted,
          cache_hit: cacheHit,
          request_replayed: false,
          active: membership.active,
          tier: membership.tier,
          protocol: membership.protocol,
          expires_at: membership.expires_at,
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
    const normalizedStatus = status >= 400 && status < 600 ? status : 500;
    const code = String((error as { code?: unknown })?.code || "").trim();
    const retryable = (error as { retryable?: unknown })?.retryable === true;
    return Response.json({
      error: errorMessage(error),
      ...(code ? { code } : {}),
      ...(retryable ? { retryable: true } : {}),
    }, {
      status: normalizedStatus,
      headers: retryable || normalizedStatus === 503
        ? { "retry-after": "2" }
        : undefined,
    });
  }
});
