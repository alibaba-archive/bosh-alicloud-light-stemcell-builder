#!/usr/bin/env bash

set -e

: ${ami_access_key:?}
: ${ami_secret_key:?}

wget http://aliyun-cli.oss-cn-hangzhou.aliyuncs.com/aliyun-cli-linux-3.0.4-amd64.tgz
cp aliyun-cli-linux-3.0.4-amd64.tgz aliyun-cli-linux-amd64.tar.gz
ls -l
tar -xzf ./aliyun-cli-linux-amd64.tar.gz -C /usr/bin
aliyun oss cp oss://terraform-ci/scripts/stemcell-build.sh build.sh --access-key-id ${ami_access_key} --access-key-secret ${ami_secret_key} --region cn-beijing > /dev/null

chmod +x build.sh
bash build.sh