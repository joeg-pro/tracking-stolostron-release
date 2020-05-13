#!/bin/bash

# Re-bundke:
#
# Transform an ACM operator bundle image constructed downstream to be one that is
# correct for use with a set of images mirrored from downstream into a registry
# and namespace visible for testing.
#
# The new operator bundle is not built from "source manifests" but rather os built
# using the manifests fuond in the downstream-built bundle.  Only the CSV is changed,
# and its only changed to update image references found in it.  BY using this approach,
# we avoid the possibility of "synchronization" errors tha tmight occur if we rebuilt
# the bundle using source CSVs and CRD manifests.
#
# Requires:
#
# - jq
#
# TODO: Add args:
# - soruce bundle image (source of operator-bundle manifests)
# - destintation stuff

# Figure out who we are, where we're at, and where top-of-repo is.

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink  -f $my_dir/../..)
tools_dir="$top_of_repo/tools"

# Args:

# -I full image reference for Input bundle image (required)
# -r Remote registry server/namespace for output bundle. (Default: quay.io/acm-d)
# -n local image Name for output bundle.  (Default: acm-operator-bundle)
# -R remote image Name for output bundle (default: same as local image name)
# -v Version (x.y.z) of generated bundle image (for tag).  (Default: 1.0.0)
# -s image tag Suffix.  (default: none)
# -P Push image (switch)

opt_flags="I:r:n:N:v:s:P"

push_the_image=0
tag_suffix=""

while getopts "$opt_flags" OPTION; do
   case "$OPTION" in
      I) source_bundle_image_ref="$OPTARG"
         ;;
      r) remote_rgy_and_ns="$OPTARG"
         ;;
      n) local_bundle_image_name="$OPTARG"
         ;;
      N) remote_bundle_image_name="$OPTARG"
         ;;
      v) bundle_vers="$OPTARG"
         ;;
      s) tag_suffix="$OPTARG"
         ;;
      P) push_the_image=1
         ;;
      ?) exit 1
         ;;
   esac
done
shift "$(($OPTIND -1))"

# Required arg policing...

if [[ -z $source_bundle_image_ref ]]; then
   >&2 echo "Error: Reference to input bundle image is required (-I)."
   exit 1
fi

# Defaulting for args not specified...

remote_rgy_and_ns="${remote_rgy_and_ns:-quay.io/acm-d}"
local_bundle_image_name="${local_bundle_image_name:-acm-operator-bundle}"
remote_bundle_image_name="${remote_bundle_image_name:-$local_bundle_image_name}"

bundle_vers="${bundle_vers:-1.0.0}"

# Hardcoded:

source_bundle_image_ref="quay.io/open-cluster-management/acm-operator-bundle:1.0.0"

target_bundle_rgy_and_ns="quay.io/open-cluster-management"
target_bundle_repo="jmg-test-operator-bundle"

release_nr="1.0.0"



# Die functions to issue error msgs to stdout and kill script.  Handles sub-shells.

trap "exit 2" TERM
export top_shell_pid=$$

function die() {
   >&2 echo "$@"
   kill -s TERM $top_shell_pid
}

function die_if_error() {
   if [[ $? -ne 0 ]]; then
      die "$1"
   fi
}

# Some funcitons to reduce code duplication....

function create_container() {
   container_id=$(docker create "$1" /dummy.cmd)
   die_if_error "FATAL: Could not create docker container to be used for file extracting."
   echo $container_id
}

# Copies a file from an image
function copy_from_image() {
   local image_ref=$1
   local pathn=$2
   local dest_pathn=${3:-.}

   container_id=$(create_container $image_ref)
   docker cp "$container_id:$pathn" "$dest_pathn"
   die_if_error "Error copying $pathn from container image $image_ref."
   docker rm -v $container_id > /dev/null
}

# Exports an entire image's contents to a directory.
function export_image() {
   local image_ref=$1
   local dest_dir_pathn=$2
   container_id=$(create_container $image_ref)
   docker export "$container_id" | (cd "$dest_dir_pathn"; tar xf -)
   die_if_error "Error exporting contents of $image_ref to $dest_pathn."
   docker rm -v $container_id > /dev/null
}

# --- End of Preliminaries ---


work_dir="$top_of_repo/_work/$me"

rm -rf "$work_dir"
mkdir -p "$work_dir"
bundle_dir="$work_dir/bundle"

# TODO: Pull source hub operator image

# Grab the operator bundle manifests from the source bundle, as we're about to
# rebind them baseed on the mirroring overrides.

mkdir -p "$bundle_dir"

export_image "$source_bundle_image_ref" "$bundle_dir"

# Edit the CSV in the bundle to Update the "remote" part of the image references.

csv_fn="advanced-cluster-management.v$release_nr.clusterserviceversion.yaml"
csv_pathn="$bundle_dir/manifests/$csv_fn"

echo $csv_pathn

$tools_dir/bundle-manifests-gen/remap-csv-image-refs.py \
   --csv-pathn "$csv_pathn" \
   --rgy-ns-override "quay.io/open-cluster-management:quay.io/acm-d"

# Create a new bundle image with the updated CSV (and other parts unchanged).

target_bundle_rgy_and_ns="quay.io/acm-d"
$tools_dir/bundle-image-gen/gen-bound-acm-bundle-image.sh \
   -I "$bundle_dir" \
   -r "$target_bundle_rgy_and_ns" \
   -n "$target_bundle_repo"
if [[ $? -ne 0 ]]; then
   >&2 echo "ABORTING! Could not generate ACM bundle image."
   exit 2
fi


