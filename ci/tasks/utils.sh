#!/usr/bin/env bash

# rounds up to the nearest GB
mb_to_gb() {
  mb="$1"
  echo "$(( (${mb}+1024-1)/1024 ))"
}
