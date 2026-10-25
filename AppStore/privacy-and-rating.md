# App privacy and age rating proposal

These are proposed App Store Connect answers for the audited version described in the repository. Re-audit the release archive and all SDKs immediately before submission. Any analytics, crash reporting, support forms, website tracking, or server-side service can change these answers.

## App Privacy

### Tracking

- Does this app or its third-party partners use data for tracking? **No**
- Uses the AppTrackingTransparency framework? **No**

### Data collection

Proposed product-page label: **Data Not Collected**

Basis for the current build:

- Photo/video content is accessed through PhotoKit and analyzed on device.
- The scan checkpoint, fingerprints/features, free-quota ledgers, entitlement-derived state, and protected compression-operation ledger stay on device. The compression ledger may retain exact source/output Photos identifiers strictly for verification and original-cleanup safety; privacy-minimized Activity history must not contain those identifiers.
- No account, backend, advertising SDK, analytics SDK, or media-upload service is present.
- App Store purchase processing by Apple is not developer collection unless purchase/customer data is separately transmitted to or stored by the developer.

Before selecting “Data Not Collected,” confirm with a release-archive dependency/network audit that the developer and third parties receive none of Apple's App Privacy data types. Also audit the support and marketing websites separately under their privacy policy.

### Privacy manifest alignment

Current `PrivacyInfo.xcprivacy` declares no tracking and no collected-data types. It declares `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1` for app-local defaults and `NSPrivacyAccessedAPICategoryDiskSpace` with reason `E174.1` for export storage preflight. Confirm the release archive and every embedded SDK manifest remain consistent and that no additional required-reason API category is introduced.

## Photos permission explanation

- `NSPhotoLibraryUsageDescription`: `Stillmint reviews the photos you choose so you can decide what to remove.`
- `NSPhotoLibraryAddUsageDescription`: `Stillmint saves compressed video copies to Photos, keeps your originals, and asks before deleting only the items you confirm.`

Reviewer explanation: access is user-initiated after an in-app primer. Limited and Full Access are supported. PhotoKit identifiers and media-derived scan data stay on device. The app requests deletion only for explicitly selected items and iOS presents the system confirmation.

## Age rating

**Pending owner completion of the current App Store Connect questionnaire.** No final displayed rating is assigned by this draft.

Proposed questionnaire basis:

- No user-generated content sharing or public social features.
- No unrestricted web access.
- No messaging, chat, advertising, contests, gambling, loot boxes, or simulated gambling.
- No violence, sexual content/nudity, profanity, horror/fear themes, alcohol/tobacco/drugs, medical treatment information, or mature themes supplied by the app.
- No location sharing.

The user may choose private photos containing arbitrary content, but the app does not supply, publish, or share that content. Answer the current App Store Connect questionnaire truthfully; Apple determines the displayed rating.

## Export compliance

The current source does not implement proprietary encryption or networking. Confirm archive dependencies and answer App Store Connect's encryption questions for the actual binary. Do not infer an exemption solely from this document.
