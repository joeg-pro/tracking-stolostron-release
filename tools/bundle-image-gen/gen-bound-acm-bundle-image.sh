#!/bin/bash

# Generates an ACM bundle image.
#
# Source pkg:  this_repo/operator-bundles/bound/advanced-cluster-management
#
# Args:
#   Same as underlying gen-bundle-image.sh script.
#
# Options:
#   Same as underlying gen-bundle-image.sh script.
#
# Cautions:
#
# - Tested on RHEL 8, not on other Linux nor Mac.

me=$(basename "$0")
my_dir=$(dirname $(readlink -f "$0"))

source "$my_dir/bundle-common.bash"
# Sets top_of_repo

default_bundle_repo="acm-operator-bundle"
input_bundle_manifests_spot="$top_of_repo/operator-bundles/bound/advanced-cluster-management"
default_image_rgy_and_ns=${OCM_BUILD_IMAGE_RGY_AND_NS:-quay.io/stolostron}

$my_dir/gen-bundle-image.sh \
   -n "$default_bundle_repo" -r "$default_image_rgy_and_ns" \
   -I "$input_bundle_manifests_spot" "$@"

