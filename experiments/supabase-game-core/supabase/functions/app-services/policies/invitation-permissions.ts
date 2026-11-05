/** Existing accounts keep friend invitations. Community invitations require
 * explicit opt-in; relationship blocks always override either preference. */
export function invitationPermissions(data: Record<string, unknown> = {}) {
  return {
    friend_invitations_allowed: data.friend_invitations_allowed !== false,
    stranger_invitations_allowed: data.stranger_invitations_allowed === true,
  };
}

export function canReceiveGameInvitation(data: Record<string, unknown>, relationshipStatus: string | null): boolean {
  if (relationshipStatus === 'blocked') return false;
  const permissions = invitationPermissions(data);
  return relationshipStatus === 'accepted'
    ? permissions.friend_invitations_allowed
    : permissions.stranger_invitations_allowed;
}

export function invitationPermissionPatch(body: Record<string, unknown>) {
  const boolean = (key: string): boolean => {
    const value = body[key];
    if (value === true || value === 'true') return true;
    if (value === false || value === 'false') return false;
    throw new Error('invalid_invitation_permissions');
  };
  return {
    friend_invitations_allowed: boolean('friend_invitations_allowed'),
    stranger_invitations_allowed: boolean('stranger_invitations_allowed'),
  };
}
