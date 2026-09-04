import { requiresPremiumProfileChange } from "./profile-membership.ts";

function assert(value: unknown) {
  if (!value) throw new Error("assertion failed");
}
const free = {
  avatar: "🕵️",
  spy_card_theme: "field",
  spy_card_accent: "signal_red",
  spy_card_badge: "operative",
};
Deno.test("basic styles and added eagle avatar remain free", () => {
  assert(!requiresPremiumProfileChange(free, { ...free, avatar: "🦅" }));
  assert(!requiresPremiumProfileChange(free, { ...free, avatar: "🥷" }));
});
Deno.test("new premium style selection requires membership", () => {
  for (
    const change of [{ avatar: "🃏" }, { spy_card_theme: "blacksite" }, {
      spy_card_accent: "verified_green",
    }, { spy_card_badge: "ghost" }]
  ) {
    assert(requiresPremiumProfileChange(free, { ...free, ...change }));
  }
});
Deno.test("rollout and expiry never strip already-saved styles", () => {
  const existing = { ...free, avatar: "🃏", spy_card_theme: "dossier" };
  assert(
    !requiresPremiumProfileChange(existing, {
      ...existing,
      display_name: "New name",
    }),
  );
  assert(!requiresPremiumProfileChange(existing, free));
});
