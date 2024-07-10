#!/bin/bash

readonly XCODE=$(xcodebuild -version | grep Xcode | cut -d " " -f2)

#readonly TOP_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
readonly TOP_DIR=$PWD
readonly BUILD_DIR="${TOP_DIR}/.build"
readonly DOCUMENTATION_DIR=".build/docs"
readonly SCHEME=MuxUploadSDK

if ! command -v xcbeautify &> /dev/null
then
    echo -e "\033[1;31m ERROR: xcbeautify could not be found please install it... \033[0m"
    exit 1
fi

set -eu pipefail

rm -rf ${BUILD_DIR}

echo "▸ Using Xcode Version: ${XCODE}"

echo "▸ Building Documentation Catalog for ${SCHEME}"

mkdir -p $DOCUMENTATION_DIR

xcodebuild docbuild -scheme $SCHEME \
                    -destination 'generic/platform=iOS' \
                    -sdk iphoneos \
                    -derivedDataPath "${DOCUMENTATION_DIR}" \
                    OTHER_DOCC_FLAGS="--transform-for-static-hosting --hosting-base-path swift-upload-sdk --output-path docs" \
                    | xcbeautify 

echo "▸ Finished building Documentation Archive"

exit
