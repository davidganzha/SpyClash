# SpyClash development signing recovery — 19 November 2026

The user explicitly approved creating one Apple Development certificate and two
development provisioning profiles, then signing the existing diagnostic build
1.0.4 (246). The archived old login keychain remained locked and was excluded
from the keychain search list again after the user cancelled its unlock dialog.
Do not ask for its password or use PotuzhnoSigning as a fallback.

## Verified signing identity

- Team: `3Z64QKNL54`.
- Certificate: `Apple Development: Created via API (C9Z2RND4TQ)`.
- Certificate ID: `9R5S4RFC39`.
- SHA-1: `AFAB62D325B968A3B130E1807A483F6B29744687`.
- Allowed keychain: `~/Library/Keychains/login.keychain-db`.
- Certificate expiry: 19 November 2027; always recheck validity and access.

The new private key was imported into the ordinary login keychain. The user
authorized `codesign` access through the macOS prompt. A real signature and its
verification succeeded, followed by signing all five code objects in build 246.

Always supply the explicit allowed keychain and exact fingerprint:

```sh
security find-identity -v -p codesigning "$HOME/Library/Keychains/login.keychain-db"
codesign --keychain "$HOME/Library/Keychains/login.keychain-db" \
  --sign AFAB62D325B968A3B130E1807A483F6B29744687 <other-required-options> <target>
```

Do not infer that the default keychain search list is an allowlist. This is a
development certificate; it is not a TestFlight/App Store distribution signer.

## Newly created profiles

Both profiles include only the new certificate and the registered Ganzha iPhone.
They were installed into Xcode's user provisioning-profile directory.

| Bundle | Profile | UUID |
| --- | --- | --- |
| `com.spyclash.ios` | SpyClash Ganzha Development Recovery 2026-11-19 | `3c2b52ca-5a28-4465-8f34-7581894268c0` |
| `com.spyclash.ios.widgets` | SpyClash Widgets Ganzha Development Recovery 2026-11-19 | `0aa036c1-87a9-44e2-809f-6fd5b5390480` |

The existing API credential could create the certificate but received HTTP 403
when creating profiles. The user signed in to Apple Developer in the browser;
both profiles were created there using the already approved certificate/device.
No existing certificate or profile was revoked, deleted, or replaced.

## Artifact and validation scope

- Source: immutable diagnostic archive from commit
  `7acda5678e5907044953a7d80d1e0c679f4e5918` in the
  `app-store-complete-238` worktree, build `1.0.4 (246)`.
- IPA: `.local/signing-recovery-20261119/SpyClash-1.0.4-246-Ganzha-Development.ipa`.
- SHA-256: `99aa9ba8738efe6120a02f36b644c38cbbcb464364ee09ec08ee8a1f87ee630b`.
- Detailed local receipt: `.local/signing-recovery-20261119/signed-build-receipt.json`.
- App, widget, GoogleMobileAds, UnityAds, and UserMessagingPlatform signatures
  passed verification, including recursive strict verification of the app.
- App and widget executable UUIDs still match their original debug symbols.
- Profiles match the certificate, team, exact bundle identifiers, and device.
- App entitlements retain Apple sign-in, Game Center, development push,
  application/keychain identity, and debugger access. The earlier local signing
  helper's Game Center omission was not carried over because the committed
  source requests that entitlement and the new profile grants it.
- Signing was performed on a clean copy in `/private/tmp`; the source archive
  was unchanged. This avoids Finder metadata that invalidated a first signing
  attempt under Documents.

This checkpoint changes signing guidance only. The existing build was signed
without editing app code, project settings, version numbers, or backend logic.
Device installation, runtime authentication, and App Store/TestFlight upload
were not performed by this recovery task.
