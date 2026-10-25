# Stillmint Privacy Policy — draft, not published

**NOT READY TO PUBLISH:** replace every TBD with real owner-approved information. This draft is not legal advice or an App Store privacy declaration.

Effective date: **TBD**  
Individual developer/legal operator's actual name: **TBD**  
Privacy contact email: **TBD**  
Public policy URL: **TBD**

## What Stillmint does

Stillmint helps you review the photos and videos you authorize, identify cleanup candidates and create smaller video copies. It does not require an account and contains no third-party advertising or cross-app tracking service. It does not provide a permanent backup or guarantee recovery.

## Photos and on-device processing

Access to Photos is requested only after you choose to grant permission. Limited access covers the items you authorize; Full access allows a broader review. Photo/video analysis happens on your device. The app does not upload your media, filenames or derived visual features to a developer-operated service. You control deletion selections and Apple Photos presents the confirmation.

On-device does not mean every action is offline. Apple Photos may download your own iCloud media when you request full previews or video playback. App Store services communicate with Apple for product prices, purchase verification, updates and restoring purchases. Apple controls those services under its own policies. Opening our support, privacy or terms pages uses your browser and the hosting provider; **TBD: disclose the real website host, server logging, support email provider, contact processing and retention before publication.**

## Local records and retention

- Scan/checkpoint records contain local Photos identifiers, metadata, hashes and analysis progress to avoid repeating work and resume a review. Changes to authorized media are reconciled; these records are not a backup of the original photos.
- Your manual protection choices and album/recent-media rules are stored locally. Removing one reason does not remove protection from another active reason.
- Compression operation records retain the exact source/output identifiers and verification state locally so a saved copy can be checked safely before original cleanup. These records are separate from Activity.
- A separate local deletion journal retains selected Photos identifiers and operation/progress records to avoid repeating an unclear deletion or charging the same confirmed cleanup twice. Unresolved operations are retained; the most recently completed record can remain until a later journal write prunes it. Completion does not mean immediate file deletion, and no fixed timed deletion is promised for this journal. An unverified operation is not proof that media was deleted. These safety records are excluded from device backup by the current implementation and are not erased by clearing Activity.
- Activity contains aggregated operation results, counts and file-size provenance, not Photos identifiers, filenames, album names, locations, thumbnails or visual features. It keeps up to 200 records within the last 12 calendar months and can be cleared independently.
- Lifetime-cumulative free-use allowances are held in separate on-device Keychain records. They do not reset daily. Clearing Activity does not erase allowances, protection rules or compression proofs. Keychain persistence after uninstall, restoration or device changes is controlled by iOS and is not promised to reset or transfer; the current records use device-only accessibility classes.
- Local files use the platform's file protection. Do not treat device protection as a promise that another person with access to your unlocked device cannot access information.

## Choices, deletion and recovery

You can change Photos access in iOS Settings, manage Limited access, remove manual protections and change rules in the app. Revoking permission stops access to unauthorized media; it is not the same as erasing every existing local record. Clearing Activity removes Activity only. This version does not offer a single control that erases every local ledger; **contact TBD for questions**, and do not assume uninstall erases all Keychain data.

Deleted media may remain in Recently Deleted in Apple Photos, subject to Apple's retention and your actions. Restore items in Photos while they are still retained. Stillmint has no independent permanent recycle bin or guaranteed one-tap rollback. Saved compressed videos and originals remain in Photos unless you explicitly delete them.

## Purchases

Apple handles payment-card information and purchase processing. Stillmint verifies Apple transactions to decide access to Lifetime features; the app does not receive your payment-card details or operate its own payment server. **TBD: owner must verify this statement against the final signed binary, website and all dependencies before declaring Data Not Collected in App Store Connect.**

## Support and changes

If you email support, the operator and mail provider receive what you send. Do not attach private photos, asset identifiers or sensitive screenshots unless needed and deliberately chosen. **TBD: specify support-record retention and deletion request handling.**

We will date material policy changes and publish the current policy at the real policy URL. Questions and requests: **TBD monitored email**.
