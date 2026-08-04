import React, { createContext, useCallback, useContext, useMemo, useState } from "react";
import { PUBLIC_ACCESS_MEMBERSHIP, normalizeMembership } from "@/lib/membership";

const MembershipContext = createContext(null);

export function MembershipProvider({ children }) {
  const [membership, setMembership] = useState(() => normalizeMembership(PUBLIC_ACCESS_MEMBERSHIP));

  const refreshMembership = useCallback(async () => membership, [membership]);

  const updateAiUsage = useCallback((result) => {
    const payload = result?.data ?? result ?? {};
    if (payload.ai_generations_today === null || payload.ai_generations_today === undefined) return;
    const used = Number(payload.ai_generations_today);
    if (!Number.isFinite(used)) return;

    setMembership((current) => ({
      ...current,
      ai_generations_today: used,
      ai_remaining: null,
    }));
  }, []);

  const value = useMemo(() => ({
    membership,
    tier: membership.tier,
    benefits: membership.benefits,
    hasPublicAccess: true,
    isLoadingMembership: false,
    hasResolvedMembership: true,
    membershipError: null,
    refreshMembership,
    updateAiUsage,
  }), [membership, refreshMembership, updateAiUsage]);

  return (
    <MembershipContext.Provider value={value}>
      {children}
    </MembershipContext.Provider>
  );
}

export function useMembership() {
  const context = useContext(MembershipContext);
  if (!context) {
    throw new Error("useMembership must be used within a MembershipProvider");
  }
  return context;
}
