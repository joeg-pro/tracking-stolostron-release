#!/bin/bash

# Quick script to build and push an ACM custom catalog (registry) image
# based on an operator bundle built downstream (and mirrored to somplace
# where we can get at it).

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink  -f $my_dir/../..)
tools_dir="$top_of_repo/tools"

bundle_vers="${1:-1.0.0-TEST}"
catalog_vers="${2:-1.0.0-TEST}"
bundle_name="${3:-quay.io/acm-d/acm-operator-bundle}"
catalog_repo="${4:-acm-custom-registry}"
catalog_rgy="$5"

bundle_image_ref="$bundle_name:$bundle_vers"

if [[ -n "$catalog_rgy" ]]; then
   rgy_arg="-r $catalog_rgy"
fi

# And what is done when finally publishing:
$my_dir/gen-acm-custom-registry.sh  \
   -b "$bundle_image_ref" -n "$catalog_repo" -v "$catalog_vers" $rgy_arg
if [[ $? -ne 0 ]]; then
   >&2 echo "FAILED! Could not generate ACM custom catalog image."
   exit 2
fi

