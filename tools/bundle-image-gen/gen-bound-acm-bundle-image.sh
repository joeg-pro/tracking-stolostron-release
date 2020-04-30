#!/bin/bash

# Generates bound ACM bundle image (in new (not-App Registry) format)

# Source pkg:  this_repo/operator-bundles/unbound/advanced-cluster-management
# Output pkg:  this_repo/operator-bundles/bound/advanced-cluster-management
#
# Requires image manfest (eg. 1.0.0.json) in current working directory.
#
# Assumptions:
# - We assume this script is located two subdirectories below top of the
#   release repo (as it sppears in Git).
#
# Cautions:
#
# - Tested on RHEL 8, not on other Linux nor Mac
# - This script uses sed, so Mac-compatbility problems may exist.
#
# Requires:
# - Python 3.6 with pyyaml (for underlying Pyton scripts)
# - readlink
# - tail
# - sed
# - tar
# - docker or podman with docker-compat wrappers

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))

top_of_repo=$(readlink  -f $my_dir/../..)

default_bound_pkg_dir="$top_of_repo/operator-bundles/bound/advanced-cluster-management"

# -- Args ---

# -I Input bundle manifests directory (default: in $top_of_repo/operator-bundles/bound)
# -r Remote registry server/namespace.  (Default: quay.io/open-cluster-management)
# -n local image Name.  (Default: acm-operator-bundle)
# -R remote image Name (default: same as local image name)
# -v Version (x.y.z) of generated bundle image (for tag).  (Default: 1.0.0)
# -s image tag Suffix.  (default: none)
# -P Push image (switch)

opt_flags="I:r:n:N:v:s:P"

push_the_image=0
tag_suffix=""

while getopts "$opt_flags" OPTION; do
   case "$OPTION" in
      I) bound_bundle_dir="$OPTARG"
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

bundle_vers="${bundle_vers:-1.0.0}"
default_bound_bundle_dir="$default_bound_pkg_dir/$bundle_vers"
bound_bundle_dir="${bound_bundle_dir:-$default_bound_bundle_dir}"

local_bundle_image_name="${local_bundle_image_name:-acm-operator-bundle}"
remote_bundle_image_name="${remote_bundle_image_name:-$local_bundle_image_name}"
remote_rgy_and_ns="${remote_rgy_and_ns:-quay.io/open-cluster-management}"

tmp_dir="/tmp/acm-bundle-image-build"
build_context="$tmp_dir/build-context"
rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"
mkdir -p "$build_context"

if [[ ! -d "$bound_bundle_dir" ]]; then
   >&2 echo "Error: Input bundle manifests directory does not exist: $bound_bundle_dir"
   exit 2
fi

# Turn annotations.yaml into LABEL statemetns for Dockerfile
# - Drop "annotations:" line
# - Convert all others to LABEL statement
tmp_label_lines="$tmp_dir/label-lines"
tail -n +2 "$bound_bundle_dir/metadata/annotations.yaml" | \
   sed "s/: /=/" | sed "s/^ /LABEL/" > "$tmp_label_lines"

tmp_final_dockerfile="$build_context/Dockerfile"
cat "$my_dir/Dockerfile.template" | \
   sed "/!!ANNOTATION_LABELS!!/r $tmp_label_lines" | \
   sed "/!!ANNOTATION_LABELS!!/d" > "$tmp_final_dockerfile"

# Copy bundle dirs into the docker build context
tar -cf - -C $bound_bundle_dir manifests metadata | (cd $build_context; tar xf -)

# Form tag
image_tag="$bundle_vers"
if [[ -n "$tag_suffix" ]]; then
   image_tag="$image_tag-$tag_suffix"
fi

local_image_name_and_tag="$local_bundle_image_name:$image_tag"
remote_image_name_and_tag="$remote_bundle_image_name:$image_tag"

# Get rid of previous local image if any
images=$(docker images --format "{{.Repository}}:{{.Tag}}" "$local_image_name_and_tag")
for img in $images; do
   docker rmi "$img" > /dev/null
done

# Build the image locally
# Note: --squash doesn't work under Travis because appearantly it doesn't have
# experimental docker features enabled.  (Hub?)
docker build -t "$local_image_name_and_tag" "$build_context"
# FYI: Buildah equivalent:  buildah bud -t "$image_name_and_tag" "$build_context"

if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not build bouund ACM budnle image."
   exit 2
fi
echo "Succesfully built image: $local_image_name_and_tag"

# Reag to be appropriate for remote registry
if [[ -n $remote_rgy_and_ns ]]; then
   docker tag "$local_image_name_and_tag" "$remote_rgy_and_ns/$remote_image_name_and_tag"
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Could not retag local image for remote registry."
      exit 2
   fi
   echo "Succesfully taggested image as: $remote_rgy_and_ns/$remote_image_name_and_tag"

   if [[ $push_the_image -eq 1 ]]; then
      if [[ -n $DOCKER_USER ]]; then
         remote_rgy=${remote_rgy_and_ns%%/*}
         docker login $remote_rgy -u $DOCKER_USER -p $DOCKER_PASS
         if [[ $? -ne 0 ]]; then
            >&2 echo "Error: Error doing docker login to remote registry."
            exit 2
         fi
         docker push "$remote_rgy_and_ns/$remote_image_name_and_tag"
         if [[ $? -ne 0 ]]; then
            >&2 echo "Error: Failed to push to remote registry."
            exit 2
         fi
      else
         >&2 echo "Error: Cannot push image to remote registry: DOCKER_USER not set."
         exit 2
      fi
   fi
fi

