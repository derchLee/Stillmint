#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source scripts/test-support.sh
device="$(ck_select_simulator)"
result="${CK_UNIT_RESULT:-/tmp/clearkeep-unit-$(date +%Y%m%d-%H%M%S)}"
xcodebuild test -project ClearKeep.xcodeproj -scheme ClearKeep -destination "platform=iOS Simulator,id=$device" -derivedDataPath /tmp/clearkeep-unit-derived -resultBundlePath "$result.xcresult" -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO "$@" 2>&1 | tee "$result.log"
