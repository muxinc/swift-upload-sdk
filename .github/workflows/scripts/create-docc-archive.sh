#!/bin/bash
# REQUIRED ENV VARS
# This script is intended to be run by a GitHub Action that supplies these env vars:
#   PROJECT_NAME: The name of the xcode project (without the extension)
#   SCHEME: The scheme to build and generate docs for
#   BUILD_CONFIGURATION: The build configuration to document
#   XCCONFIG_FILENAME: The name of the xcodebuild config file

readonly XCODE=$(xcodebuild -version | grep Xcode | cut -d " " -f2)

#readonly TOP_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
readonly TOP_DIR=$(pwd)
readonly BUILD_DIR="${TOP_DIR}/.build"
readonly DOCUMENTATION_DIR="${BUILD_DIR}/docs"
readonly XCCONFIG_DIR="${TOP_DIR}/FrameworkXCConfigs/"

# if [ -z $target_project ] 
# then
#     echo -e "\033[1;31m ERROR: Target project must be specified \033[0m"
#     exit 1
# else
#   readonly PROJECT_NAME=$target_project
# fi
if [ -z $target_scheme ]
then
    echo -e "\033[1;31m ERROR: Target scheme must be specified \033[0m"
    exit 1
else 
  readonly SCHEME=$target_scheme 
fi
# if [ -z $target_build_configration ]
# then
#   readonly BUILD_CONFIGURATION="Release"
# else 
#   readonly BUILD_CONFIGURATION=$target_build_configration
# fi
# if [ -z $xcconfig_filename ]
# then
#   readonly XCCONFIG_FILENAME="Release-Production"
# else
#   readonly XCCONFIG_FILENAME=$target_xcconfig_filename
# fi

#readonly PROJECT="${TOP_DIR}/${PROJECT_NAME}.xcodeproj"
readonly DOCC_ARCHIVE_NAME="${SCHEME}.doccarchive"
readonly DOCC_ARCHIVE_PATH="${BUILD_DIR}/${DOCC_ARCHIVE_NAME}"

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

#expanded_xcconfig_path="${XCCONFIG_DIR}/${XCCONFIG_FILENAME}.xcconfig"

                    #-xcconfig $expanded_xcconfig_path \
# xcodebuild docbuild -project $PROJECT \
#                     -scheme $SCHEME \
#                     -configuration $BUILD_CONFIGURATION \
#                     -destination 'generic/platform=iOS' \
#                     -sdk iphoneos \
#                     -derivedDataPath "${DOCUMENTATION_DIR}" | xcbeautify \

echo "▸ Building documentation archive at: ${DOCUMENTATION_DIR}"

xcodebuild docbuild -scheme ${SCHEME} \
                    -destination 'generic/platform=iOS' \
                    -derivedDataPath "${DOCUMENTATION_DIR}" \
                    | xcbeautify

cd ${BUILD_DIR}

echo "▸ Finished building Documentation Archive"

echo "▸ Searching for ${DOCC_ARCHIVE_NAME} inside ${DOCUMENTATION_DIR}"
docc_built_archive_path=$(find docs -type d -name "${DOCC_ARCHIVE_NAME}")

if [ -z "${docc_built_archive_path}" ]
then
    echo -e "\033[1;31m ERROR: Failed to locate Documentation Archive \033[0m"
    exit 1
else
    echo "▸ Located documentation archive at ${docc_built_archive_path}"
    mv ${docc_built_archive_path} ${BUILD_DIR}
    zip -qry "${DOCC_ARCHIVE_NAME}.zip" "${DOCC_ARCHIVE_NAME}"
fi

# Name of S3 devdocs bucket top-level directory where SDK documentation
# is deployed to
# TODO: This needs to be configurable from outside
static_documentation_root_directory_name="upload-ios"

# This matches the semantic version of the SDK binary
# TODO: Set based on XCConfig
static_documentation_versioned_subdirectory_name="staging"

# When deploying a new version the contents of the latest subdirectory 
# gets replaced with the generated documentation from the new version 
static_documentation_latest_subdirectory_name="latest"

static_documentation_versioned_path="${static_documentation_root_directory_name}/${static_documentation_versioned_subdirectory_name}"

source_archive_path=${DOCC_ARCHIVE_PATH}
output_path=$static_documentation_versioned_subdirectory_name
output_path="./docc-output-processed"
hosting_base_path=$static_documentation_versioned_path


echo "▸ Processing documentation archive with source archive path: ${source_archive_path} hosting base path: ${hosting_base_path} output path: ${output_path}"

mkdir -p $output_path

$(xcrun --find docc) process-archive transform-for-static-hosting "${source_archive_path}" \
    --output-path "${output_path}" \
    --hosting-base-path "${hosting_base_path}"

mkdir -p $static_documentation_root_directory_name

mv $output_path $static_documentation_root_directory_name

zip -qry "${static_documentation_root_directory_name}.zip" "${static_documentation_root_directory_name}"

cd ..

exit
