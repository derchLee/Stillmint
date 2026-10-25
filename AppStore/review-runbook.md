# App Review runbook — en-US

## Reviewer path

1. Launch and choose **Continue to Photo Access**.
2. Grant Full Access, or Limited Access and select several screenshots/photos/videos.
3. Start the on-device scan. If the review device has no eligible media, add two screenshots and relaunch/rescan.
4. Open a category, preview an item, explicitly select it, and review the deletion summary.
5. Stillmint asks Photos to delete; iOS presents the final system confirmation. Canceling is supported and selections remain available.

Analysis and checkpoints remain on device. Stillmint does not upload media, use advertising identifiers, or track users. iCloud assets that are unavailable locally are reported as skipped and can be retried after download in Photos.

**Implemented commercial rules (runtime release verification still required):** deletion is free for 100 confirmed items with no byte cap, and full video compression is free for 10 successfully saved and refetch-confirmed exports. These separate quotas are lifetime cumulative and do not reset daily. Preview never consumes quota; failures, cancellations, save failures and `pendingVerification` consume nothing. The single Lifetime Unlock is a Non-Consumable that permanently enables unlimited cleanups and full compression. The localized total price comes from StoreKit; there is no subscription or recurring charge. Restore Purchases is available in the purchase sheet and Settings. Current local StoreKit evidence remains 5 passed/3 failed for 8 cases; ordinary purchase, fresh restore and refund are not accepted as verified. Do not use this runbook as submission approval.

Every distinct verified compression job counts once, including compressing the same source again with different parameters; retrying the same operation ID is idempotent. Compression defaults to Keep both. Deleting the exact original of a verified compressed output does not consume ordinary deletion allowance—even after 100 ordinary items—but only after the protected operation ledger mapping and output availability are revalidated. A missing output, missing/untrusted mapping, or merely similar file gets no exemption. Protection rules, explicit user action, and Apple Photos confirmation still apply.

## App Review submission fields requiring owner completion

- Contact name, phone, email: `[OWNER REQUIRED]`
- Review account: not required; no app account exists
- Privacy Policy: `[PUBLIC HTTPS URL REQUIRED]`
- Terms of Use: `[PUBLIC HTTPS URL REQUIRED]`
- Product IDs and states: `[APP STORE CONNECT CONFIRMATION REQUIRED]`
- Notes for any temporary product-review dependency: `[OWNER REQUIRED]`

Do not submit while any bracketed field remains unresolved or while the app binary contains `com.example` / `YOUR-DOMAIN` placeholders.
