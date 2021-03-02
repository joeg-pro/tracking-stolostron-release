#!/bin/bash

# Generates an OCM Hub bundle image.
#
# Source pkg:  this_repo/operator-bundles/bound/multicluster-hub
#
# Assumptions:
# - We assume this script is located two subdirectories below top of the
#   release repo (as it sppears in Git).
#
# Args:
#
# $1 = Bundle version number (x.y.z[-iter]).
#
# Options:
# -n image Name (repo).  (Default: multicluster-hub-operator-bundle)
# -t image Tag (Default: Use bundle version)
# -r Remote registry server/namespace. (Default: quay.io/open-cluster-management)
# -P Push the image after building. (switch)
#
# -J Prefix for repo names (for testing).  (Default: none)
#
# Cautions:
#
# - Tested on RHEL 8, not on other Linux nor Mac.

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink  -f $my_dir/../..)

default_bundle_repo="multicluster-hub-operator-bundle"
input_bundle_manifests_spot="$top_of_repo/operator-bundles/bound/multicluster-hub"

default_image_rgy_and_ns=${OCM_BUILD_IMAGE_RGY_AND_NS:-quay.io/open-cluster-management}

opt_flags="r:n:t:PJ:a"

bundle_repo=""
rgy_and_ns=""
dash_p_opt=""
dash_t_opt=()

while getopts "$opt_flags" OPTION; do
   case "$OPTION" in
      r) rgy_and_ns="$OPTARG"
         ;;
      n) bundle_repo="$OPTARG"
         ;;
      P) dash_p_opt="-P"
         ;;
      t) dash_t_opt=("-t" "$OPTARG")
         ;;
      J) test_repo_prefix="$OPTARG"
         ;;
      ?) exit 1
         ;;
   esac
done
shift "$(($OPTIND -1))"

bundle_vers="$1"

bundle_repo="${bundle_repo:-$default_bundle_repo}"
if [[ -n "$test_repo_prefix" ]]; then
   bundle_repo="$test_repo_prefix-$bundle_repo"
fi

if [[ -z "$rgy_and_ns" ]]; then
   rgy_and_ns="$default_image_rgy_and_ns"
fi

$my_dir/gen-bundle-image.sh \
   -n "$bundle_repo" -v "$bundle_vers" -I "$input_bundle_manifests_spot" \
   -r "$rgy_and_ns" "${dash_t_opt[@]}" $dash_p_opt

