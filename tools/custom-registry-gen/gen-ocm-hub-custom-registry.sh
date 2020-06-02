#!/bin/bash

# Generates a custom registry that servces the OCM Hub operator bundle.
#
# Assumptions:
# - We assume this script is located two subdirectories below top of the
#   release repo (as it sppears in Git).
#
# Cautions:
#
# - Tested on RHEL 8, not on other Linux nor Mac

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink  -f $my_dir/../..)
tools_dir="$top_of_repo/tools"

# -- Args ---
#
#  $1 = Tag (probably in x.y.z[-suffix] form) of input bundle image and output catalog image.
#
# -r Remote registry server/namespace.  (Default: quay.io/open-cluster-management)
# -b bundle image Name (repo).  (Default: multicluster-hub-operator-bundle)
# -c catalog image Name (repo). (Default: multicluster-hub--custom-registry)
# -P Push image (switch)
#
# -J Prefix for repo names (for testing).  (Default: none)

opt_flags="r:b:c:PJ:"

dash_p_opt=""

while getopts "$opt_flags" OPTION; do
   case "$OPTION" in
      r) remote_rgy_and_ns="$OPTARG"
         ;;
      b) bundle_image_repo="$OPTARG"
         ;;
      c) catalog_image_repo="$OPTARG"
         ;;
      J) test_repo_prefix="$OPTARG"
         ;;
      P) dash_p_opt="-P"
         ;;
      ?) exit 1
         ;;
   esac
done
shift "$(($OPTIND -1))"

bundle_and_catalog_tag="$1"
if [[ -z "$bundle_and_catalog_tag" ]]; then
   >&2 echo "Error: Bundle/catalog tag (x.y.z[-iter]) is required."
   exit 1
fi

remote_rgy_and_ns="${remote_rgy_and_ns:-quay.io/open-cluster-management}"
bundle_image_repo="${bundle_image_repo:-multicluster-hub-operator-bundle}"
catalog_image_repo="${catalog_image_repo:-multicluster-hub-custom-registry}"

if [[ -n "$test_repo_prefix" ]]; then
   bundle_image_repo="$test_repo_prefix-$bundle_image_repo"
   catalog_image_repo="$test_repo_prefix-$catalog_image_repo"
fi

bundle_image_ref="$remote_rgy_and_ns/$bundle_image_repo:$bundle_and_catalog_tag"

$tools_dir/custom-registry-gen/gen-custom-registry.sh  \
   -B "$bundle_image_ref" -n "$catalog_image_repo" \
   -t "$bundle_and_catalog_tag" $dash_p_opt

