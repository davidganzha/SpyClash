# Apple native v2 production deployment — build176

The explicitly approved `appleAuthBroker` deployment to canonical Base44 app `69a0e57fa939f578082f8091` completed on **2026-10-14 at 10:32:32 UTC**. The approved source checkpoint is `b1bfceb1339c79a85621cc2fd950898daf70bf81`.

A fresh authenticated CLI pull before deployment matched all 13 baseline files in the approved manifest. Only the Apple entry changes and new `native-handoff.ts` module were deployed; the live billing lifecycle helper and all other helpers were preserved byte for byte.

The first two submissions were rejected because the CLI uploaded paths relative to the nested entry while retaining that nested entry in metadata. Remote runtime remained unchanged after both rejections. Flattening the ignored upload package without changing runtime bytes resolved the packaging mismatch. Base44 normalized the uploaded paths back to their original layout. The final single-function deployment returned exit 0 and `deployed_count: 1`.

Readback at **10:33:52 UTC** matched all **14 approved files** exactly, including function metadata. Entry SHA-256: `a7119b1b9a380740d0f1a3a80456dcbcbef0add844fc7c3f3e613a72f28f4fc6`. Native handoff SHA-256: `5b593a95ef655a5375b6aa901f165ef9f790b09d2d23a63e284dd15282bff361`.

Three unauthenticated health checks executed through read-only Base44 CLI exec passed:

- Public JWKS: HTTP 200 and a nonempty key set.
- Unsupported handoff version: HTTP 400, `invalid_native_handoff_version`, before provider exchange.
- Bootstrap without a ticket: HTTP 400, `invalid_ticket`.

Local-shell requests received Cloudflare 403 responses rather than broker JSON; this channel did not establish function health. The separate server-side probes above did. Neither channel used a real Apple credential or created a provider session. Physical Apple sign-in remains pending.

Google state-recovery and provider helper hashes match the fresh baseline; the hosted callback local source remains SHA-256 `a59964b250227975fe8093ed912a9eec094813d7df5017aa763e2fad14c09f3c`. No hosted website, Google callback, provider setting, secret, or other Base44 function was deployed by this task. No new physical Google sign-in was performed.

Full sanitized hashes, scope, timing, and probe outcomes are in [apple-native-v2-deployment.json](apple-native-v2-deployment.json). The approved patch and compatibility policy remain in [apple-native-v2-manifest.json](apple-native-v2-manifest.json).
