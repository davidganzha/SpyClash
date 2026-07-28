# SpyClash 1.0 (39) — local release evidence

Prepared on 28 July 2026 for Apple ID `6793534085`, team
`David Ganzha (3Z64QKNL54)`, bundle ID `com.spyclash.ios`, Base44 app
`69a0e57fa939f578082f8091`, and `https://spyclash.com`.

This is a local checkpoint only. The Web candidate is **not deployed**.
Build 39 is **not uploaded** or selected in App Store Connect. The app is not
submitted to App Review, promoted through TestFlight, or released.

## Interactive Web candidate

- Local checkout: `.web-reference/spyclash-web`
- Base commit: `ff8e46759870260c3a192d694197e355bc69ff8f`
- Candidate commit: `fb0860f0a603f5020ca059f48ae930d213ae0ce9`
- Public support email: `yanushevych.mr@gmail.com`
- Dist files: `6`
- `DIST_INVENTORY_SHA256`:
  `c02535dfd3e7d1c54f8bbdecb5e210cb2c209dc822b10e66975709e7d0b3bb19`

The digest is SHA-256 of the sorted dist inventory. Each row contains
`<file_sha256>\t<byte_count>\t<relative_path>`.

The candidate preserves the current interactive Web/iOS parity application.
It does not replace it with the older public-only static landing candidate.
It upgrades the Base44 SDK and vulnerable transitive packages, removes unused
`jspdf`, `react-quill`, and direct `lodash`, moves the SPA to
`react-router-dom 7.18.1`, adds current search/social metadata, and makes the
monitored support email a source-level fallback even if site metadata is
stripped.

Clean detached-checkout validation:

- `npm ci`: passed
- Web tests: `35/35` passed
- typecheck: passed
- lint: passed
- production build: passed
- deprecated release-marker scan: passed
- support, Privacy Policy, and Terms routes: rendered locally
- Support → Privacy Policy client-side navigation: passed
- Privacy Policy and Terms hard reloads: passed
- support email, description, Open Graph title, and canonical Open Graph URL:
  present

`npm audit --omit=dev` reports two package nodes for one high advisory in the
unstable React Server Components mode of React Router. SpyClash is a
declarative browser SPA and does not import or use the affected RSC APIs.
No production critical, moderate, or low advisories remain. Downgrading Router
reintroduces multiple broader advisories; an eventual literal-zero result
requires a separate React 19 / React Router 8 migration.

The authenticated Home/Community/game surfaces cannot be proven against the
static local preview because the Base44 public backend rejects that local
origin with `404`. They remain a mandatory live post-deploy smoke test after
the reviewed notification-function cutover.

## Read-only Production preflight

The fresh Base44 inspection at `2026-07-28T07:01:43Z` confirmed:

- Production schema: `22` entities
- Production schema digest:
  `1be1657ecc65e54e918dd2361f913bd881471f53d0f3cb2f67afb8d2560b811e`
- Current Production functions: `16`
- Reviewed target functions: `17`
- Notification Step B plan digest:
  `4896ee8d3d852edd634f336da7ca919f6e3d627691bcf16aef5d6ce3359ac5c5`
- Add only: `notificationAction`
- Update only: `communityAction`, `gameRoomAction`, `deleteAccount`,
  `pushNotificationAction`
- Delete: none
- Preserve byte-for-byte: the other `12` Production functions
- Deployment order: `notificationAction`, `communityAction`,
  `gameRoomAction`, `deleteAccount`, `pushNotificationAction`

Local-only drift in `advanceRound`, `autoRegisterUser`, `checkSubscription`,
and `createCheckout` is explicitly excluded from the reviewed Step B target.
The read-only preflight made no Production change.

## Reproducible Web patches

The nested Web checkout has no GitHub remote. The two scoped commits are
preserved in the root GitHub checkpoint as:

- `WebCandidate/0001-chore-finalize-public-support-contact.patch.gz`
  - SHA-256:
    `f3048035de81ac8c6da702af5e8ae04b246ef63eeee684616fde3d8b7469c075`
- `WebCandidate/0002-chore-harden-web-release-candidate.patch.gz`
  - SHA-256:
    `9f8b851610768ef327e7d99fdc537d92fa9e7c3abbb6d377a5db3da89226d333`

Decompress and apply them in order to Web commit
`ff8e46759870260c3a192d694197e355bc69ff8f`.

## iOS candidate

- Marketing version: `1.0`
- Current project version: `39`
- `project.yml` and `SpyClash.xcodeproj/project.pbxproj`: synchronized
- Release Simulator build/install/launch: passed on iPhone 17 Pro Max,
  iOS 26.5
- Runtime UI snapshot: `SpyClash version 1.39v`
- Debug test configuration: `42/42` passed
- Release bundle gate: passed for `com.spyclash.ios 1.0 (39)`
- Release gate regression suite: `18/18` passed
- Embedded Live Activity extension: present
- 1024 px opaque App Store icon: present
- Privacy manifest: exact match to reviewed source
- Audio/playback paths and `.storekit`: absent

The Simulator bundle is intentionally unsigned for distribution, so effective
signed-entitlement checks were skipped. This is compile/runtime evidence, not
a substitute for the final signed archive, provisioning, or physical-device
proof.

## Known pre-submit gates

- Notification Step B functions are prepared but not deployed.
- The interactive Web candidate is prepared but not deployed.
- Authenticated cross-platform Web/iOS behavior requires live smoke testing
  after those two exact operations.
- Existing Build 28 store screenshots are technically valid but visually stale
  and show `1.28v`; recapture localized screenshots from the final candidate.
- A signed archive/IPA from the final build and physical-device install/launch
  proof are still required.
- App Store Connect metadata and privacy answers require a final read-only
  portal audit before stopping at the enabled Submit for Review button.
- Do not press Submit for Review.
