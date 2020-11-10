#!/bin/bash

# This script executes a sequence of steps entirely upstream that reflects the
# combination of steps performedd in part upstream and in part downstream during
# a product build to produce an product-packaged operator bundle for the ACM.
# However, to avoid confusion with a true donwstream build, the resulting bundle
# does not have product branding.
#
# This script defaults to using the "new" bundle-image format of providing
# operator metadata.  App Registry format can be request instead via -a arg.

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink  -f $my_dir/../..)
tools_dir="$top_of_repo/tools"

default_channel_name="release-2.1"

# -- Args --

# $1 Bundle version for this bundle (Format: x.y.z[-iter]).  (Required)
# $2 Version of bundle replaced by this one (Format: x.y.z[-iter]).  Default: None
#
# -r remote Registry server/namespace. (Default: quay.io/open-cluster-management)
# -b Budnle repository name (default: acm-operator-bundle)
# -c Custom catalog repository Name (default: acm-custom-registry)
# -t image Tag for bundle/catalog (default: use bundle version)
# -P Push the bundle image to remote registry after producing it (switch)
#
# -J Prefix for repo names (for testing).  (Default: none)
# -a Build bundle in old App Registry format (switch)

opt_flags="r:b:c:t:PJ:a"

dash_a_opt=""
dash_p_opt=""
dash_j_opt=""
image_tag=""

while getopts "$opt_flags" OPTION; do
   case "$OPTION" in
      r) bundle_rgy_and_ns="$OPTARG"
         ;;
      b) bundle_repo="$OPTARG"
         ;;
      c) catalog_repo="$OPTARG"
         ;;
      t) image_tag="$OPTARG"
         ;;
      J) dash_j_opt="-J $OPTARG"
         ;;
      P) dash_p_opt="-P"
         ;;
      a) dash_a_opt="-a"
         ;;
      ?) exit 1
         ;;
   esac
done
shift "$(($OPTIND -1))"

what_kind="ACM"
script_qualifier="acm"

bundle_rgy_and_ns="${bundle_rgy_and_ns:-quay.io/open-cluster-management}"
bundle_repo="${bundle_repo:-acm-operator-bundle}"
catalog_repo="${catalog_repo:-acm-custom-registry}"

bundle_vers="$1"
if [[ -z "$bundle_vers" ]]; then
   >&2 echo "Error: Bundle version (x.y.z[-iter]) is required."
   exit 1
fi
prev_vers="$2"
if [[ -z "$prev_vers" ]]; then
   echo "Note: This bundle will not be configured as replacing a previous bundle version."
   prev_vers="none"
fi

if [[ -n "$image_tag" ]]; then
   dash_t_opt="-t $image_tag"
else
   image_tag="$bundle_vers"
fi

# -- End Args --

echo ""
echo "----- [ Generating Unbound $what_kind Bundle Manifests ] -----"
echo ""

$tools_dir/bundle-manifests-gen/gen-unbound-$script_qualifier-bundle.sh "$bundle_vers"
if [[ $? -ne 0 ]]; then
   >&2 echo "ABORTING! Could not generate unbound $what_kind bundle manifests."
   exit 2
fi

echo ""
echo "----- [ Generating Bound $what_kind Bundle Manifests ] -----"
echo ""

# Note: During a real product build, this step is done downstream using the same
# same script being run here and unbound bundle manifests generated upstream
# as done above and snpashotted into a branch for consumption downstream.

$tools_dir/bundle-manifests-gen/gen-bound-$script_qualifier-bundle.sh "$bundle_vers" "$prev_vers" "$default_channel_name"
if [[ $? -ne 0 ]]; then
   >&2 echo "ABORTING! Could not generate bound $what_kind bundle manifests."
   exit 2
fi

echo ""
echo "----- [ Generating $what_kind Bundle Image ] -----"
echo ""

# Note: During a real product build, this step is done downstream using
# some scripting and Dockerifle maintained in midstream.

$tools_dir/bundle-image-gen/gen-bound-$script_qualifier-bundle-image.sh \
   -r "$bundle_rgy_and_ns" -n "$bundle_repo" \
   $dash_t_opt $dash_p_opt $dash_a_opt $dash_j_opt \
   "$bundle_vers"
if [[ $? -ne 0 ]]; then
   >&2 echo "ABORTING! Could not generate $what_kind bundle image."
   exit 2
fi

echo ""
echo "----- [ Generating $what_kind Custom Registry Image ] -----"
echo ""

$tools_dir/custom-registry-gen/gen-$script_qualifier-custom-registry.sh \
   -r "$bundle_rgy_and_ns" -b "$bundle_repo" -c "$catalog_repo" \
   $dash_p_opt $dash_j_opt \
   "$image_tag"
if [[ $? -ne 0 ]]; then
   >&2 echo "FAILED! Could not generate $what_kind custom catalog image."
   exit 2
fi

