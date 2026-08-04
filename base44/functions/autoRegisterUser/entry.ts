import { createClientFromRequest } from 'npm:@base44/sdk@0.8.31';

// Auto-invite a user to this app right after they verify their email.
// Called from Register.jsx after verifyOtp so new users don't get stuck on Welcome
// in "Public (no login)" mode.
Deno.serve(async (req) => {
  try {
    const body = await req.json().catch(() => ({}));
    const email = (body?.email || '').trim().toLowerCase();

    if (!email) {
      return Response.json({ error: 'Email required' }, { status: 400 });
    }

    const base44 = createClientFromRequest(req);

    // Use service role to invite the user as a regular app user.
    // If they already exist, this is a no-op.
    try {
      await base44.asServiceRole.users.inviteUser(email, 'user');
    } catch (inviteErr) {
      // Already invited / already exists — that's fine.
      console.log('inviteUser note:', inviteErr?.message || inviteErr);
    }

    return Response.json({ success: true, email });
  } catch (error) {
    console.error('autoRegisterUser error:', error);
    return Response.json({ error: error.message }, { status: 500 });
  }
});