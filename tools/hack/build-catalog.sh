#!/bin/bash

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink  -f $my_dir/../..)
tools_dir="$top_of_repo/tools"

bundle_image_ref="${1:-quay.io/acm-d/acm-operator-bundle:v1.0.0-5}"
catalog_vers="${2:-1.0.0}"
catalog_repo="${3:-acm-custom-registry}"
catalog_rgy="$4"

if [[ -n "$catalog_rgy" ]]; then
   rgy_arg="-r $catalog_rgy"
fi

# And what is done when finally publishing:
$my_dir/gen-acm-custom-registry.sh -P \
   -b "$bundle_image_ref" -n "$catalog_repo" -v "$catalog_vers" $rgy_arg
if [[ $? -ne 0 ]]; then
   >&2 echo "FAILED! Could not generate ACM custom catalog image."
   exit 2
fi

