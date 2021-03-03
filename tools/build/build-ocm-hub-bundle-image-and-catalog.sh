#!/bin/bash

# This script executes the steps performed (entirely) upstream to
# produce an upstream/"community"-packaged operator bundle for the OCM Hub.
#
# Args:
#
# $1 Bundle version for this bundle (Format: x.y.z[-iter]).  (Required)
#
# -r remote Registry server/namespace. (Default: quay.io/open-cluster-management)
# -b Budnle repository name (default: multicluster-hub-operator-bundle)
# -c Custom catalog repository Name (Default: multicluster-hub-custom-registry)
# -t image Tag for bundle/catalog (Default: use bundle version)
# -P Push the bundle image and catalogs to remote registry after producing it (switch)
#
# -J Prefix for repo names (for testing).  (Default: none)
#
# For use by scripts covering wrapping this one:
#
# -w Qualifier appended to names of lower-level scripts we invoke.
# -W "what kind" string for messages.
#
# Assumptions:
# - We assume this script lives two directory levles below the top of the repo.

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink  -f $my_dir/../..)
tools_dir="$top_of_repo/tools"

default_bundle_repo="multicluster-hub-operator-bundle"
default_catalog_repo="multicluster-hub-custom-registry"

default_image_rgy_and_ns=${OCM_BUILD_IMAGE_RGY_AND_NS:-quay.io/open-cluster-management}

opt_flags="r:b:c:t:PJ:w:W:"

dash_a_opt=""
dash_p_opt=""
dash_j_opt=""
image_tag=""

what_kind="OCM Hub"
script_qualifier="ocm-hub"

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
      w) script_qualifier="$OPTARG"
         ;;
      W) what_kind="$OPTARG"
         ;;
      ?) exit 1
         ;;
   esac
done
shift "$(($OPTIND -1))"

bundle_rgy_and_ns="${bundle_rgy_and_ns:-$default_image_rgy_and_ns}"
bundle_repo="${bundle_repo:-$default_bundle_repo}"
catalog_repo="${catalog_repo:-$default_catalog_repo}"

bundle_vers="$1"
if [[ -z "$bundle_vers" ]]; then
   >&2 echo "Error: Bundle version (x.y.z[-iter]) is required."
   exit 1
fi

# Notes:
#
# As an upstream build we generate the final (bound) bundle with no replacement-graph
# properties because we currently lack the build smarts in upstream to know how to
# build a catalog with all of the right predecessor bundles in it. So we generate
# just a single-bundle catalog and to make sure that always works, we have to drop
# all eg. replaces properties from the CSV.
#
# For a Red Hat product build, the generation of the bound bundle manifests is done
# using the same tooling we use here, but with appropriate input so as to maintain
# the replacement graph.

echo "Note: This bundle will not include any replacement-graph properties."
prev_vers="none"

if [[ -n "$image_tag" ]]; then
   dash_t_opt="-t $image_tag"
else
   image_tag="$bundle_vers"
fi


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

# Note: During a Red Hat product build, this step is done in the downstream build
# pipline using the same script being run here and and the same unbound bundle manifests
# generated just above above. But the Red Hat downstream build maintains/supplies
# predecessor infomration we don't maintain in the upstream.

$tools_dir/bundle-manifests-gen/gen-bound-$script_qualifier-bundle.sh "$bundle_vers" "$prev_vers"
if [[ $? -ne 0 ]]; then
   >&2 echo "ABORTING! Could not generate bound $what_kind bundle manifests."
   exit 2
fi

echo ""
echo "----- [ Generating $what_kind Bundle Image ] -----"
echo ""

# Note: During a Red Hat product build, this step is done in the downstream build
# pipeline using scripting and Dockerifles unique to the downstream.  The following
# is a metaphorical approximation of what is done downstream.

$tools_dir/bundle-image-gen/gen-bound-$script_qualifier-bundle-image.sh \
   -r "$bundle_rgy_and_ns" -n "$bundle_repo" \
   $dash_t_opt $dash_p_opt $dash_a_opt $dash_j_opt \
   "$bundle_vers"
if [[ $? -ne 0 ]]; then
   >&2 echo "ABORTING! Could not generate $what_kind bundle image."
   exit 2
fi

# Note: For purposes of a Red Hat product build and release, there is no custom OLM
# catalog/registry for our bundle.  Rather, the bundle image built in the Red Hat
# downstream is published into catalogs served by the Red Hat production infrastructure.
# We build a catalog here so we have something to use in testing in the upstream and
# before we push-to-prod downstream.

echo ""
echo "----- [ Generating $what_kind Custom Registry Image ] -----"
echo ""

$tools_dir/custom-registry-gen/gen-$script_qualifier-custom-registry.sh \
   -r "$bundle_rgy_and_ns" -b "$bundle_repo" -c "$catalog_repo" \
   $dash_p_opt $dash_j_opt "$image_tag"
if [[ $? -ne 0 ]]; then
   >&2 echo "FAILED! Could not generate $what_kind custom catalog image."
   exit 2
fi

