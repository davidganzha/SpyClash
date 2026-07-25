import { createClient } from "npm:@base44/sdk@0.8.31";
import {
  type AppleCredentialIdentityWriter,
  AppleSignInCredentialError,
  bindPendingAppleSignInCredentials,
  withPendingAppleCredentialBindingIdentityWriter,
} from "./apple-sign-in-credential.ts";

type AuthUser = {
  id?: string;
  email?: string | null;
  [key: string]: unknown;
};

type AuthClient = {
  auth: {
    me: () => Promise<AuthUser>;
  };
};

type SDKError = {
  status?: number;
  data?: {
    extra_data?: {
      reason?: string;
      email?: string;
    };
  };
};

type UserInvitationClient = {
  users: {
    inviteUser: (email: string, role: "user") => Promise<unknown>;
  };
};

const json = (body: unknown, init: ResponseInit = {}) => {
  const headers = new Headers(init.headers);
  headers.set("Cache-Control", "no-store");
  return Response.json(body, { ...init, headers });
};

const verifiedResponseUser = (user: AuthUser) => {
  if (typeof user.id !== "string" || !user.id || !user.email) {
    throw new Error("Authenticated user response is incomplete");
  }
  return user;
};

const getVerifiedIdentity = async (base44: AuthClient) => {
  try {
    const user = await base44.auth.me();
    if (!user?.email) throw new Error("Authenticated user has no email");
    return {
      email: user.email.toLowerCase(),
      alreadyRegistered: true,
      user,
    };
  } catch (error) {
    const sdkError = error as SDKError;
    const reason = sdkError.data?.extra_data?.reason;
    const email = sdkError.data?.extra_data?.email;

    // Base44 has verified the bearer token, but this identity is not attached
    // to the current app yet. Use only the server-provided email.
    if (reason === "user_not_registered" && email) {
      return {
        email: email.toLowerCase(),
        alreadyRegistered: false,
        user: null,
      };
    }

    throw error;
  }
};

const verifyProvisioning = async (base44: AuthClient) => {
  let lastError: unknown;

  for (const delay of [0, 100, 250]) {
    if (delay) await new Promise((resolve) => setTimeout(resolve, delay));

    try {
      const user = await base44.auth.me();
      if (user?.email) return user;
    } catch (error) {
      lastError = error;
    }
  }

  throw lastError || new Error("User provisioning could not be verified");
};

Deno.serve(async (req) => {
  try {
    const body = await req.json().catch(() => ({}));
    const accessToken = typeof body?.access_token === "string"
      ? body.access_token.trim()
      : "";
    const appleBindingTicket = typeof body?.apple_binding_ticket === "string"
      ? body.apple_binding_ticket.trim()
      : "";
    const serviceHeader = req.headers.get("Base44-Service-Authorization");
    const appId = req.headers.get("Base44-App-Id");
    const serverUrl = req.headers.get("Base44-Api-Url") || "https://base44.app";

    // A newly authenticated SSO identity is not attached to this app yet.
    // Sending its token in Authorization makes the functions gateway reject
    // the request before this function can provision the user. Accept the
    // token only in the HTTPS body, then verify it directly with Base44.
    if (!accessToken) {
      return json({ error: "Authentication required" }, { status: 401 });
    }
    if (!serviceHeader?.startsWith("Bearer ") || !appId) {
      throw new Error("Missing Base44 service context");
    }

    const userClient = createClient({
      appId,
      serverUrl,
      token: accessToken,
    });
    const identity = await getVerifiedIdentity(userClient);

    // The service token is injected by Base44 and never accepted from the
    // request body. It owns both user provisioning and the admin-only Apple
    // credential binding record.
    const serviceClient = createClient({
      appId,
      serverUrl,
      token: serviceHeader.slice("Bearer ".length),
    }) as ReturnType<typeof createClient> & UserInvitationClient;

    const appleCredentialStore =
      (serviceClient as any).entities.AppleSignInCredential;
    const billingLifecycleStore =
      (serviceClient as any).entities.BillingIdentityLifecycle;
    const bindAppleCredential = async (
      user: AuthUser,
      identityWriter?: AppleCredentialIdentityWriter,
    ) => {
      if (!appleBindingTicket) return;
      const verifiedUser = verifiedResponseUser(user);
      await bindPendingAppleSignInCredentials({
        store: appleCredentialStore,
        lifecycleStore: billingLifecycleStore,
        email: verifiedUser.email,
        userID: verifiedUser.id,
        bindingTicket: appleBindingTicket,
        identityWriter,
      });
    };

    if (identity.alreadyRegistered) {
      await bindAppleCredential(identity.user!);
      return json({
        success: true,
        already_registered: true,
        user: verifiedResponseUser(identity.user!),
      });
    }

    const provisionAndBind = async (
      identityWriter?: AppleCredentialIdentityWriter,
    ): Promise<AuthUser> => {
      // The SDK does not expose users under asServiceRole. The server-only
      // client uses the injected service token; the caller's email is never
      // trusted.
      let inviteError = null;
      try {
        await serviceClient.users.inviteUser(identity.email, "user");
      } catch (error) {
        // A concurrent request may have completed the same invite.
        inviteError = error;
      }

      let provisionedUser: AuthUser;
      try {
        provisionedUser = await verifyProvisioning(userClient);
      } catch (verificationError) {
        throw inviteError || verificationError;
      }
      await bindAppleCredential(provisionedUser, identityWriter);
      return provisionedUser;
    };

    // Validate the short-lived Apple ticket and hold its identity writer before
    // creating a Base44 User. A stale pre-deletion access token therefore
    // cannot create a phantom account and fail binding afterward.
    const provisionedUser = appleBindingTicket
      ? await withPendingAppleCredentialBindingIdentityWriter({
        store: appleCredentialStore,
        lifecycleStore: billingLifecycleStore,
        email: identity.email,
        bindingTicket: appleBindingTicket,
        operation: provisionAndBind,
      })
      : await provisionAndBind();

    return json({
      success: true,
      user: verifiedResponseUser(provisionedUser),
    });
  } catch (error) {
    console.error("autoRegisterUser error:", error);

    const sdkError = error as SDKError;
    const credentialStatus = error instanceof AppleSignInCredentialError
      ? error.status
      : undefined;
    const status = credentialStatus ||
      (sdkError.status === 401 || sdkError.status === 403
        ? sdkError.status
        : 500);
    const message = error instanceof AppleSignInCredentialError
      ? status >= 500
        ? "Apple credential binding is temporarily unavailable"
        : "Apple credential binding was rejected"
      : status === 401
      ? "Authentication required"
      : status === 403
      ? "Access denied"
      : "User provisioning failed";

    return json({ error: message }, { status });
  }
});
