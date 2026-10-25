#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source scripts/test-support.sh
device="$(ck_select_simulator)"
result="${CK_E2E_RESULT:-/tmp/clearkeep-e2e-$(date +%Y%m%d-%H%M%S)}"
xcodebuild test -project ClearKeep.xcodeproj -scheme ClearKeepE2E -testPlan ClearKeepE2E -destination "platform=iOS Simulator,id=$device" -derivedDataPath /tmp/clearkeep-e2e-derived -resultBundlePath "$result.xcresult" -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO "$@" 2>&1 | tee "$result.log"
