#!/bin/bash

readonly DOCUMENTATION_TOP_LEVEL_SLUG=swift-upload-sdk
readonly DOCUMENTATION_TARGET_SLUG=muxuploadsdk

echo "▸ Creating docc static archive"
./scripts/create-docc-archive.sh

echo "▸ Preparing docc static archive for deployment"
echo "▸ Top level slug: ${DOCUMENTATION_TOP_LEVEL_SLUG} Target slug: ${DOCUMENTATION_TARGET_SLUG}"

./scripts/post-process-docc-archive.sh $DOCUMENTATION_TOP_LEVEL_SLUG $DOCUMENTATION_TARGET_SLUG
