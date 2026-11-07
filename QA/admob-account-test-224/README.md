# Supervised own-account rewarded test — build 224

The user authorized one real in-app rewarded viewing and one additional generation for their own account, keeping advertising and new generation limits off for all others. The production global switches remain false.

A separate server capability is derived from the exact authenticated account ID in a comma-separated test allowlist. It does not enable quotas or change membership. The iOS test controls additionally require a signed Debug Simulator build with an explicit owned AdMob-unit configuration; sample ads, physical Debug, Release, and local UI previews cannot use the control.

The test uses ordinary prepare and signed AdMob SSV processing. Client SDK completion alone cannot create a credit. Existing free generations and membership are not consumed or changed. After a verified viewing, remove the test allowlist entry; late signed callbacks remain valid for their already-issued attempt.

## Validation

22 native iOS tests passed (store and configuration), and build224 succeeded after integrating the existing remote FAN checkpoints221/222. The installed normal app passed signature, Keychain identity and installed-content hash checks. Google routing was repaired separately in checkpoint223 and the current app now opens accounts.google.com. Actual user sign-in, advertising and the real server-credit check are pending.

The first runtime install attempt used test products with an invalid Testing.framework seal; the installation gate rejected it. A clean signed runtime build was subsequently built and installed successfully. Only the latter artifact is used for the real sign-in/ad workflow.
