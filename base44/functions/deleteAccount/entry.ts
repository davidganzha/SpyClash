import { createClientFromRequest } from 'npm:@base44/sdk@0.8.31';

Deno.serve(async (req) => {
  try {
    const base44 = createClientFromRequest(req);
    const user = await base44.auth.me();

    if (!user) {
      return Response.json({ error: 'Unauthorized' }, { status: 401 });
    }

    // Best-effort cleanup of user's content
    try {
      const history = await base44.asServiceRole.entities.GameHistory.filter({ player_email: user.email });
      for (const h of history || []) {
        try { await base44.asServiceRole.entities.GameHistory.delete(h.id); } catch (e) { console.error('history item', h.id, e?.message); }
      }
    } catch (e) {
      console.error('history cleanup failed', e?.message);
    }

    try {
      const packs = await base44.asServiceRole.entities.WordPack.filter({ owner_email: user.email });
      for (const p of packs || []) {
        try { await base44.asServiceRole.entities.WordPack.delete(p.id); } catch (e) { console.error('pack item', p.id, e?.message); }
      }
    } catch (e) {
      console.error('packs cleanup failed', e?.message);
    }

    try {
      await base44.asServiceRole.entities.User.delete(user.id);
    } catch (e) {
      console.error('user delete failed', e?.message);
      return Response.json({ error: 'Failed to delete user record' }, { status: 500 });
    }

    return Response.json({ success: true });
  } catch (error) {
    console.error('deleteAccount fatal', error?.message, error?.stack);
    return Response.json({ error: error?.message || 'Internal error' }, { status: 500 });
  }
});