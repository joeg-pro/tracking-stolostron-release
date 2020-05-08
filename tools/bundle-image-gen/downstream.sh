#!/bin/bash

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink  -f $my_dir/../..)

tools_dir="$top_of_repo/tools"

# Assumption:  This repo's is available at $top_of_repo.

# Step 1:
# Use unbound bundle manifests (.yamls) available in this repo (committed to branch in
# the upstream) and an image manifestto with downstream digests (dropped in downstream)
# to generate bound manifests to ne put into the image.
#
# Requires:
# - Downstream image manifests has been dropped in as:
#   $top_of_repo/image-manifests/1.0.0.json
#
# Output:
# - Resulting bound bundle manifests are left in:
#   $top_of_repo/operator-bundles/bound/advanced-cluster-management

$tools_dir/bundle-manifests-gen/gen-bound-acm-bundle.sh
if [[ $? -ne 0 ]]; then
   >&2 echo "ABORTING! Could not generate bound ACM bundle manifests."
   exit 2
fi

# Step 2:
# Use the bound bundle manifests created in Step 1 to generate a Dockerfile (with some
# stuff plugged in based on the manifests) and build image.
#
# Output:
# - Leaves local docker image: $bundle_rgy_and_ns/acm-operator-bundle:1.0.0

bundle_rgy_and_ns="quay.io/acm-d"
bundle_repo="acm-operator-bundle"
$tools_dir/bundle-image-gen/gen-bound-acm-bundle-image.sh -r "$bundle_rgy_and_ns" -n "$bundle_repo"
if [[ $? -ne 0 ]]; then
   >&2 echo "ABORTING! Could not generate ACM bundle image."
   exit 2
fi

# Step 3:
# Push image to delivery repo.
# We assume this is handled by a human or process driving this script.

