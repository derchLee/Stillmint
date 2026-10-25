#!/usr/bin/env python3
"""Read-only release configuration dry-run; never signs, uploads or approves G4."""
import argparse
import ipaddress
import json
import plistlib
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path


def placeholder(value):
    return not isinstance(value, str) or not value.strip() or bool(re.search(
        r'YOUR[-_ ]|PLACEHOLDER|replace-before|\bTBD\b|\bOWNER[-_ ]INPUT\b|\$\(|<[^>]+>|\.example(?:/|$)|com\.example\.', value, re.I))


def public_https(value):
    if placeholder(value):
        return False
    try:
        u = urllib.parse.urlsplit(value)
        if u.scheme != 'https' or not u.hostname or u.username or u.password or u.fragment:
            return False
        host = u.hostname.lower()
        if any(host == sample or host.endswith('.' + sample) for sample in ['example.com', 'example.org', 'example.net']):
            return False
        if '.' not in host or host.endswith(('.localhost', '.local', '.test', '.invalid', '.example')):
            return False
        try:
            return ipaddress.ip_address(host).is_global
        except ValueError:
            return True
    except ValueError:
        return False


def audit(config, app=None, check_urls=False):
    checks = []
    def add(key, ok, detail):
        checks.append({'id': key, 'status': 'PASS' if ok else 'BLOCKED', 'detail': detail})
    bundle = config.get('bundleID')
    add('bundleID', not placeholder(bundle) and bool(re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}', bundle)), 'Final registered bundle ID required; registration is not verified here.')
    team = config.get('teamID') if isinstance(config.get('teamID'), str) else ''
    add('teamID', bool(re.fullmatch(r'[A-Z0-9]{10}', team)), 'Apple Developer Team ID format only; membership/signing not verified.')
    product = config.get('lifetimeProductID')
    add('lifetimeProductID', not placeholder(product), 'Exact ASC non-consumable ID required; public string does not prove ASC availability.')
    for field in ['privacyURL', 'termsURL', 'supportURL']:
        value = config.get(field)
        valid = public_https(value)
        add(field, valid, 'Public HTTPS URL without placeholders required.')
        reachable = False
        detail = 'Not fetched; run --check-urls after owner supplies actual published URLs.'
        if valid and check_urls:
            try:
                request = urllib.request.Request(value, headers={'User-Agent': 'Stillmint-release-preflight/1.0'})
                with urllib.request.urlopen(request, timeout=15) as response:
                    content = response.read(131072).decode('utf-8', errors='replace')
                    reachable = response.status == 200 and public_https(response.url) and len(content.strip()) > 80
                    detail = 'HTTP status/content presence only, not policy correctness or legal approval.'
            except Exception as error:
                detail = 'Fetch failed: ' + type(error).__name__
        add(field + '.publicFetch', reachable, detail)
    for field in ['legalOwner', 'reviewContactName', 'reviewContactPhone', 'reviewContactEmail']:
        add(field, not placeholder(config.get(field)), 'Owner-supplied real publication/review information required; not invented by this tool.')
    email = config.get('reviewContactEmail') if isinstance(config.get('reviewContactEmail'), str) else ''
    add('reviewContactEmail.format', bool(re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', email)), 'Monitored contact email format; deliverability not verified.')
    if app:
        path = Path(app)
        try:
            with (path / 'Info.plist').open('rb') as file:
                info = plistlib.load(file)
            add('artifact.bundleID', info.get('CFBundleIdentifier') == bundle and not placeholder(bundle), 'Compiled Info.plist must match final configuration.')
            for field, key in [('privacyURL', 'CKPrivacyPolicyURL'), ('termsURL', 'CKTermsOfUseURL'), ('supportURL', 'CKSupportURL'), ('lifetimeProductID', 'CKLifetimeProductID')]:
                add('artifact.' + key, info.get(key) == config.get(field) and not placeholder(info.get(key)), 'Resolved compiled value must match owner configuration.')
            for key in ['NSPhotoLibraryUsageDescription', 'NSPhotoLibraryAddUsageDescription', 'CFBundleShortVersionString', 'CFBundleVersion']:
                add('artifact.' + key, not placeholder(info.get(key)), 'Compiled value must be present and resolved.')
            manifests = list(path.rglob('PrivacyInfo.xcprivacy'))
            add('artifact.privacyManifest', bool(manifests), 'Manifest presence only; reason/API inventory must be independently audited.')
            add('artifact.noStoreKitFixture', not list(path.rglob('*.storekit')), 'Shipping artifact must not bundle local StoreKit fixture resources.')
        except (OSError, ValueError, plistlib.InvalidFileException):
            add('artifact.readable', False, 'Readable compiled .app/Info.plist required.')
    else:
        add('artifact.readable', False, 'No compiled app supplied. Use --app PATH after building resolved Release configuration.')
    for key in ['distributionSigning', 'ascProductAndAgreements', 'realDevicePhotos', 'sandboxPurchaseRestoreRefund', 'largeLibraryPerformance', 'voiceOverAccessibility', 'privacyLabelAndRetention', 'ageRating', 'exportCompliance']:
        add('external.' + key, False, 'Separate current evidence and owner approval required; not proven by configuration dry-run.')
    return {'schemaVersion': 1, 'mode': 'dry-run', 'uploadsPerformed': False,
            'configurationPassed': all(c['status'] == 'PASS' for c in checks if not c['id'].startswith('external.')),
            'gate': 'G4', 'decision': 'BLOCKED', 'checks': checks,
            'scope': 'Static configuration/artifact checks are not signing, ASC, Sandbox or G4 certification.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True, help='Owner-supplied JSON; no secrets.')
    parser.add_argument('--app', help='Compiled Release .app, inspected read-only.')
    parser.add_argument('--check-urls', action='store_true', help='Fetch supplied public HTTPS pages; no authentication.')
    args = parser.parse_args()
    try:
        config = json.loads(Path(args.config).read_text())
        if not isinstance(config, dict):
            raise ValueError('Expected JSON object')
    except (OSError, ValueError) as error:
        print(json.dumps({'mode': 'dry-run', 'decision': 'BLOCKED', 'error': type(error).__name__}))
        return 2
    print(json.dumps(audit(config, args.app, args.check_urls), indent=2))
    return 1  # G4 cannot be approved by this local-only preflight.


if __name__ == '__main__':
    sys.exit(main())
