#!/bin/bash

base_url="https://muxinc.github.io"
repository_name="swift-upload-sdk"
target_name="muxuploadsdk"
output_path="docs/"

sed -e "s/__BASE__/${base_url}/g" \
    -e "s/__SLUG__/${repository_name}/g" \
    -e "s/__TARGET__/${target_name}/g" \
    "scripts/docc-files/index.html.template" > ${output_path}/index.html

cat ${output_path}/index.html
