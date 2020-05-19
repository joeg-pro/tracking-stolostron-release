#!/bin/bash

# Generates an ACM bundle image (in new bundle-image format by default)
#
# Source pkg:  this_repo/operator-bundles/bound/advanced-cluster-management
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
# -r Remote registry server/namespace.  (Default: quay.io/open-cluster-management)
# -n image Name (repo).  (Default: acm-operator-bundle)
# -v Version (x.y.z) of generated bundle image (for tag).  (Default: 1.0.0)
# -s version Suffix.  (default: none)
# -P Push image (switch)
# -a use App Registry format (switch)

opt_flags="r:n:v:s:Pa"

dash_s_opt=""
dash_p_opt=""
dash_a_opt=""

while getopts "$opt_flags" OPTION; do
   case "$OPTION" in
      r) remote_rgy_and_ns="$OPTARG"
         ;;
      n) bundle_repo="$OPTARG"
         ;;
      v) bundle_vers="$OPTARG"
         ;;
      s) dash_s_opt=="-s $OPTARG"
         ;;
      P) dash_p_opt="-P"
         ;;
      a) dash_a_opt="-P"
         ;;
      ?) exit 1
         ;;
   esac
done
shift "$(($OPTIND -1))"

remote_rgy_and_ns="${remote_rgy_and_ns:-quay.io/open-cluster-management}"
bundle_repo="${bundle_repo:-acm-operator-bundle}"
bundle_vers="${bundle_vers:-1.0.0}"

$tools_dir/bundle-image-gen/gen-bundle-image.sh \
   -I "$top_of_repo/operator-bundles/bound/advanced-cluster-management" \
   -r $remote_rgy_and_ns -n $bundle_repo -v $bundle_vers \
   $dash_s_opt $dash_p_opt $dash_a_opt

