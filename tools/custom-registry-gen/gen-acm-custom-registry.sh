#!/bin/bash

# Generates a custom registry that servces the ACM operator bundle.
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
#  $1 = Version number (tag) in x.y.z[-suffix] form of input bundle and output catalog.
#
# -r Remote registry server/namespace.  (Default: quay.io/open-cluster-management)
# -b bundle image Name (repo).  (Default: acm-operator-bundle)
# -c catalog image Name (repo). (Default: acm-custom-registry)
# -J Prefix for repo names (for testing).  (Default: none)
# -P Push image (switch)

opt_flags="r:b:c:J:P"

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

bundle_and_catalog_vers="$1"
if [[ -z "$bundle_and_catalog_vers" ]]; then
   >&2 echo "Error: Bundle/catalog version (x.y.z[-iter]) is required."
   exit 1
fi

remote_rgy_and_ns="${remote_rgy_and_ns:-quay.io/open-cluster-management}"
bundle_image_repo="${bundle_image_repo:-acm-operator-bundle}"
catalog_image_repo="${catalog_image_repo:-acm-custom-registry}"

if [[ -n "$test_repo_prefix" ]]; then
   bundle_image_repo="$test_repo_prefix-$bundle_image_repo"
   catalog_image_repo="$test_repo_prefix-$catalog_image_repo"
fi

bundle_image_ref="$remote_rgy_and_ns/$bundle_image_repo:$bundle_and_catalog_vers"

$tools_dir/custom-registry-gen/gen-custom-registry.sh  \
   -B "$bundle_image_ref" -n "$catalog_image_repo" \
   -v "$bundle_and_catalog_vers" $dash_p_opt

