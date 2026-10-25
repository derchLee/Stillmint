#!/usr/bin/env python3
"""Static brand acceptance checks; never migrates product identity or user data."""
import hashlib
import json
import plistlib
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
name = "Stillmint"
checks = []
def check(label, passed):
    checks.append(bool(passed))
    print(("PASS " if passed else "FAIL ") + label)

info = plistlib.loads((root / "ClearKeep/Supporting/Info.plist").read_bytes())
check("display name", info["CFBundleDisplayName"] == name)
check("permission copy", all(name in info[key] and "ClearKeep" not in info[key] for key in ("NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription")))
platform = (root / "ClearKeep/App/PlatformServices.swift").read_text()
compression = (root / "ClearKeep/Adapters/CompressionPersistence.swift").read_text()
check("bundle/Keychain/storage identities unchanged", info["CFBundleIdentifier"] == "$(PRODUCT_BUNDLE_IDENTIFIER)" and info["CFBundleName"] == "$(PRODUCT_NAME)" and all(value in platform for value in ['"com.clearkeep.free-quota"', '"ledger"', '"clearkeep-scan.json"', '"clearkeep.free.deletedItems"', '"clearkeep.free.deletedBytes"']) and all(value in compression for value in ['"com.clearkeep.compression-quota"', '"CompressionOperations"', '"operations.json"']))
visible = {
    "ClearKeep/Features/RootView.swift": ["Stillmint finds photos", "Choose which photos Stillmint can review"],
    "ClearKeep/Features/ReviewFlow.swift": ["Stillmint does not upload your photos or videos"],
    "ClearKeep/Domain/CompressionWorkflow.swift": ["Stillmint will not save again"],
}
for file, fragments in visible.items():
    text = (root / file).read_text()
    check(file + " visible copy", all(fragment in text for fragment in fragments))

catalog = json.loads((root / "ClearKeep.storekit").read_text())
product = catalog["products"][0]
check("local fixture brand reference", product["referenceName"] == "Stillmint Lifetime Unlock")
check("purchase identity/price unchanged", len(catalog["products"]) == 1 and product["productID"] == "com.clearkeep.lifetime" and product["type"] == "NonConsumable" and product["displayPrice"] == "19.99")
manifest = json.loads((root / "ClearKeep/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json").read_text())
filename = manifest["images"][0]["filename"]
check("versioned icon reference", filename == "Stillmint-AppIcon-v1-20261024.png" and (root / "ClearKeep/Resources/Assets.xcassets/AppIcon.appiconset" / filename).is_file())
old_icon = root / "docs/branding/legacy/AppIcon-1024-before-Stillmint.png"
check("old icon preserved", hashlib.sha256(old_icon.read_bytes()).hexdigest() == "11a422c0545da3cbf9cf2ad7683825760ef7e623e17a8b0af3260f8b347b31e4")
protected = {
    # 2026-10-25 accepted deletion-journal/atomic quota baseline, not a branding-only change.
    # Historical 2026-10-24 hashes are superseded by intentional, independently tested safety work.
    "ClearKeep/App/PlatformServices.swift": "b8c7fbcfd554893af31afbeedd469a63b2ceaaee495836de8dbe043b90cace42",
    "ClearKeep/App/ReviewWorkflow.swift": "a98a420035fc1448f28bbb6990402e80e886064a6f0b670a8561fde87ed81c67",
    "ClearKeep/App/AppModel.swift": "bb4520563aa00ecbd0ff0412d15c617e2dab83155a603bbd686077d5cdd4e077",
    "ClearKeep/Adapters/CompressionPersistence.swift": "fd23af31d31deec462e076aeca7ac58e2013190d1a1e8eaf56b8e76e39dd07b0",
}
for file, digest in protected.items():
    check(file + " branding baseline unchanged", hashlib.sha256((root / file).read_bytes()).hexdigest() == digest)
check("Swift app/module retained", "struct ClearKeepApp: App" in (root / "ClearKeep/App/ClearKeepApp.swift").read_text() and (root / "ClearKeep.xcodeproj/project.pbxproj").is_file())
check("subtitle within 30 characters", len("Keep the photos that matter") <= 30)
print(f"{sum(checks)}/{len(checks)} brand checks passed")
sys.exit(0 if all(checks) else 1)
