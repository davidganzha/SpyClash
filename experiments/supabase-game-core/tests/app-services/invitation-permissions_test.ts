import assert from 'node:assert/strict';
import { canReceiveGameInvitation, invitationPermissions, invitationPermissionPatch } from '../../supabase/functions/app-services/policies/invitation-permissions.ts';

Deno.test('invitations default to friends, require community consent, and blocks override all sources', () => {
  assert.deepEqual(invitationPermissions(), {friend_invitations_allowed: true, stranger_invitations_allowed: false});
  assert.equal(canReceiveGameInvitation({}, 'accepted'), true);
  for (const status of [null, 'pending', 'declined']) assert.equal(canReceiveGameInvitation({}, status), false);
  assert.equal(canReceiveGameInvitation({stranger_invitations_allowed: true}, null), true);
  assert.equal(canReceiveGameInvitation({friend_invitations_allowed: false, stranger_invitations_allowed: true}, 'accepted'), false);
  assert.equal(canReceiveGameInvitation({friend_invitations_allowed: true, stranger_invitations_allowed: true}, 'blocked'), false);
  assert.equal(canReceiveGameInvitation({stranger_invitations_allowed: 'true'}, null), false);
});

Deno.test('settings accept native and form booleans, reject ambiguous or incomplete payloads', () => {
  assert.deepEqual(invitationPermissionPatch({friend_invitations_allowed: 'false', stranger_invitations_allowed: true}), {friend_invitations_allowed: false, stranger_invitations_allowed: true});
  for (const value of [undefined, null, 1, 'yes', '']) {
    assert.throws(() => invitationPermissionPatch({friend_invitations_allowed: value, stranger_invitations_allowed: false}));
  }
});
