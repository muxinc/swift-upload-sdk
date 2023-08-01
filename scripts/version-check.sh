#!/bin/bash

readonly COCOAPOD_SPEC=Mux-Upload-SDK.podspec

cocoapod_spec_version=$(grep -Eo '\b[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+)?(\+[0-9A-Za-z-]+)?\b' $COCOAPOD_SPEC | awk 'NR==1')

echo "Detected Cocoapod Spec Version: ${cocoapod_spec_version}"

release_version=$(git branch --show-current | sed -E 's/.*v([0-9]+\.[0-9]+\.[0-9]+).*/\1/')

echo "Inferred Release Version: ${release_version}"

if [ "${cocoapod_spec_version}" == "${release_version}" ]; then
	echo "Versions match"
else
    echo "Versions do not match, please update the cocoapod spec to ${release_version}"
    exit 1
fi



