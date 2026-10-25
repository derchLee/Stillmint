# Stillmint for iPhone

Native SwiftUI iOS 17+ app that scans the user-authorized Photos library on device, presents conservative review candidates, and delegates every deletion to Apple's Photos confirmation UI. Photos and videos are not uploaded.

## Local build

Open `ClearKeep.xcodeproj`. Debug builds intentionally disable signing and use explicit `com.example...` placeholders. An unsigned CI compile is:

```sh
xcodebuild -project ClearKeep.xcodeproj -scheme ClearKeep -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

`ClearKeep.storekit` contains a local US Lifetime Unlock fixture ($19.99 is test pricing, not the final sale price). `ClearKeepStoreKit` is a separate test scheme/host containing this resource; the shipping app and default unit/E2E schemes do not include or activate it.

Implemented free tier: 100 on-device lifetime-cumulative confirmed ordinary deletions with no byte cap, plus a separate 10 lifetime-cumulative successful full video compressions. Durable deletion confirmation is settled once using a journal and quota operation marker. An unproven interrupted/error outcome is paused, never automatically deleted again or charged just because IDs are absent; the user may explicitly close it as unverified without resetting allowance. Compression counts only after validation, Photos save, and refetch confirmation; preview/failure/cancel/save failure/`pendingVerification` do not count. There are no commercial duration/input-size/resolution/daily compression limits. Lifetime permanently unlocks unlimited cleanup and compression. Implementation is a Beta candidate, not proof that the release gates below are complete.

Each distinct verified compression job counts once, including a new job for the same source with different parameters; retrying the same operation ID is idempotent. Keep both is the default. Exact source cleanup for a verified output does not use ordinary deletion quota, but only after a separate protected operation ledger revalidates the source/output mapping and output availability. This mapping is never stored in Activity history. Missing output/mapping or protected source means no exemption.

## Automated tests

```sh
scripts/run-tests.sh unit      # Default unit/hosting tests, no StoreKitTest configuration
scripts/run-tests.sh e2e       # 12 production-UI journeys with explicit DEBUG Photos/I/O fixtures
scripts/run-tests.sh storekit  # 9 real StoreKit cases, including one separate session-control diagnostic
scripts/run-tests.sh all       # Unit -> StoreKit -> E2E; stops at any failure
```

Runners prefer `CK_SIMULATOR_ID`; otherwise they find a booted/available iPhone Simulator and boot it without erasing data. `CK_UNIT_RESULT`, `CK_STOREKIT_RESULT`, and `CK_E2E_RESULT` set unique `.log`/`.xcresult` prefixes. Xcode with an installed iOS Simulator runtime is required. Run suites serially against one device. The StoreKit runner uses local simulator ad-hoc development signing (no paid developer account); only its separate test host enables `get-task-allow`. Default Debug and shipping signing settings are unchanged.

**Release and StoreKit status, 2026-10-25: BLOCKED, not ready for submission.** Latest local StoreKit suite: 6 passed / 3 failed / 0 skipped. The original eight cases remain 5 passed / 3 failed; the ninth is a separate official session-control diagnostic and does not replace production purchase. Direct verified purchase, fresh restore, and refund remain unverified; strict assertions are retained. Thus `all` currently reports failure at StoreKit. Latest source-workspace regression: unit/integration/hosting 140 total (139 passed, 1 actual Photos authorization-dependent test skipped), E2E 12 passed, unsigned Release build succeeded. See [validation scope and remaining gates](docs/release/validation-status-2026-10-25.md). These are recorded source-workspace results, not a claim that this repository has already passed CI, signed-device testing, or App Store review.

## Required release configuration

Before archiving, replace all `CK_*` placeholder values in Release build settings (and keep `project.yml` synchronized):

- `CK_BUNDLE_ID`: final registered App ID
- `DEVELOPMENT_TEAM`: owner's Apple team
- `CK_LIFETIME_PRODUCT_ID`: App Store Connect Non-Consumable Lifetime Unlock

Legacy Pass/Annual IDs may remain internal only for verified-entitlement compatibility. They must not be requested for sale or shown in purchase UI.
- `CK_PRIVACY_POLICY_URL`, `CK_TERMS_URL`, and `CK_SUPPORT_URL`: verified public HTTPS pages
- `CK_MARKETING_VERSION` and `CK_BUILD_NUMBER`

Release permits automatic signing; it deliberately does not contain a team, certificate, profile, secret, or claimed final bundle ID.

## Verification before upload

1. Run unit tests and a signed Release build on a physical iPhone.
2. Test Photos access: Full, Limited, denied, changed during review, iCloud-only/skipped, cancellation, successful and partial deletion.
3. Test StoreKit Sandbox: lifetime purchase, cancel, pending/Ask to Buy, restore, refund/revocation, interrupted transaction, reinstall and device change; verify legacy entitlements remain compatible without being offered for sale.
4. Complete the accessibility/device matrix: smallest supported iPhone, largest Dynamic Type, VoiceOver, Increase Contrast, Dark Mode, Reduce Motion. v1 is portrait-only.
5. Benchmark 10k and 50k local/iCloud-heavy libraries and record duration, peak memory, battery/thermal state, cancellation latency, skipped count, and the 500-item exact-hash budget behavior.
6. Archive, run Organizer validation, upload to TestFlight, and smoke-test the processed build.

See `AppStore/review-runbook.md` and `AppStore/release-checklist.md`. No source-only build can replace signed-device, App Store Connect, TestFlight, legal, or trademark validation.
