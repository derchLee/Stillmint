#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source scripts/test-support.sh
device="$(ck_select_simulator)"
result="${CK_STOREKIT_RESULT:-/tmp/clearkeep-storekit-$(date +%Y%m%d-%H%M%S)}"
xcodebuild test -project ClearKeep.xcodeproj -scheme ClearKeepStoreKit -destination "platform=iOS Simulator,id=$device" -derivedDataPath /tmp/clearkeep-storekit-derived -resultBundlePath "$result.xcresult" -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES 'CODE_SIGN_IDENTITY=-' "$@" 2>&1 | tee "$result.log"
