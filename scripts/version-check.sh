#!/bin/bash

readonly COCOAPOD_SPEC=Mux-Upload-SDK.podspec

# Extracts the pod spec version in the form of a MAJOR.MINOR.PATCH string
cocoapod_spec_version=$(grep -Eo '\b[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+)?(\+[0-9A-Za-z-]+)?\b' $COCOAPOD_SPEC | awk 'NR==1')

echo "Detected Cocoapod Spec Version: ${cocoapod_spec_version}"

SEMANTIC_VERSION_FILE=Sources/MuxUploadSDK/PublicAPI/SemanticVersion.swift

release_version=$(awk '
    /let major/ { gsub(/[^0-9]/, "", $0); major = $0 }
    /let minor/ { gsub(/[^0-9]/, "", $0); minor = $0 }
    /let patch/ { gsub(/[^0-9]/, "", $0); patch = $0 }
    END {
        if (major && minor && patch) {
            print major "." minor "." patch
        } else {
            print "Error: Version information not found"
        }
    }
' <(grep -E 'let major|let minor|let patch' "$SEMANTIC_VERSION_FILE"))

echo $release_version

if [ "${cocoapod_spec_version}" == "${release_version}" ]; then
	echo "Versions match"
else
    echo "Versions do not match, please update ${COCOAPOD_SPEC} to ${release_version}"
    exit 1
fi
