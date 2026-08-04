export const ACCOUNT_AVATARS = Object.freeze([
  "🕵️", "🥷", "🧠", "🎭", "🃏", "👁️", "🔥", "⚡️", "🎯", "🛡️",
]);

export function accountAvatarForDisplay(avatar) {
  const candidate = String(avatar || "");
  return candidate || ACCOUNT_AVATARS[0];
}

export function canSelectAccountAvatar(avatar) {
  return ACCOUNT_AVATARS.includes(String(avatar || ""));
}

export function resolveAccountAvatarSelection(selectedAvatar, currentAvatar) {
  const selected = accountAvatarForDisplay(selectedAvatar);
  if (canSelectAccountAvatar(selected)) return selected;
  return accountAvatarForDisplay(currentAvatar);
}
