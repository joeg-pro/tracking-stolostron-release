#!/bin/bash

# Generates an OCM Hub bundle image (in new bundle-image format by default)
#
# Source pkg:  this_repo/operator-bundles/bound/multicluster-hub
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
# $1 = Bundle version number (x.y.z[-iter]). (Required)
#
# -r Remote registry server/namespace.  (Default: quay.io/open-cluster-management)
# -n image Name (repo).  (Default: multicluster-hub-operator-bundle)
# -t image Tag (Default: Use bundle version)
# -P Push the image (switch)
#
# -J Prefix for repo names (for testing).  (Default: none)
# -a use App Registry format (switch)

opt_flags="r:n:t:PJ:a"

dash_p_opt=""
dash_a_opt=""
dash_t_opt=""

while getopts "$opt_flags" OPTION; do
   case "$OPTION" in
      r) remote_rgy_and_ns="$OPTARG"
         ;;
      n) bundle_repo="$OPTARG"
         ;;
      P) dash_p_opt="-P"
         ;;
      t) dash_t_opt="-t $OPTARG"
         ;;
      J) test_repo_prefix="$OPTARG"
         ;;
      a) dash_a_opt="-a"
         ;;
      ?) exit 1
         ;;
   esac
done
shift "$(($OPTIND -1))"

bundle_vers="$1"
if [[ -z "$bundle_vers" ]]; then
   >&2 echo "Error: Bundle version (x.y.z[-iter]) is required."
   exit 1
fi

remote_rgy_and_ns="${remote_rgy_and_ns:-quay.io/open-cluster-management}"
bundle_repo="${bundle_repo:-multicluster-hub-operator-bundle}"

if [[ -n "$test_repo_prefix" ]]; then
   bundle_repo="$test_repo_prefix-$bundle_repo"
fi

$tools_dir/bundle-image-gen/gen-bundle-image.sh \
   -I "$top_of_repo/operator-bundles/bound/multicluster-hub" \
   -r $remote_rgy_and_ns -n $bundle_repo -v $bundle_vers \
   $dash_t_opt $dash_p_opt $dash_a_opt

