import { useCallback, useMemo, useState } from "react";
import { useMembership } from "@/lib/MembershipContext";

/**
 * Universal access keeps usage only as optional telemetry. It never blocks generation,
 * shows a countdown, or derives access from a paid entitlement.
 */
export function useGlobalQuota() {
  const { membership, updateAiUsage } = useMembership();
  const [usedToday, setUsedToday] = useState(() => membership.ai_generations_today);

  const refresh = useCallback(async () => usedToday, [usedToday]);

  const increment = useCallback((result) => {
    const reportedUsage = Number(
      result?.ai_generations_today
      ?? result?.data?.ai_generations_today,
    );
    if (Number.isFinite(reportedUsage)) {
      setUsedToday(reportedUsage);
      updateAiUsage(result);
      return;
    }
    setUsedToday((current) => (Number(current) || 0) + 1);
  }, [updateAiUsage]);

  const quota = useMemo(() => ({ count: usedToday }), [usedToday]);

  return {
    quota,
    usedToday,
    timeLeft: null,
    quotaTimeLeft: null,
    dailyLimit: null,
    DAILY_LIMIT: Infinity,
    remaining: null,
    isUnlimited: true,
    increment,
    isLimitReached: false,
    refresh,
  };
}
