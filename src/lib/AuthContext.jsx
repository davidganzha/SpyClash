import React, { createContext, useState, useContext, useEffect } from 'react';
import { base44 } from '@/api/base44Client';
import { appParams } from '@/lib/app-params';
import { createAxiosClient } from '@base44/sdk/dist/utils/axios-client';

const AuthContext = createContext(undefined);

const clearStoredAuth = () => {
  try {
    localStorage.removeItem('base44_access_token');
    localStorage.removeItem('token');
  } catch {}
  appParams.token = null;
};

const getStoredAccessToken = () => {
  try {
    return appParams.token
      || localStorage.getItem('base44_access_token')
      || localStorage.getItem('token');
  } catch {
    return appParams.token;
  }
};

// A not-yet-provisioned Base44 identity is rejected by the functions gateway
// when its bearer token is sent as the request Authorization header. Call the
// function anonymously, pass the token in the HTTPS request body, and let
// the function validate it against Base44 before deriving the user's email.
const autoRegisterCurrentUser = async () => {
  const accessToken = getStoredAccessToken();
  if (!accessToken) throw new Error('Missing access token');

  const headers = {
    'Content-Type': 'application/json',
    'X-App-Id': String(appParams.appId),
  };
  if (appParams.functionsVersion) {
    headers['Base44-Functions-Version'] = appParams.functionsVersion;
  }

  const response = await fetch(`/api/apps/${appParams.appId}/functions/autoRegisterUser`, {
    method: 'POST',
    credentials: 'omit',
    headers,
    body: JSON.stringify({ access_token: accessToken }),
  });
  const payload = await response.json().catch(() => ({}));

  if (!response.ok || payload?.success !== true) {
    throw new Error(payload?.error || 'Auto-registration failed');
  }
};

export const AuthProvider = ({ children }) => {
  const [user, setUser] = useState(null);
  const [isAuthenticated, setIsAuthenticated] = useState(false);
  const [isLoadingAuth, setIsLoadingAuth] = useState(true);
  const [isLoadingPublicSettings, setIsLoadingPublicSettings] = useState(true);
  const [authError, setAuthError] = useState(null);
  const [appPublicSettings, setAppPublicSettings] = useState(null); // Contains only { id, public_settings }

  useEffect(() => {
    checkAppState();
  }, []);

  const checkAppState = async () => {
    try {
      setIsLoadingPublicSettings(true);
      setAuthError(null);
      
      // Public settings are public. Do not attach an expired or not-yet-
      // provisioned user token to this request.
      const appClient = createAxiosClient({
        baseURL: `/api/apps/public`,
        headers: {
          'X-App-Id': appParams.appId
        },
        interceptResponses: true
      });
      
      try {
        const publicSettings = await appClient.get(`/prod/public-settings/by-id/${appParams.appId}`);
        setAppPublicSettings(publicSettings);
        
        // If we got the app public settings successfully, check if user is authenticated
        if (appParams.token) {
          await checkUserAuth();
        } else {
          setIsLoadingAuth(false);
          setIsAuthenticated(false);
        }
        setIsLoadingPublicSettings(false);
      } catch (appError) {
        console.error('App state check failed:', appError);

        const reason = appError?.data?.extra_data?.reason;
        // Handle app-level errors
        if (appError.status === 403 && reason) {
          if (reason === 'auth_required') {
            setAuthError({
              type: 'auth_required',
              message: 'Authentication required'
            });
          } else if (reason === 'user_not_registered') {
            setAuthError({
              type: 'user_not_registered',
              message: 'User not registered for this app'
            });
          } else {
            setAuthError({
              type: reason,
              message: appError.message
            });
          }
        } else {
          setAuthError({
            type: 'unknown',
            message: appError.message || 'Failed to load app'
          });
        }
        setIsLoadingPublicSettings(false);
        setIsLoadingAuth(false);
      }
    } catch (error) {
      console.error('Unexpected error:', error);
      setAuthError({
        type: 'unknown',
        message: error.message || 'An unexpected error occurred'
      });
      setIsLoadingPublicSettings(false);
      setIsLoadingAuth(false);
    }
  };

  const checkUserAuth = async (isRetry = false) => {
    try {
      // Now check if the user is authenticated
      setIsLoadingAuth(true);
      const currentUser = await base44.auth.me();
      setUser(currentUser);
      setIsAuthenticated(true);
      setIsLoadingAuth(false);
      setAuthError(null);
    } catch (error) {
      console.error('User auth check failed:', error);

      // If user auth fails, distinguish between an app-provisioning gap and
      // an expired/invalid token.
      const reason = error?.data?.extra_data?.reason;

      // Recover only from the exact Base44 provisioning error. Other 403s
      // must not silently create users.
      if (reason === 'user_not_registered' && !isRetry) {
        try {
          await autoRegisterCurrentUser();
          await checkUserAuth(true);
          return;
        } catch (e) {
          console.error('autoRegisterUser retry failed:', e);
        }
      }

      setIsLoadingAuth(false);
      setIsAuthenticated(false);
      setUser(null);

      if (reason === 'user_not_registered') {
        setAuthError({
          type: 'user_not_registered',
          message: 'User not registered for this app'
        });
      } else if (error.status === 401 || error.status === 403) {
        if (error.status === 401) clearStoredAuth();
        setAuthError({
          type: 'auth_required',
          message: 'Authentication required'
        });
      }
    }
  };

  const logout = (shouldRedirect = true) => {
    setUser(null);
    setIsAuthenticated(false);
    
    if (shouldRedirect) {
      // Use the SDK's logout method which handles token cleanup and redirect
      base44.auth.logout(window.location.href);
    } else {
      clearStoredAuth();
    }
  };

  const navigateToLogin = () => {
    // Use the SDK's redirectToLogin method
    base44.auth.redirectToLogin(window.location.href);
  };

  return (
    <AuthContext.Provider value={{ 
      user, 
      isAuthenticated, 
      isLoadingAuth,
      isLoadingPublicSettings,
      authError,
      appPublicSettings,
      logout,
      navigateToLogin,
      checkAppState
    }}>
      {children}
    </AuthContext.Provider>
  );
};

export const useAuth = () => {
  const context = useContext(AuthContext);
  if (!context) {
    throw new Error('useAuth must be used within an AuthProvider');
  }
  return context;
};
