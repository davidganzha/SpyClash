# SpyClash App Store Connect fields

Prepared for bundle `com.spyclash.app`, iOS version `1.0`, build `3`.

This file contains no credentials, private contact details, or production
secrets. It is the checked-in source of truth for the non-secret values to
enter in App Store Connect after build 3 finishes processing.

## App Privacy

- Privacy Policy URL: `https://spyclash.com/privacypolicy`
- User Privacy Choices URL: `https://spyclash.com/support`
- Tracking: No

Declare every data type below as linked to the user's identity, used only for
App Functionality, and not used for tracking:

| App Store data type | SpyClash use |
| --- | --- |
| Email Address | Account authentication and recovery |
| Name | Operative profile identity |
| User ID | Account, social graph, rooms, and entitlements |
| Gameplay Content | Online room and match state |
| Other User Content | Profiles, comments, reports, and custom word packs |
| Purchase History | Apple and web entitlement synchronization |
| Device ID | APNs device registration and notification delivery |
| Other Data | Live Activity push tokens and delivery state |

These values must remain aligned with
`SpyClash/Resources/PrivacyInfo.xcprivacy`. Push tokens, Live Activity tokens,
and installation identifiers are not used for advertising or cross-app
tracking.

## Age Rating questionnaire

SpyClash is not a Kids Category app. Use the following truthful capability and
content answers; allow App Store Connect to calculate the resulting regional
ratings instead of overriding them downward.

### In-app controls and capabilities

- Parental Controls: No
- Age Assurance: No
- User-Generated Content: Yes
- Messaging and Chat: Yes
- Advertising: No
- Social Media: Yes
- Social Media Disabled for Users Under 13: No

### Content descriptors

- Profanity or Crude Humor: Infrequent
- Horror or Fear Themes: None
- Mature or Suggestive Themes: None
- Medical or Treatment Information: None
- Alcohol, Tobacco, or Drug Use or References: None
- Sexual Content or Nudity: None
- Graphic Sexual Content or Nudity: None
- Cartoon or Fantasy Violence: None
- Realistic Violence: None
- Prolonged Graphic or Sadistic Realistic Violence: None
- Guns or Other Weapons: None

### Chance-based activities

- Simulated Gambling: None
- Contests: Frequent
- Gambling: No
- Loot Boxes: No

### Additional information

- Made for Kids: No
- Override to Higher Age Rating: Not Applicable
- Age Suitability URL: leave blank unless a dedicated public page is added

## Version 1.0 attachment

- Select build `1.0 (3)` only. Build 2 contains the retired APNs registration
  loop and must not be attached to the submission.
- Attach the `LIMITLESS` weekly auto-renewable subscription to the first app
  submission.
- The subscription review screenshot must come from Sandbox or TestFlight and
  show the real localized App Store price and Restore Purchases control.
- Product-page screenshots are stored in `Screenshots/en-US` in upload order.

## App Review information

Enter the following only in App Store Connect, never in Git:

- dedicated review-account email;
- dedicated review-account password;
- review contact first name and last name;
- monitored review contact email;
- international review contact phone number.

The review account must be registered and verified before submission. Normal
email/password login for an already verified Base44 account does not request an
OTP. Test those exact credentials in build 3 before saving them in App Store
Connect.

Paste the non-secret review instructions from `APP_REVIEW_NOTES.md` into the
App Review Notes field.

## EU Digital Services Act

The Account Holder must make the trader/non-trader declaration in App Store
Connect. If declaring as a trader, provide the exact legal name, postal
address, phone number, and monitored email that Apple is permitted to verify
and display. Do not infer these values from source control or public profiles.

## Submission gates

- Base44 production has all 16 reviewed functions, including
  `pushNotificationAction` and `app-store-entitlement`.
- Build 3 has completed App Store Connect processing.
- Dedicated review account succeeds without OTP.
- Sandbox/TestFlight purchase, restore, entitlement sync, push, and Live
  Activity tests pass on a physical iPhone.
- A real Sandbox/TestFlight LIMITLESS screenshot replaces the local StoreKit
  reference image.
- A monitored support address is published and deliverable.
- DSA declaration is complete.
- The original procedural audio generator reproduces all 27 shipped WAV files
  byte-for-byte and the verified hashes remain recorded in the rights manifest.
- Build 3 and LIMITLESS are attached to version 1.0.
- Submit for Review is performed only after a separate explicit confirmation.
