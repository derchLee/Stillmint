# App Store screenshot plan — en-US

Create screenshots from the final signed release-equivalent build. Use real, licensed sample media with no personal data. Do not composite UI states the shipped app cannot produce.

## Required capture sets

- Primary: current Apple-required 6.9-inch iPhone display size accepted by App Store Connect.
- Add other device-size sets only when App Store Connect requires them or the layout materially differs.
- Portrait sequence recommended. Validate exact pixel dimensions in App Store Connect at upload time because accepted device families can change.
- Capture Light Mode for a coherent primary story; optionally add Dark Mode only if every frame remains consistent and legible.

## Six-shot sequence

1. **Make space without guessing**
   - Screen: Welcome/pricing disclosure with on-device privacy badge.
   - Caption: `Review before you remove.`
   - Proof: the release build's verified free allowance and real localized purchase price are visible before scanning. Target copy is 100 confirmed deletions with no byte cap plus 10 refetch-confirmed full compressions; do not capture this until the binary implements it.

2. **See what is worth reviewing**
   - Screen: Storage Map with Similar Photos, Duplicates, Screenshots, Screen Recordings, and Large Videos where test data supports each category.
   - Caption: `A clear map of photo storage.`
   - Proof: category counts and estimated sizes are visible.

3. **Nothing selected by default**
   - Screen: populated review grid with zero selected.
   - Caption: `You choose every item.`
   - Proof: no preselection and clear selection controls.

4. **Protect important photos**
   - Screen: a favorited or edited item with the Protected state.
   - Caption: `Extra care for favorites and edits.`
   - Proof: the extra unlock step is visible; do not imply guaranteed protection.

5. **Preview the details**
   - Screen: photo or video preview with dimensions/size and explicit selection action.
   - Caption: `Preview before deciding.`
   - Proof: use a video frame only if playback UI is actually visible in the build.

6. **Confirm with Apple Photos**
   - Screen: in-app Delete Summary, not a fabricated system alert.
   - Caption: `Know what will change.`
   - Proof: selected count, estimated space, Recently Deleted explanation, and final ask-to-delete action.

## Optional seventh shot

- Screen: purchase screen with the single Lifetime Unlock and its real StoreKit-localized total price; after binary parity, it must say unlimited cleanup and full compression.
- Caption: `Straightforward options. No weekly plan.`
- Use only after all required purchase disclosures and policy/terms links are functional in the shipped UI.

## Visual and compliance QA

- Keep all essential copy inside device-safe areas and readable on the uploaded image.
- Avoid Apple hardware claims, fake storage warnings, rankings, review scores, competitor logos, “best,” “100% safe,” “perfect duplicates,” or guaranteed recovered-space numbers.
- Never show identifiable faces, names, locations, license plates, health records, messages, or copyrighted images without permission.
- Match current UI terminology exactly: “estimated,” “Protected,” and “Recently Deleted.”
- Verify status bar, localization, time, battery, and network indicators look intentional and consistent.
- Export in sRGB, without transparency, and inspect every uploaded rendition in App Store Connect.
