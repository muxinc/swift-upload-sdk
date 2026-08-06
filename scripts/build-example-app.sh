#!/bin/bash

readonly XCODE=$(xcodebuild -version | grep Xcode | cut -d " " -f2)

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "▸ Usage: $0 SCHEME"
    exit 1
fi

readonly SCHEME="$1"

if ! command -v xcbeautify &> /dev/null
then
    echo -e "\033[1;31m ERROR: xcbeautify could not be found please install it... \033[0m"
    exit 1
fi

echo "▸ Using Xcode Version: ${XCODE}"

# The example app consumes MuxUploadSDK as a local package rooted at the
# repository, so this compiles the sample app against the working tree and
# catches public API changes that break SDK consumers.
cd Example/SwiftUploadSDKExample

echo "▸ Resolve Package Dependencies"

xcodebuild -resolvePackageDependencies

echo "▸ Available Schemes"

xcodebuild -list -json

echo "▸ Build ${SCHEME}"

# A generic destination keeps this off any particular simulator runtime, so the
# step survives Xcode upgrades on the agent and does not boot a device.
xcodebuild clean build \
	-scheme $SCHEME \
	-destination 'generic/platform=iOS Simulator' \
	CODE_SIGNING_ALLOWED=NO \
  | xcbeautify
