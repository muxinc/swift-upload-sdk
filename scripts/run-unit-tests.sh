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

if ! command -v jq &> /dev/null
then
    echo -e "\033[1;31m ERROR: jq could not be found and is required to select an iOS simulator... \033[0m"
    exit 1
fi

SIMULATOR_DETAILS=$(xcrun simctl list devices available --json | jq -r '
    [
        .devices
        | to_entries[]
        | select(.key | startswith("com.apple.CoreSimulator.SimRuntime.iOS-"))
        | .runtimeVersion = (
            .key
            | sub(".*iOS-"; "")
            | split("-")
            | map(tonumber)
        )
        | .runtimeName = (
            .key
            | sub("com.apple.CoreSimulator.SimRuntime.iOS-"; "iOS ")
            | gsub("-"; ".")
        )
        | .eligibleDevices = [
            .value[]
            | select(
                (.isAvailable // false)
                and (.deviceTypeIdentifier | contains(".iPhone-"))
            )
        ]
        | select(.eligibleDevices | length > 0)
    ]
    | sort_by(.runtimeVersion)
    | last // empty
    | .eligibleDevices[0] as $device
    | [$device.udid, $device.name, .runtimeName]
    | @tsv
')
readonly SIMULATOR_DETAILS

if [ -z "${SIMULATOR_DETAILS}" ]
then
    echo -e "\033[1;31m ERROR: No available iPhone simulator was found... \033[0m"
    exit 1
fi

IFS=$'\t' read -r SIMULATOR_UDID SIMULATOR_NAME SIMULATOR_RUNTIME <<< "${SIMULATOR_DETAILS}"
readonly SIMULATOR_UDID SIMULATOR_NAME SIMULATOR_RUNTIME

echo "▸ Using Xcode Version: ${XCODE}"

echo "▸ Available Xcode SDKs"

xcodebuild -showsdks

echo "▸ Resolve Package Dependencies"

xcodebuild -resolvePackageDependencies

echo "▸ Available Schemes"

xcodebuild -list -json

echo "▸ Test ${SCHEME}"

echo "▸ Using ${SIMULATOR_NAME} (${SIMULATOR_RUNTIME}, ${SIMULATOR_UDID})"

xcodebuild clean test \
  -scheme "${SCHEME}" \
  -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}" \
  | xcbeautify
