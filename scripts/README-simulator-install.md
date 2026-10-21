# Simulator builds that can retain authentication

Build Simulator apps with signing enabled. An app compiled with
`CODE_SIGNING_ALLOWED=NO` can launch and pass preview checks while Keychain
rejects session reads and writes with `-34018`.

For the main Supabase candidate, use an explicit Simulator UDID and an isolated
build directory:

```sh
xcodebuild -project SpyClash.xcodeproj \
  -scheme SpyClash-Supabase-Main-Candidate -configuration SupabaseDebug \
  -destination 'platform=iOS Simulator,id=<SIMULATOR-UDID>' \
  -derivedDataPath /tmp/SpyClash-SignedSimulator \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build

python3 scripts/install-ios-simulator-app.py \
  --simulator '<SIMULATOR-UDID>' \
  /tmp/SpyClash-SignedSimulator/Build/Products/SupabaseDebug-iphonesimulator/SpyClash.app
```

The installer requires an available, already booted Simulator. It checks the
source before installation and checks the installed copy afterward, including
an exact content digest match. It never uninstalls, clears app data, signs an
artifact, or launches the app. A failed post-install check stops with an error;
it does not silently restore or launch another build.

To inspect an app without installing it:

```sh
python3 scripts/check-ios-simulator-bundle.py /absolute/path/SpyClash.app --json
```

Both scripts default to `com.spyclash.ios`; `--bundle-id` can select another
project test target. The gate checks the Simulator platform, full resource seal,
nested Mach-O signatures, and application/Keychain identity against the project
team. It reads both code-signature entitlements and Xcode's embedded Simulator
`__TEXT,__entitlements` section. An empty signature entitlement plist is normal
when Xcode uses that embedded section. A source `.entitlements` or `.xcent` file
alone is not evidence of the installed app's identity.

The existing distribution bundle checker deliberately permits unsigned
Simulator artifacts for compilation checks; it is not an authentication runtime
gate. After installation, verify sign-in and persistence across relaunch in the
actual Simulator. A valid bundle alone does not prove a provider login succeeded.

Focused offline checks (no Simulator writes):

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/tests/check_ios_simulator_bundle_test.py
```
