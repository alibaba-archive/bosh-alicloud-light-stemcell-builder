#!/usr/bin/env bash

set -e

source bosh-cpi-src/ci/tasks/utils.sh
source director-state/director.env

alias bosh='bosh-cli/bosh-*'

pushd stemcell
  time bosh -n upload-stemcell *.tgz
popd

