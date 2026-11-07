# Supervised own-account rewarded test — build 224

The user authorized one real in-app rewarded viewing and one additional generation for their own account, keeping advertising and new generation limits off for all others. The production global switches remain false.

A separate server capability is derived from the exact authenticated account ID in a comma-separated test allowlist. It does not enable quotas or change membership. The iOS test controls additionally require a signed Debug Simulator build with an explicit owned AdMob-unit configuration; sample ads, physical Debug, Release, and local UI previews cannot use the control.

The test uses ordinary prepare and signed AdMob SSV processing. Client SDK completion alone cannot create a credit. Existing free generations and membership are not consumed or changed. After a verified viewing, remove the test allowlist entry; late signed callbacks remain valid for their already-issued attempt.

## Validation

22 native iOS tests passed (store and configuration), and build224 succeeded after integrating the existing remote FAN checkpoints221/222. The installed normal app passed signature, Keychain identity and installed-content hash checks. Google routing was repaired separately in checkpoint223. Actual Google sign-in completed in the normal app, the authenticated User/me identity matched the visible profile, and the session survived relaunch.

The first runtime install attempt used test products with an invalid Testing.framework seal; the installation gate rejected it. A clean signed runtime build was subsequently built and installed successfully. Only the latter artifact is used for the real sign-in/ad workflow.

## Actual in-app outcome — 7 November 2026

The supervised test was enabled only for the authenticated account, SPY ID 844-010. The actual app displayed its test control with zero additional generations; existing daily generation availability stayed at 10. The app invoked the owned AdMob unit. Before any ad appeared, Google returned `Account not approved yet. <https://support.google.com/admob/answer/9905175#1>`; the error was captured from the actual store catch, not inferred from a generic UI message.

The live AdMob dashboard independently showed that the account is not approved, the app is under review, and the payment profile is complete. Existing app-ads.txt verification is a separate completed step. No ad view or earned generation was demonstrated. The Supabase gateway recorded no SSV callback during 20:02:30–20:04:30 UTC.

At 20:05:19 UTC, Base44 acknowledged clearing the personal test allowlist. A subsequent runtime snapshot confirms that the test card and watch-ad button are absent and the existing availability remains 10. No global advertising or new quota switch was enabled. No credits were synthesized and no quota, entitlement or membership records were directly edited.

CLI-authenticated entity reads returned empty arrays, but their row visibility is not independently established. These reads do not prove that no pending attempt exists or authoritatively establish balances; see `base44-ledger-read-visibility-qualification.json`. The end-to-end ad and +1 check remains blocked pending Google account approval.

This follow-up records the outcome of checkpoint224; it changes QA evidence only, not application code or build version.
