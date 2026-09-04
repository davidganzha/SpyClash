// Existing selections remain usable after rollout/expiry; only new premium
// selections require a verified entitlement. Never strip a user's saved card.
export function requiresPremiumProfileChange(
  current: Record<string, unknown>,
  next: Record<string, unknown>,
): boolean {
  const defaults: Record<string, string[]> = {
    avatar: ["🕵️", "🥷", "🧠", "🎭", "🦅"],
    spy_card_theme: ["field"],
    spy_card_accent: ["signal_red"],
    spy_card_badge: ["operative"],
  };
  return Object.entries(defaults).some(([field, free]) => {
    const value = String(next[field] || "");
    return value !== String(current[field] || "") && !free.includes(value);
  });
}
