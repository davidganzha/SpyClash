import { createClient } from 'npm:@base44/sdk';

const json = (body, init = {}) => Response.json(body, {
  ...init,
  headers: {
    'Cache-Control': 'no-store',
    ...(init.headers || {}),
  },
});

const getVerifiedIdentity = async (userClient) => {
  try {
    const user = await userClient.auth.me();
    if (!user?.email) throw new Error('Authenticated user has no email');
    return { email: user.email.toLowerCase(), alreadyRegistered: true };
  } catch (error) {
    const reason = error?.data?.extra_data?.reason;
    const email = error?.data?.extra_data?.email;

    // Base44 has verified the bearer token, but this identity is not attached
    // to the current app yet. Use only the server-provided email.
    if (reason === 'user_not_registered' && email) {
      return { email: email.toLowerCase(), alreadyRegistered: false };
    }

    throw error;
  }
};

const verifyProvisioning = async (userClient) => {
  let lastError;

  for (const delay of [0, 100, 250]) {
    if (delay) await new Promise((resolve) => setTimeout(resolve, delay));

    try {
      const user = await userClient.auth.me();
      if (user?.email) return user;
    } catch (error) {
      lastError = error;
    }
  }

  throw lastError || new Error('User provisioning could not be verified');
};

Deno.serve(async (req) => {
  try {
    const body = await req.json().catch(() => ({}));
    const accessToken = typeof body?.access_token === 'string'
      ? body.access_token.trim()
      : '';
    const serviceHeader = req.headers.get('Base44-Service-Authorization');
    const appId = req.headers.get('Base44-App-Id');
    const serverUrl = req.headers.get('Base44-Api-Url') || 'https://base44.app';

    if (!accessToken) {
      return json({ error: 'Authentication required' }, { status: 401 });
    }
    if (!serviceHeader?.startsWith('Bearer ') || !appId) {
      throw new Error('Missing Base44 service context');
    }

    const userClient = createClient({
      appId,
      serverUrl,
      token: accessToken,
    });
    const identity = await getVerifiedIdentity(userClient);

    if (identity.alreadyRegistered) {
      return json({ success: true, already_registered: true });
    }

    // The SDK does not expose users under asServiceRole. Build a server-only
    // client with the injected service token so the supported users module can
    // perform the invite. The caller's email is never trusted.
    const serviceClient = createClient({
      appId,
      serverUrl,
      token: serviceHeader.slice('Bearer '.length),
    });

    let inviteError = null;
    try {
      await serviceClient.users.inviteUser(identity.email, 'user');
    } catch (error) {
      // A concurrent request may have completed the same invite. Verification
      // below is the source of truth; otherwise surface the original failure.
      inviteError = error;
    }

    try {
      await verifyProvisioning(userClient);
    } catch (verificationError) {
      throw inviteError || verificationError;
    }

    return json({ success: true });
  } catch (error) {
    console.error('autoRegisterUser error:', error);

    const status = error?.status === 401 || error?.status === 403
      ? error.status
      : 500;
    const message = status === 401
      ? 'Authentication required'
      : status === 403
        ? 'Access denied'
        : 'User provisioning failed';

    return json({ error: message }, { status });
  }
});