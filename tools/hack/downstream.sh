#!/bin/bash

# This script approximates the steps performed downstream to turn the unbound
# ACM operator bundle manifests we send downstream (via the contents of this
# repo's operator-bundles/unbound directory) into an operator bundle image.
#
# NOTES:
#
# - THIS SCRIPT IS NOT CURRENTLY USED DOWNSTREAM.  IT IS MEANT AS AN EXEMPLAR ONLY.
#
# - Downstream is KNOWN to operate differently.  For example donstream uses a
#   Dockerfile that is maintained in dist-git and is different than the one that
#   is being generated from a template by this script.
#
# - This script ucrrently uses the "new" bundle-image format of providing operator
#   metadata.  But due to snags downstream, we were forced to pivot to using the
#   "old" app-registry operator metadata format for ACM 1.0.0.

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink  -f $my_dir/../..)

tools_dir="$top_of_repo/tools"

# -- Args --

# -r remote Registry server/namespace.  (Default: quay.io/open-cluster-management)
# -n repository Name (default: acm-operator-bundle)
# -v Version (x.y.z) of generated bundle image (for tag).  (Default: 1.0.0)
# -s image tag Suffix.  (default: none)

opt_flags="r:n:v:s:a"

push_the_image=0
use_bundle_image_format=1
tag_suffix=""

while getopts "$opt_flags" OPTION; do
   case "$OPTION" in
      r) bundle_rgy_and_ns="$OPTARG"
         ;;
      n) bundle_repo="$OPTARG"
         ;;
      v) bundle_vers="$OPTARG"
         ;;
      s) vers_suffix="$OPTARG"
         ;;
      a) use_bundle_image_format=0
         ;;
      ?) exit 1
         ;;
   esac
done
shift "$(($OPTIND -1))"

bundle_vers="${bundle_vers:-1.0.0}"
bundle_rgy_and_ns="${bundle_rgy_and_ns:-quay.io/open-cluster-management}"
bundle_repo="${bundle_repo:-acm-operator-bundle}"

# -- End Args --

if [[ -n "$vers_suffix" ]]; then
   bundle_vers="$bundle_vers-$vers_suffix"
fi

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


echo ""
echo "----- [ Generating Bound Bundle Manifests ] -----"
echo ""

$tools_dir/bundle-manifests-gen/gen-bound-acm-bundle.sh "$bundle_vers"
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

echo ""
echo "----- [ Generating Bundle Image ] -----"
echo ""

if [[ $use_bundle_image_format -eq 0 ]]; then
  dash_a_arg="-a"
fi

$tools_dir/bundle-image-gen/gen-bound-acm-bundle-image.sh -P $dash_a_arg \
   -r "$bundle_rgy_and_ns" -n "$bundle_repo" -v "$bundle_vers"
if [[ $? -ne 0 ]]; then
   >&2 echo "ABORTING! Could not generate ACM bundle image."
   exit 2
fi

# Step 3:
# Push image to delivery repo.
# We assume this is handled by a human or process driving this script.

