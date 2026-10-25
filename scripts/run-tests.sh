#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
test_mode="${1:-all}"
if (( $# > 0 )); then shift; fi
case "$test_mode" in
  unit) scripts/run-unit.sh "$@" ;;
  e2e) scripts/run-e2e.sh "$@" ;;
  storekit) scripts/run-storekit.sh "$@" ;;
  all) scripts/run-unit.sh "$@"; scripts/run-storekit.sh "$@"; scripts/run-e2e.sh "$@" ;;
  *) print -u2 "Usage: scripts/run-tests.sh [unit|storekit|e2e|all] [xcodebuild options]"; exit 2 ;;
esac
