#!/bin/bash

# Quick script to build and push a custom catalog (registry) image
# built from a specified/defaulted bundle image.
#
# Allows independence of budnle vs. catatlog image stuff where the
# non-hack catalog-build cover scripts don't (intentionally).

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink  -f $my_dir/../..)
tools_dir="$top_of_repo/tools"

# To keep it simple, we use only positoinal arg with args 2 and beond optional
# and arranged in order of expected need to override.

bundle_tag=$1
if [[ -z "$bundle_tag" ]]; then
   >&2 echo "Bundle image tag is required."
   exit 2
fi

# Default to catalog tag being same as bundle tag
catalog_tag="${2:-$1}"
# Default to catalog having usual name and being pushed to our downstream-testing namespace
catalog_rgy_ns_and_repo="${3:-quay.io/acm-d/acm-custom-registry}"
# Ddefault to bundle having usual name and being fetched from our downstream-testing namespace
bundle_rgy_ns_and_repo="${4:-quay.io/acm-d/acm-operator-bundle}"

bundle_image_ref="$bundle_rgy_ns_and_repo:$bundle_tag"
catalog_rgy_and_ns="${catalog_rgy_ns_and_repo%/*}"
catalog_repo="${catalog_rgy_ns_and_repo##*/}"

$tools_dir/custom-registry-gen/gen-custom-registry.sh  -P \
   -B "$bundle_image_ref" \
   -r "$catalog_rgy_and_ns" -n "$catalog_repo" -t "$catalog_tag"

