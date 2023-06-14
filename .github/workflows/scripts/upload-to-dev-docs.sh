#!/bin/bash

cd .build

echo

if [ -z $1 ]
then
    echo -e "\033[1;31m ERROR: this script requires a directory parameter. \033[0m"
    exit $E_MISSING_POS_PARAM
fi

if [ -z $2 ]
then
    echo -e "\033[1;31m ERROR: this script requires a subdirectory parameter. \033[0m"
    exit $E_MISSING_POS_PARAM
fi

if ! command -v aws &> /dev/null
then
    echo -e "\033[1;31m ERROR: awscli could not be found. Run brew install awscli to install it. \033[0m"
    exit 1
fi

aws configure list

echo "Run aws configure if needed to setup AWS credentials"

echo

echo "Updating S3 bucket with content of $1"

echo

echo "Syncing into S3"
echo
# Currently set to --dryrun for testing, which doesn't do anything except list files that get uploaded or deleted. 
# Add --delete flag to remove files in the S3 directory that are not in the local directory
# For more: https://awscli.amazonaws.com/v2/documentation/api/latest/reference/s3/sync.html#description
aws s3 rm --recursive "s3://mux-devdocs/${1}/${2}/"
aws s3 rm --recursive "s3://mux-devdocs/upload-swift/latest/"
aws s3 sync $1 "s3://mux-devdocs/${1}"

echo "Propagating index.html"
echo
# S3/CloudFront doesn't server up index.html for a bare directory-name URL by default, but S3 isn't a real filesystem
# so we can use the S3 API to "copy" the index.html file to the directory name and server it up just the same

echo "Copying from mux-devdocs/${1}/${2}/documentation/muxuploadsdk/index.html with key ${1}/${2}/documentation/muxuploadsdk/"

aws s3api copy-object --copy-source "mux-devdocs/${1}/${2}/documentation/muxuploadsdk/index.html" --key "${1}/${2}/documentation/muxuploadsdk/" --bucket mux-devdocs

aws s3api copy-object --copy-source "mux-devdocs/${1}/latest/documentation/muxuploadsdk/index.html" --key "${1}/latest/documentation/muxuploadsdk/" --bucket mux-devdocs

