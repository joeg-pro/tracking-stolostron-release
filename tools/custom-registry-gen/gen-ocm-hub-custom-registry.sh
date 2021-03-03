#!/bin/bash

# Generates a custom registry that can be a catalog source of
# one or more similarly named input ACM (or other) operator bundles.
#
# This script is a simple cover script over gen-custom-registry.sh for use
# in some simple CI cases in which alll input bundles differ only in their tags
# (otherwsie come from same registry, namespace and repository).  For more complex
# use cases, eg where the input bundles come from different places, use the
# underlying custom-registry-gen.sh script directly since its more general.
#
# Args:
#
#  $1 = Tags (probably in x.y.z[-suffix] form) of input bundle images.  Bundles
#       are added to the catalog in the order in which the tags are listed.
#       Last tag is also used as tag of output bundle image (for compatibility).
#
# -r Remote registry server/namespace.  (Default: quay.io/open-cluster-management)
# -b bundle image Name (repo).  (Default: multicluster-hub-operator-bundle)
# -c catalog image Name (repo). (Default: multicluster-hub-custom-registry)
# -P Push image (switch)
#
# -J Prefix for repo names (for testing).  (Default: none)
#
# Cautions:
#
# - Tested on RHEL 8, not on other Linux nor Mac

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))

default_bundle_repo="multicluster-hub-operator-bundle"
default_catalog_repo="multicluster-hub-custom-registry"

default_image_rgy_and_ns=${OCM_BUILD_IMAGE_RGY_AND_NS:-quay.io/open-cluster-management}

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

bundle_tags="$@"
if [[ -z "$bundle_tags" ]]; then
   >&2 echo "Error: One or more bundle tags (x.y.z[-iter]) is required."
   exit 1
fi

remote_rgy_and_ns="${remote_rgy_and_ns:-$default_image_rgy_and_ns}"
bundle_image_repo="${bundle_image_repo:-$default_bundle_repo}"
catalog_image_repo="${catalog_image_repo:-$default_catalog_repo}"

if [[ -n "$test_repo_prefix" ]]; then
   bundle_image_repo="$test_repo_prefix-$bundle_image_repo"
   catalog_image_repo="$test_repo_prefix-$catalog_image_repo"
fi

dash_uppser_b_opts=()
last_tag=""
for t in $bundle_tags; do
   dash_upper_b_opts+=("-B" "$remote_rgy_and_ns/$bundle_image_repo:$t")
   last_tag="$t"
done

if [[ -z "$catalog_tag" ]]; then
   catalog_tag="$last_tag"
fi

$my_dir/gen-custom-registry.sh  \
   "${dash_upper_b_opts[@]}" -n "$catalog_image_repo" \
   -t "$catalog_tag" $dash_p_opt

