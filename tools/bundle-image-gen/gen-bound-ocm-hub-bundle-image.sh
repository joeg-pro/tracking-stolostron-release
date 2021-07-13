#!/bin/bash

# Generates an OCM Hub bundle image.
#
# Source pkg:  this_repo/operator-bundles/bound/multicluster-hub
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

default_bundle_repo="multicluster-hub-operator-bundle"
input_bundle_manifests_spot="$top_of_repo/operator-bundles/bound/multicluster-hub"
default_image_rgy_and_ns=${OCM_BUILD_IMAGE_RGY_AND_NS:-quay.io/open-cluster-management}

$my_dir/gen-bundle-image.sh \
   -n "$default_bundle_repo" -r "$default_image_rgy_and_ns" \
   -I "$input_bundle_manifests_spot" "$@"

