# Contributing to SpyClash

Thank you for helping improve the official SpyClash project. This repository uses a source-available contribution model: contributions are welcome, but the code is not available for independent reuse.

## Before you start

1. Read `LICENSE.md` and `CLA.md` completely.
2. Check existing issues and pull requests before starting substantial work.
3. For a large change, open an issue describing the behavior and proposed approach before implementation.
4. Never include secrets, signing material, production user data, or third-party assets you cannot redistribute.

## Development workflow

1. Fork the repository on GitHub.
2. Clone your fork only for the purpose of preparing a SpyClash contribution.
3. Create a focused branch.
4. Run `./scripts/bootstrap-public-assets.sh` to create local placeholder audio.
5. Implement and test the change.
6. Open a pull request against `main` and complete the supplied template.

## Pull-request requirements

- One coherent change per pull request.
- A clear explanation of behavior and user impact.
- Tests or reproducible verification appropriate to the change.
- No unrelated generated files or formatting churn.
- No modifications to licensing, contributor terms, trademarks, repository governance, signing settings, payment configuration, or security policy unless the Owner requested them.
- The CLA checkbox must remain checked. The automated CLA check must pass.

Only the Owner decides whether and when a pull request is merged. Opening or merging a pull request grants no access to production systems and no permission to publish a separate build or service.

## Security reports

Do not publish exploitable security details in an issue. Follow `SECURITY.md`.
