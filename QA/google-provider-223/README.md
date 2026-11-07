# Google provider routing — checkpoint 223

On 7 November 2026 the Google button in the installed Debug build 219 opened Apple Account. A fresh Chrome navigation to the same application-owned Google entry reproduced the result.

The broker received the expected app ID and `https://spyclash.com/MobileAuthCallback.html?auth_provider=google` inside a 155-character Base64URL-encoded JSON OIDC state. The existing selector accepted only plain JSON and therefore fell back to Apple. No credentials or raw OAuth transaction tokens are retained in this report.

The patch accepts canonical bounded Base64URL JSON as well as the existing plain JSON format. It retains exact app ID, HTTPS origin, return URL and unique provider-marker checks. Only `appleAuthBroker/provider.ts` changes in the production candidate; the remaining live broker files are preserved.

Deployment and validation receipts will be recorded after the corresponding checks. This source checkpoint alone does not prove successful sign-in.

## Approved Base44 publication

On 2026-11-07T19:45:27+00:00, the user explicitly approved publishing the login fix. Only `appleAuthBroker` was deployed from the frozen live-derived candidate. Fresh preflight matched all 14 live source files. Postflight matched all 14 candidate hashes and confirmed the sole source change was `provider.ts`; the other 13 broker source files retain their live bytes. All other 21 function source/configuration records also match preflight, apart from the platform-wide deployment identifier.

Deployment ID `c4814a98412d4bd58be273a25614f18a`. The provider SHA256 is `6f8c6ce102171970b2bf994167e6c85eeb4052a308ad83a3592b56127610765a`. Actual browser sign-in verification remains pending at the time of this receipt. See [deployment receipt](deployment-receipt.json).
