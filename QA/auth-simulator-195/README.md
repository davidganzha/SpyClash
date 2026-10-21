# Simulator authentication repair — build 195

Verified on 21 October 2026 in the existing `SpyClash Social 193` Simulator
(its name is not the installed build number).

## Failure and cause

- Installed version was 1.0.3 (194), backend `supabase-main-candidate`.
- User-visible error: `The Base44 sign-in could not be saved securely.`
- `securityd` reported OSStatus `-34018` for SpyClash's Keychain reads and updates:
  `Client has neither application-identifier nor keychain-access-groups entitlements`.
- The installed app failed strict code-signature verification. The build log
  referenced by `QA/player-card-194/verification.json` recorded
  `CODE_SIGNING_ALLOWED=NO`.
- Authentication source was unchanged from accepted build 187. The user
  confirmed Google sign-in still worked on the physical phone running 187.

## Repair and verification

- Built 1.0.3 (195), scheme `SpyClash-Supabase-Main-Candidate`, configuration
  `SupabaseDebug`, with `CODE_SIGNING_ALLOWED=YES` and `CODE_SIGN_IDENTITY=-`.
- Installed over the existing app, preserving its data.
- Verified the installed app's strict signature including nested code.
- Xcode's Simulator application identity is embedded in the executable's
  `__TEXT,__entitlements` section; the normal code-signing entitlement dictionary
  may be empty. The Simulator identity is `3Z64QKNL54.com.spyclash.ios`.
- Observed real authenticated profile and online room on build 195.
- Terminated and relaunched the app; it restored the same authenticated profile
  and online room without another Google sign-in.
- No `-34018` errors were recorded for either new app process (83205, 83609).
- Both built and installed bundles passed the new gate, including all six
  executable signatures. Their complete bundle digest matched:
  `6330b0e3a8ce1cffa83ab27a5ec24a0a31359c5457a9edf85d5fb2ace5ff8a40`.
- Retained unsigned build 193 and 194 artifacts were rejected by the gate.
- All 15 focused offline gate/installer regression tests passed, including
  rejection of missing identity, invalid resource/nested signatures, the wrong
  default Keychain group, and an installed-content mismatch.

The new Simulator install gate validates runtime signing and app identity before
installation, then verifies the installed copy. This repair changes local build
and installation safeguards; no backend deployment or TestFlight upload occurred.
Physical build 187 was not replaced. Overnight retention was not independently
tested; the confirmed regression test is cold-process session restoration.
