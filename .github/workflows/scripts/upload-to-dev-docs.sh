#!/bin/bash

echo

if [ -z $1 ]
then
    echo -e "\033[1;31m ERROR: this script requires a file or directory parameter. \033[0m"
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

# Currently set to --dryrun for testing, which doesn't do anything except list files that get uploaded or deleted. 
# Add --delete flag to remove files in the S3 directory that are not in the local directory
# For more: https://awscli.amazonaws.com/v2/documentation/api/latest/reference/s3/sync.html#description
aws s3 sync $1 "s3://mux-devdocs/${1}" --dryrun
