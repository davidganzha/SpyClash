# SpyClash SwiftUI Migration

## Product Goal

SpyClash is a native SwiftUI iOS app. The web project is a reference for product logic and copy, not the interface source of truth. Base44 remains the backend space for auth, data, functions, subscriptions, and operational resources.

## Non-Negotiables

- No WebView shell for core gameplay, rooms, auth, profile, packs, pricing, leaderboard, or history.
- SwiftUI owns navigation, layout, animation, accessibility, and interaction design.
- 3D visuals and motion are native app assets, not web decorations.
- Base44 is accessed through typed Swift service boundaries, not directly from views.
- The visual language is native iOS: dark graphite theme, system materials, Liquid Glass where available, minimal red accent.
- The dock stays small and contextual, with no more than four primary destinations.
- Command screens should avoid vertical scroll. Use fixed native scenes with adaptive compression instead.
- Web screens can inform behavior, but iOS UX can be better, simpler, and more native.

## Current State

- Native SwiftUI target exists in `SpyClash/`.
- Root state is owned by `AppState`.
- Backend access is centralized in `Base44Client`.
- Major screens already exist as SwiftUI views:
  - `WelcomeView`
  - `AuthView`
  - `HomeView`
  - `GameView`
  - `LocalGameView`
  - `WordPacksView`
  - `LeaderboardView`
  - `HistoryView`
  - `ProfileView`
  - `QRSheets`
- The biggest debt is not missing SwiftUI files; it is that several screens still behave and read like web panels instead of native iOS flows.

## Migration Tracks

### 1. App Shell

Goal: make the iOS app feel native before any screen-specific polish.

- Keep `AppShellView` as the single root shell.
- Keep `AppTab` contextual: Home, Packs, Profile, and Room only when an active room exists.
- Move secondary actions into command menus, sheets, and screen-local controls.
- Use iOS system transitions, materials, and haptics consistently.

### 2. Design System

Goal: one reusable SwiftUI design language.

- `SpyTheme` owns colors, typography, corner radius, spacing, and button language.
- `SpyPanel` becomes the default glass card surface.
- `SpyButtonStyle` becomes the default button family.
- `SpyBackground` stays calm and dark, without web-style scanline noise.
- `SpyOrbSceneView` provides reusable native 3D atmosphere for hero, room, reveal, and premium moments.
- Add focused components instead of rebuilding rows and cards inside giant views.

### 2.5. Motion And 3D

Goal: make SpyClash feel alive without becoming noisy.

- Use small, readable motion: entrance, state change, focus, success, and room lifecycle transitions.
- Use 3D sparingly for high-value moments: Home hero, room creation, spy reveal, win screen, subscription.
- Device tilt can add subtle same-direction parallax, with stronger movement on decorative 3D and weaker movement on controls.
- Keep all 3D non-blocking and decorative unless it directly communicates state.
- Prefer SceneKit/SwiftUI-native rendering over web canvas or video loops.
- Respect Reduce Motion and keep motion disabled or heavily reduced when the system asks for it.
- Respect system performance: no uncontrolled per-frame SwiftUI updates for decorative motion.

### 3. Home Flow

Goal: Home is the native start point, not a dashboard.

- Home is a no-scroll command scene.
- Landing: title, one Play action, one How to Play action.
- Play expands inline into Local and Online choices.
- Online expands inline into Create Room, Join Code, Scan QR.
- Pricing lives in Profile or a contextual sheet, not in the primary Home block unless relevant.

### 3.5. Scroll Policy

Goal: scrolling appears only when it has a clear job.

- No scroll for Home, role reveal, room state summaries, auth entry, or short command screens.
- Use adaptive compression: smaller 3D visual, hidden secondary copy, tighter spacing.
- Keep scroll for real collections: leaderboards, history, packs, legal text, long player rosters.
- Avoid hiding primary actions below the fold.

### 4. Online Room

Goal: room is a native multiplayer control room.

- Waiting room: room code, invite, player roster, host controls.
- Ready check: one clear primary action and player readiness.
- Active game: role, word visibility, timer, question/answer flow, vote flow.
- Post-game: winner, stats, replay, leave.
- Long action lists move into `Menu` or sheets.

### 5. Local Game

Goal: local mode is a polished native party-game flow.

- Setup should feel like a compact iOS wizard, not a form dump.
- Role reveal should use full-screen cards and native gestures.
- Timer and round state should be glanceable.
- End screen should clearly explain winner and next step.

### 6. Packs

Goal: word packs feel like a native library/editor.

- Pack list uses native rows/cards with search and clear empty states.
- Editor is a focused sheet with validation.
- AI pack generation remains Base44-backed, but the UX is SwiftUI-native.

### 7. Account/Profile

Goal: profile becomes settings + identity + account state.

- Stats stay compact.
- Legal, language, subscription, logout, delete account go into grouped settings.
- Leaderboard and history are secondary destinations, not dock clutter.

### 8. Backend Boundary

Goal: keep backend complexity out of views.

- `Base44Client` remains the only network gateway.
- Views call app/feature actions, not raw endpoints.
- Preserve Google auth through `ASWebAuthenticationSession`.
- Keep deep links native: `spyclash://join`, auth callback, reset password.
- Web URLs are fallback/share targets, not app navigation.

## First Refactor Pass

1. Split giant views into feature folders:
   - `Views/Game/`
   - `Views/Local/`
   - `Views/Home/`
   - `Views/Packs/`
   - `Views/Profile/`
2. Extract repeated components:
   - `GlassActionButton`
   - `GlassListRow`
   - `StatusPill`
   - `PlayerAvatarRow`
   - `EmptyStateView`
   - `AsyncStateView`
3. Replace web-like rectangular/cut-corner controls with iOS continuous-radius materials.
4. Make every screen pass a basic iPhone build before moving to the next one.

## Definition of Done

- No core UX depends on web rendering.
- All primary gameplay flows are SwiftUI-native.
- Base44 is a backend service boundary only.
- The app builds for iOS Simulator and physical iPhone.
- The first screen feels like a paid, native iOS product within three seconds.
