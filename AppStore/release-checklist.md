# App Store release checklist

All unchecked **BLOCKER** items prevent the claim “ready to submit.” Record evidence links/paths beside each completed item.

## Identity, account, and signing

- [ ] **BLOCKER** Final US app name passes App Store Connect availability and appropriate trademark/name clearance; no trademark claim is made without evidence.
- [ ] **BLOCKER** Replace `CK_BUNDLE_ID = com.example.clearkeep.replace-before-release` with the final registered Bundle ID in `project.yml` and the Xcode project.
- [ ] **BLOCKER** Set production Apple Developer Team, automatic/manual signing, distribution certificate, and provisioning profile.
- [ ] Set version to `1.0` and a unique build number; archive Release configuration with iOS 17+ and iPhone-only targeting.
- [ ] Confirm SKU, primary category (`Photo & Video` recommended), secondary category if any, copyright owner, availability, and pricing territory.
- [ ] **BLOCKER** Paid Applications Agreement, banking, and tax information are active.

## Product completeness

- [ ] **BLOCKER** App icon contains all required release renditions and passes archive validation; no placeholder artwork.
- [ ] **BLOCKER** Settings includes working Privacy Policy, Terms, Support/Feedback, and Restore Purchases routes; no subscription-management sales UI remains.
- [ ] Replace prototype README language and audit every shipped string for production accuracy.
- [ ] Verify all user-facing text is en-US quality and no debug/demo/test state ships.
- [ ] Confirm screenshots/recordings/duplicate/similar category behavior matches metadata; remove any unsupported marketing claim.

## PhotoKit real-device matrix

- [ ] **BLOCKER** Signed-device tests recorded for not determined, Limited, Full, denied, permission changes, and Limited picker.
- [ ] **BLOCKER** Signed-device tests recorded for local and iCloud-only photos/videos, complete video playback/seek, offline behavior, and interrupted downloads.
- [ ] **BLOCKER** System deletion confirmation, user cancellation, library mutation during confirmation, partial/failure reconciliation, and Recently Deleted recovery instructions pass.
- [ ] Default selection is zero in every category and after relaunch; Protected items require an explicit unlock.
- [ ] No media, thumbnails, filenames, asset identifiers, location, or derived fingerprints appear in logs or network traffic.

## StoreKit and monetization

- [ ] **BLOCKER** Production bundle ID and the single Lifetime Unlock product ID match code and App Store Connect exactly.
- [ ] **BLOCKER** Lifetime Unlock is configured as Non-Consumable; localization, price, review screenshot and availability are complete.
- [ ] **BLOCKER** Sandbox matrix in `en-US/iap.md` passes on a signed device, including purchase/revocation/restore/cancel/pending/reinstall/device change.
- [ ] Legacy Pass/Annual verified entitlements remain compatible but are absent from the product request and every sales surface.
- [ ] StoreKit-localized prices appear before scan; no hardcoded/guessed price or purchase CTA appears when either product is unavailable.
- [ ] **BLOCKER** Binary matches the confirmed free tier: lifetime-cumulative 100 confirmed deletions with no byte cap, plus a separate lifetime-cumulative 10 refetch-confirmed compression exports; no daily reset or hidden duration/input-size/resolution commercial limit.
- [ ] **BLOCKER** The 100th deletion and 10th compression succeed; the 101st/11th require Lifetime. Failure/cancel/save failure/`pendingVerification` consume nothing; operation replay is idempotent; refund/revocation preserves actual free usage without re-grant.
- [ ] **BLOCKER** Distinct verified compression jobs count separately, including the same source with new parameters; retries of the same operation ID count once. Completion defaults to Keep both and never auto-deletes the source.
- [ ] **BLOCKER** Verified compressed-source cleanup bypasses ordinary item quota only when the protected operation ledger's exact source/output mapping and current output availability revalidate. Missing/untrusted output denies exemption; protected sources remain blocked; mixed/partial deletion counts only confirmed ordinary IDs.
- [ ] Purchase surface contains working Privacy, Terms, Restore and close paths plus one-time/lifetime/no-subscription disclosure.

## Performance, quality, and accessibility

- [ ] **BLOCKER** 10k and 50k local/iCloud-heavy library tests meet documented memory, responsiveness, cancellation, thermal, battery, and crash-free thresholds.
- [ ] **BLOCKER** VoiceOver traversal and labels pass through onboarding, scan, review, preview, purchase, summary, result, and Settings.
- [ ] **BLOCKER** Maximum Dynamic Type, Dark Mode, Increase Contrast, Reduce Motion, landscape behavior, and 44×44 pt controls pass on supported devices.
- [ ] Unit/UI regression suite passes against the release commit with results archived.
- [ ] Release archive passes Xcode validation, static analysis, crash launch test, and clean-install/upgrade smoke tests.

## Privacy, policy, and metadata

- [ ] **BLOCKER** Publish real Support, Privacy, Terms, and optional Marketing HTTPS pages; replace every placeholder in metadata and in-app UI.
- [ ] **BLOCKER** Release archive, privacy manifest, App Privacy answers, privacy policy, support site, and in-app claims pass a single data-flow audit.
- [ ] **BLOCKER** Complete current age-rating and export-compliance questionnaires based on the actual binary.
- [ ] Description, subtitle, keywords, promotional text, review notes, copyright, categories, and availability are entered and proofread.
- [ ] Upload compliant screenshots for every required iPhone display class; upload IAP review screenshots separately.
- [ ] App Review contact details are monitored and review notes contain no placeholders.

## Submission and operations

- [ ] Upload build, resolve every processing/validation warning, attach the Non-Consumable IAP to the submission, and select the correct build.
- [ ] Internal TestFlight smoke test passes; external beta feedback and crash reports are triaged.
- [ ] Prepare support responses for accidental-deletion concerns, Recently Deleted navigation, billing, refund routing, restore, and photo permission.
- [ ] Choose manual/phased release intentionally; define rollback/stop-release owner and monitoring window.
- [ ] Submit only after all blockers above have evidence and final product/engineering/privacy sign-off.
