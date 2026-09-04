# Local StoreKit fixture

Restored from the last full LIMITLESS source snapshot, with Ukrainian metadata
added. The price and numeric identifiers in this file are **test fixture values**,
not a statement about App Store Connect configuration or current retail pricing.

Select this file manually in a local Xcode Run scheme for StoreKit diagnostics.
It is outside the app's resource directory and is not selected by the shared
release scheme. The release gate rejects any bundled `.storekit` file.

Locally signed StoreKit transactions are not Apple server-verified receipts.
The application intentionally has no production entitlement-verification bypass:
use the real Apple sandbox and the canonical backend for purchase/restore
acceptance. UI-only preview never invokes Apple purchases or the backend.
