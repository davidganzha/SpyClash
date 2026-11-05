# SpyClash 1.0.3 (213): consistent FAN typography

FAN voting now uses explicit monospaced typography for its heading, vote requirement, selected-player subtitle, player-sheet heading, explanation, and player names. FAN settings use the same style for the toggle label and explanations. The bundled Rajdhani font has no Cyrillic glyphs, so using it for Russian headings had allowed a proportional system fallback.

This change only adjusts typography. The three choices and their existing voting actions are unchanged. Build metadata is synchronized to 213; marketing version remains 1.0.3. No production function or client distribution was published.

The signed Simulator build and installation checks passed. Existing native FAN UI checks cover 3, 4, 8, and 12 players, the separate candidate list, and all three recorded-vote states. Final run identifiers and screenshots are stored in `release/evidence/fan-typography-213/`. These are Simulator preview checks, not live multiplayer or physical-device validation.
