# Interface settings — iOS 1.0.1 (141)

Open the pull-down command menu → Settings. The page is a full-height sheet; it does not replace the selected tab. Available to FREE and LIMITLESS accounts, with EN/RU/ES/UK copy.

## SpyClash visual language

Build 141 replaces the rejected native grouped Form with a custom scroll layout. It reuses the app's `SpyWordmark`, `SpyPanel`, `CutCornerShape`, `CornerStroke`, `SpyWebPressStyle`, `SpyButtonStyle`, and `SpyModal`: black/graphite surfaces, red selection states, Rajdhani headings, monospaced captions, numbered sections, and cut-corner controls. There is no system navigation bar, rounded list section, menu picker, or native-looking switch.

Custom switches keep native Toggle accessibility representations. Inline choices expose their selected state and have at least 48-point touch targets. The reset dialog disables/hides the page beneath it, focuses the confirmation control for accessibility, and supports the escape action. Preference storage and app-wide consumers are unchanged.

## Implemented controls

| Setting | Actual consumer | Original default |
| --- | --- | --- |
| Reduce motion | `SpyReduceMotion` combines the app preference with iOS Reduce Motion in existing animation-aware views/styles | Off; iOS always takes priority |
| Background effects | Removes the shared `SpyBackground` decorative layers and `SpyLaserScanLayer` timeline | On |
| Stronger contrast | Shared secondary text and border tokens in `SpyTheme` | Off |
| Small labels | Shared micro/mono fonts, command-menu titles, optional dock labels (0.90× / 1× / 1.15×) | Standard |
| Navigation labels | Adds text beneath icons inside the existing dock; keeps its actions and badges | Off |
| Haptic feedback | Central `HapticManager`, including LIMITLESS Core Haptics and fallback feedback | Standard |

Presets are Original, Calm (reduced motion, no background effects, no app-generated haptics), and Readable (stronger contrast, larger small labels, dock labels). Individual edits can override a preset. Changes apply immediately.

This is not a global text-size or color-theme override: hardcoded fonts/colors are unchanged. Red brand/error semantics, premium Spycard styles, game rules/timers, membership checks, and system-generated haptics remain independent. The page's copy states these boundaries.

## Persistence and safety

- Codable preferences live in one versioned local UserDefaults key, `spyclash.interface.v1`.
- DEBUG `--spyclash-ui-preview` uses a separate `spyclash.interface.preview.v1` key so preview testing cannot alter normal preferences.
- Missing/unknown/malformed fields fall back independently to original values.
- Reset requires confirmation and removes only the interface preferences key.
- No backend call, account update, StoreKit purchase, Stripe change, production deployment, or App Store operation is part of this feature.

## Verification

- Debug Simulator build/install/launch on iPhone 17, iOS 26.5.
- 420 native tests passed on build 141, including the 12 preference/default/migration/persistence/isolation tests added in build 140.
- Runtime checks: command menu → Settings → close; Readable updates the preview and actual dock; Calm removes the shared background; settings survive process relaunch; soft haptics enable the sample button and Off disables it; reset cancellation preserves changes and confirmation restores defaults.
- Release Simulator build and bundle gate passed; the gate's 43 regression tests also passed. This is not a signed device/archive or an App Store upload.
- Physical haptic feel and final design acceptance require a human check; Simulator cannot verify vibration.

Preview launch arguments:

```text
--spyclash-ui-preview --spyclash-preview-tab=profile --spyclash-preview-lang=ru --spyclash-preview-limitless --spyclash-preview-sheet=settings
```
