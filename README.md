# SpyClash

SpyClash is a social-deduction game for iPhone with local and online play, custom word packs, room sharing, StoreKit membership, and an integrated online service.

## Source-available, not open source

The source is public so people can inspect the implementation and propose improvements to the official project. It is **not** released under an OSI-approved open-source license.

You may view the code, create a GitHub fork, make a local working copy, and modify it only as needed to prepare a contribution to this repository. You may not reuse the code or assets in another project, publish a clone, deploy your own SpyClash service, redistribute builds, or use the repository for commercial or non-commercial products without prior written permission.

See [LICENSE.md](LICENSE.md) for the controlling terms.

## Contributing

Contributions are welcome through pull requests. Every contributor must:

1. Read [CONTRIBUTING.md](CONTRIBUTING.md).
2. Accept [CLA.md](CLA.md) in the pull-request template.
3. Keep each pull request focused and include appropriate verification.
4. Wait for maintainer review; contributors do not receive direct access to the protected default branch.

Submitting a pull request does not grant permission to use the rest of SpyClash outside the contribution workflow.

## Repository layout

- `SpyClash/` — SwiftUI iOS application.
- `SpyClash.xcodeproj/` — primary Xcode project.
- Backend entities, authentication configuration, and server functions are included for contribution review.
- `StoreKit/` — local StoreKit test configuration.
- `scripts/` — contributor bootstrap utilities.

## Local setup

Requirements:

- macOS with a current Xcode release.
- iOS 17 or newer simulator/device target.
- Optional: XcodeGen if regenerating the project from `project.yml`.

After cloning:

```bash
open SpyClash.xcodeproj
```

Select your own Apple development team for device builds. Never commit signing certificates, provisioning profiles, private keys, `.env` files, or backend, Apple, or Stripe secrets.

## Assets and third-party material

`Rajdhani-Bold.ttf` is distributed under the SIL Open Font License 1.1. Its license is included at `LICENSES/Rajdhani-OFL-1.1.txt` and takes precedence over `LICENSE.md` for that font file.

The iOS app includes an in-app Third-Party Acknowledgements screen containing the applicable notices for Rajdhani, Socket.IO Client Swift, and Starscream.

App Store media remain subject to `LICENSE.md` and any file-specific third-party terms. Their publication does not grant reuse rights.

SpyClash names, logos, icons, and trade dress are not licensed for use in other products. See [TRADEMARKS.md](TRADEMARKS.md).

## Security

Do not disclose credentials or exploitable vulnerabilities in public issues. Follow [SECURITY.md](SECURITY.md).
