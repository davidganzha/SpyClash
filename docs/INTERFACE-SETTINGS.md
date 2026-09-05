# Settings — iOS 1.0.1 (142)

Open the pull-down command menu → Settings. The page is a full-height sheet; it does not replace the selected tab. Available to FREE and LIMITLESS accounts, with EN/RU/ES/UK copy.

## SpyClash visual language

The page keeps the custom SpyClash scroll layout introduced in build 141: `SpyWordmark`, `SpyPanel`, `CutCornerShape`, `CornerStroke`, `SpyWebPressStyle`, `SpyButtonStyle`, and `SpyModal`. Black/graphite surfaces, red accents, Rajdhani headings, monospaced captions, and numbered sections remain. Build 142 restores real SwiftUI switch-style `Toggle` controls and adds a native red-tinted `Slider`, as requested. The hero's mode/autosave row, divider, and live-preview text/icons were removed; the Interface heading remains.

Native switches retain system interaction and accessibility. Inline choices expose their selected state and have at least 48-point touch targets. The reset dialog disables/hides the page beneath it, focuses the confirmation control for accessibility, and supports the escape action.

## Implemented controls

| Setting | Actual consumer | Original default |
| --- | --- | --- |
| Interface scale | Native slider, 100–120% in 5% steps; `spyInterfaceScale()` at the window root and every app-authored sheet/full-screen presentation root | 100% |
| Reduce motion | `SpyReduceMotion` combines the app preference with iOS Reduce Motion in existing animation-aware views/styles | Off; iOS always takes priority |
| Background effects | Removes the shared `SpyBackground` decorative layers and `SpyLaserScanLayer` timeline | On |
| Stronger contrast | Shared secondary text and border tokens in `SpyTheme` | Off |
| Small labels | Shared micro/mono fonts, command-menu titles, optional dock labels (0.90× / 1× / 1.15×) | Standard |
| Navigation labels | Adds text beneath icons inside the existing dock; keeps its actions and badges | Off |
| Haptic feedback | Central `HapticManager`, including LIMITLESS Core Haptics and fallback feedback | Standard |
| Language | Moved from Profile; existing `AppState.setLanguage` local persistence and account synchronization | Existing selection retained |
| Radar invitations | Moved from Profile; existing `RadarPolicySettingsView`, Ask first / Join automatically, local persistence and account-sync/retry status | Existing selection retained |

Presets are Original, Calm (reduced motion, no background effects, no app-generated haptics), and Readable (stronger contrast, larger small labels, dock labels). Each preset restores interface scale to 100%. Individual edits can override a preset. Changes apply immediately except drag-based scale changes, which apply on release so the slider does not move under the finger. Accessibility adjustments apply without requiring a drag.

Whole-interface scale divides the available layout viewport before applying a visual transform, allowing scrollable content to reflow instead of cropping an enlarged canvas. It scales app text, buttons, panels, and navigation together without changing view identity. Apply the modifier exactly once per presentation root, not to individual cards. System keyboard and Apple payment dialogs remain system-sized. Small-label size is an independent setting; color semantics, premium Spycard styles, game rules/timers, membership checks, and system-generated haptics are unchanged.

## Persistence and safety

- Codable preferences live in one versioned local UserDefaults key, `spyclash.interface.v1`.
- DEBUG `--spyclash-ui-preview` uses a separate `spyclash.interface.preview.v1` key so preview testing cannot alter normal preferences.
- Missing/unknown/malformed fields fall back independently to original values. Old records without scale decode to 100%; invalid/non-finite/out-of-range scale is normalized.
- Reset requires confirmation and removes only the interface preferences key. It does not reset language, radar invitations, profile, purchases, or game data; the button and confirmation explicitly say so.
- Language and radar controls reuse their existing account synchronization. Moving them does not migrate or replace storage. DEBUG language changes in UI fixtures remain in memory, with no normal-language persistence or account update.
- No backend implementation/deploy, StoreKit purchase, Stripe change, or App Store operation was performed for this change.

## Verification

- Debug Simulator build/install/launch on the separate `SpyClash Settings — iPhone 17`, iOS 26.5, keeping the other simulator's app undisturbed.
- 424 native tests passed, including 16 preference/scale/default/migration/persistence/isolation tests.
- Separate `SpyClash-Settings-UI` scheme: 2 UI tests passed. Actual slider drag reaches 120%, the close button becomes 1.2× wider and remains hittable, a native switch changes state at maximum scale, and scale survives process relaunch. Preset reset restores 100% and original control width.
- UI tests also cover Profile → command menu → LIMITLESS → close at 120%, language changing the open settings sheet to English, radar selection, reset preserving language/radar, and absence of both controls from Profile. Retained test screenshots were inspected for the settings sheet, Profile, and LIMITLESS at 120%, plus the moved controls.
- Release Simulator build and bundle gate passed; the gate's 43 regression tests also passed. This is not a signed device/archive or an App Store upload.
- Physical haptic feel and final design acceptance require a human check; Simulator cannot verify vibration.

The UI tests use DEBUG fixtures and never buy a subscription or change a real account. Account synchronization behavior is reused, not claimed as newly verified against production. The test target is not embedded in app/archive products and is separate from the normal unit-test scheme.

Preview launch arguments:

```text
--spyclash-ui-preview --spyclash-preview-tab=profile --spyclash-preview-lang=ru --spyclash-preview-limitless --spyclash-preview-sheet=settings
```
