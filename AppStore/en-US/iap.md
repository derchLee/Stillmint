# In-app purchases — en-US

Prices below are product strategy targets. App Store Connect tier/storefront values and StoreKit-localized prices are authoritative.

## Lifetime Unlock

- Proposed product ID: `com.clearkeep.lifetime`
- Product type: **Non-Consumable**
- Reference name: `Stillmint Lifetime Unlock`
- Display name: `Lifetime Unlock`
- Description: `Unlock unlimited photo and video cleanups forever with one purchase.`
- Target US price: **Owner decision required**; StoreKit-localized price is authoritative.
- Duration: `Lifetime`
- Family Sharing: owner decision; validate the chosen behavior before enabling.

Configure exactly as a Non-Consumable. The verified transaction grants permanent unlimited cleanup access. The app must expose Restore Purchases.

## Legacy entitlements — compatibility only

- `com.clearkeep.cleanup_pass_30d`
- `com.clearkeep.pro.annual`

Existing verified transactions may continue to unlock cleanup under their original expiry rules. These identifiers must not be requested in the new product catalog, displayed, promoted, or offered for sale.

### Required purchase disclosure near the action

Show the StoreKit-localized total price and state: `One-time purchase. Unlocks unlimited cleanups and full video compression forever. No subscription or recurring charge.` Provide working Privacy Policy, Terms of Use, Restore Purchases, and close paths.

## Confirmed free tier (not yet implemented)

- Lifetime-cumulative deletion allowance: 100 identifier-confirmed deleted items, with no byte cap and no daily/monthly reset.
- Lifetime-cumulative compression allowance: 10 successfully validated, Photos-saved, and refetch-confirmed full video exports, with no commercial duration, input-size, resolution, or daily limit.
- Preview, protection, comparison, recovery, truthful receipts, and compression sample previews are free.
- Failed/canceled/unverified deletions and failed/canceled/invalid/save-failed/`pendingVerification` compression operations consume no allowance.
- Quotas are separate, durable, and idempotent by operation. Restore/relaunch/date changes do not reset them; Lifetime refund/revocation returns to the preserved actual free usage.
- Every distinct full-compression job with a newly saved/refetch-confirmed output consumes one compression export, including the same source compressed again with different parameters. Retrying the same operation ID never double-charges.
- `Keep both` is the default. Stillmint never automatically deletes the original.
- Deleting the exact source of a verified compressed output does not consume the 100-item ordinary-deletion allowance, even after that allowance is exhausted. The app must revalidate a protected on-device source/output operation mapping and the output's availability before offering this exception. Missing/untrusted mappings, missing outputs, or merely similar files receive no exception; protection and PhotoKit confirmation remain mandatory.

The code implements the confirmed 100-item and 10-compression rules. Purchase, restore and refund remain blocked in current StoreKit integration evidence; verify the exact signed release build and Sandbox before submitting.

## Purchase screenshot requirements

Each IAP submitted for review needs an App Review screenshot showing the purchase option inside the app. It is not displayed on the public product page. Capture on a release-equivalent build with the localized price visible; do not use a fabricated price.

## StoreKit release matrix

- The single lifetime product ID resolves for the production bundle ID.
- The Non-Consumable is Cleared for Sale and included with the app version/submission as required.
- Agreements, tax, and banking status allow paid apps/IAP.
- Purchase, cancellation, pending/Ask to Buy, verification failure, restore, cross-launch entitlement refresh, refund/revocation, reinstall and device change are recorded in Sandbox.
- Permanent unlock remains active across relaunch/update and restores after reinstall/device change.
- Legacy Pass/Annual transactions retain compatibility without appearing in the sale catalog.
- The purchase sheet retains the user's selected assets after cancel/failure.
- A missing lifetime product shows no guessed price and does not expose a purchase CTA.
