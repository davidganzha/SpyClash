import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";
import { useAuth } from "@/lib/AuthContext";
import {
  getCommunityState,
  retryPendingRoomInviteCleanups,
} from "@/lib/communityActions";
import {
  communityAttentionCount,
  communityPollIntervalMilliseconds,
  shouldPauseCommunityPolling,
} from "@/lib/communityProtocol";

const CommunityContext = createContext(null);

export function CommunityProvider({ children }) {
  const { isAuthenticated, user } = useAuth();
  const [state, setState] = useState(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState(null);
  const inFlight = useRef(null);
  const stateGeneration = useRef(0);
  const sessionUserId = useRef(user?.id || null);
  sessionUserId.current = user?.id || null;

  const installState = useCallback((nextState) => {
    stateGeneration.current += 1;
    setState(nextState);
  }, []);

  const refresh = useCallback(async ({ silent = false } = {}) => {
    if (!isAuthenticated || !user?.id) return null;
    if (inFlight.current) return inFlight.current;
    const expectedUserId = user.id;
    const expectedGeneration = stateGeneration.current;
    if (!silent) setIsLoading(true);

    const request = (async () => {
      try {
        let nextState = await getCommunityState();
        const cleared = await retryPendingRoomInviteCleanups();
        if (cleared > 0) nextState = await getCommunityState();
        if (
          sessionUserId.current === expectedUserId &&
          stateGeneration.current === expectedGeneration
        ) {
          setState(nextState);
          setError(null);
        }
        return nextState;
      } catch (nextError) {
        if (sessionUserId.current === expectedUserId) setError(nextError);
        throw nextError;
      } finally {
        if (sessionUserId.current === expectedUserId) setIsLoading(false);
        inFlight.current = null;
      }
    })();
    inFlight.current = request;
    return request;
  }, [isAuthenticated, user?.id]);

  useEffect(() => {
    if (!isAuthenticated || !user?.id) {
      stateGeneration.current += 1;
      setState(null);
      setError(null);
      setIsLoading(false);
      return undefined;
    }

    if (!shouldPauseCommunityPolling(window.location.pathname)) {
      void refresh().catch(() => {});
    }
    let timer = null;
    let disposed = false;
    const schedule = () => {
      if (disposed) return;
      timer = window.setTimeout(async () => {
        if (
          document.visibilityState !== "hidden"
          && !shouldPauseCommunityPolling(window.location.pathname)
        ) {
          await refresh({ silent: true }).catch(() => {});
        }
        schedule();
      }, communityPollIntervalMilliseconds(window.location.pathname));
    };
    schedule();
    return () => {
      disposed = true;
      if (timer) window.clearTimeout(timer);
    };
  }, [isAuthenticated, user?.id, refresh]);

  const value = useMemo(() => ({
    state,
    setState: installState,
    isLoading,
    error,
    refresh,
    attentionCount: communityAttentionCount(state),
  }), [state, isLoading, error, refresh, installState]);

  return (
    <CommunityContext.Provider value={value}>
      {children}
    </CommunityContext.Provider>
  );
}

export function useCommunity() {
  const context = useContext(CommunityContext);
  if (!context) throw new Error("useCommunity must be used within CommunityProvider");
  return context;
}
