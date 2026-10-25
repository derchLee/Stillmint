#!/bin/zsh
# Shared by runners; only selects/boots an available iPhone Simulator, never erases it.
ck_select_simulator() {
  local selected_device="${CK_SIMULATOR_ID:-}"
  if [[ -z "$selected_device" ]]; then
    selected_device="$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
devices = [device for runtime, values in json.load(sys.stdin)["devices"].items()
           if ".iOS-" in runtime for device in values
           if device.get("isAvailable", False) and device["name"].startswith("iPhone")]
if not devices:
    sys.exit("No available iPhone Simulator. Install an iOS runtime/device in Xcode or set CK_SIMULATOR_ID.")
devices.sort(key=lambda device: (device["state"] != "Booted", device["name"], device["udid"]))
print(devices[0]["udid"])
')" || return 1
  fi
  if ! xcrun simctl bootstatus "$selected_device" -b >&2; then
    print -u2 "Cannot boot iPhone Simulator $selected_device. Check CK_SIMULATOR_ID and installed Xcode runtimes."
    return 1
  fi
  print -r -- "$selected_device"
}
