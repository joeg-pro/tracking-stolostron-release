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
#
# $1 = Bundle version number (x.y.z[-iter]).
#
# -r Remote registry server/namespace.  (Default: quay.io/open-cluster-management)
# -n image Name (repo).  (Default: acm-operator-bundle)
# -J Prefix for repo names (for testing).  (Default: none)
# -P Push the image (switch)
# -a use App Registry format (switch)
#
# For backward compatibility with initial version of this script (deprecated):
# -v Version (x.y.z) of generated bundle image (for tag). (used if positional arg not specified)
# -s suffix (-iter) for bundle version (for tag). (used if positoinal arg not specified)

opt_flags="r:n:J:Pav:s:"

dash_p_opt=""
dash_a_opt=""
dash_s_opt=""

while getopts "$opt_flags" OPTION; do
   case "$OPTION" in
      r) remote_rgy_and_ns="$OPTARG"
         ;;
      n) bundle_repo="$OPTARG"
         ;;
      P) dash_p_opt="-P"
         ;;
      J) test_repo_prefix="$OPTARG"
         ;;
      a) dash_a_opt="-a"
         ;;
      v) bundle_vers_from_opt="$OPTARG"
         ;;
      s) vers_suffix="$OPTARG"
         ;;
      ?) exit 1
         ;;
   esac
done
shift "$(($OPTIND -1))"

# Getting the complete bundle version (including suffix) from our first positional
# arg is the preferred way.  But for backwards compatibility with the 1.0.0 version of
# this script, continue to honor the -v and -s options if $1 is not specified.

bundle_vers="$1"
if [[ -z "$bundle_vers" ]]; then
   bundle_vers="${bundle_vers_from_opt:-1.0.0}"
   if [[ -n "$vers_suffix" ]]; then
      dash_s_opt="-s $vers_suffix"
   fi
else
   if [[ -n "$bundle_vers_from_opt" ]]; then
      >&2 echo "Error: Deprecated -v option not allowed when version specified as positional argument."
      exit 1
   fi
   if [[ -n "$vers_suffix" ]]; then
      >&2 echo "Error: Deprecated -s option not allowed when version specified as positional argument."
      exit 1
   fi
fi

remote_rgy_and_ns="${remote_rgy_and_ns:-quay.io/open-cluster-management}"
bundle_repo="${bundle_repo:-acm-operator-bundle}"

if [[ -n "$test_repo_prefix" ]]; then
   bundle_repo="$test_repo_prefix-$bundle_repo"
fi

$tools_dir/bundle-image-gen/gen-bundle-image.sh \
   -I "$top_of_repo/operator-bundles/bound/advanced-cluster-management" \
   -r $remote_rgy_and_ns -n $bundle_repo -v $bundle_vers \
   $dash_p_opt $dash_a_opt $dash_s_opt

