#!/usr/bin/env python3
"""Build the native client; signing uses certificates already in your Keychain."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('mode', choices=('simulator', 'archive'), nargs='?', default='simulator')
parser.add_argument('--identity', default=os.environ.get('SPOTIFIED_SIGNING_IDENTITY', 'Apple Distribution'))
parser.add_argument('--profile', default=os.environ.get('SPOTIFIED_SIGNING_PROFILE', 'Afterglow Labs Software Suite Ad Hoc Provisioning'))
parser.add_argument('--team', default=os.environ.get('SPOTIFIED_SIGNING_TEAM', '2J5W72TTU5'))
args = parser.parse_args()


def run(*command):
    subprocess.run(command, cwd=ROOT, check=True)


run('xcodegen', 'generate')
common = ['xcodebuild', '-project', 'Spotified.xcodeproj', '-scheme', 'Spotified']
if args.mode == 'simulator':
    run(*common, '-configuration', 'Debug', '-sdk', 'iphonesimulator',
        '-derivedDataPath', '.build/DerivedData', 'CODE_SIGN_IDENTITY=-', 'build-for-testing')
else:
    run(*common, '-configuration', 'Release', '-destination', 'generic/platform=iOS',
        '-archivePath', '.build/Spotified.xcarchive', '-derivedDataPath', '.build/ArchiveData',
        'CODE_SIGN_STYLE=Manual', 'CODE_SIGN_IDENTITY=' + args.identity,
        'PROVISIONING_PROFILE_SPECIFIER=' + args.profile, 'DEVELOPMENT_TEAM=' + args.team, 'archive')
    options = ROOT / '.build/ExportOptions.plist'
    options.write_bytes(plistlib.dumps({
        'method': 'release-testing', 'signingStyle': 'manual', 'teamID': args.team,
        'signingCertificate': args.identity,
        'provisioningProfiles': {'com.afterglowlabs.spotified.ios': args.profile},
        'manageAppVersionAndBuildNumber': False,
    }))
    run('xcodebuild', '-exportArchive', '-archivePath', '.build/Spotified.xcarchive',
        '-exportPath', '.build/Export', '-exportOptionsPlist', str(options))
    print('Signed client:', ROOT / '.build/Export/Spotified.ipa')
