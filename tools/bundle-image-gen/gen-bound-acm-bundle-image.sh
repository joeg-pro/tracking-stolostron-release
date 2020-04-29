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

local_bundle_image_name="acm-operator-bundle"
remote_bundle_image_name="$local_bundle_image_name"

# DON'T COMMIT:
# remote_bundle_image_name="test-acm-operator-bundle"

# Args (all optional):
# $1 = Bundle version (default: 1.0.0)
# $2 = Remote registry and namespace (default: quay.io/open-cluster-management)
# $3 - Image-tag suffix (default: none)

bundle_vers="${1:-1.0.0}"
remote_rgy_and_ns="${2:-quay.io/open-cluster-management}"
tag_suffix="$3"

tmp_dir="/tmp/acm-bundle-image-build"
build_context="$tmp_dir/build-context"
rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"
mkdir -p "$build_context"

# TODO:  Parameterize gen-bound-acm-bundle for eg. bundle version, etc.
$top_of_repo/tools/bundle-manifests-gen/gen-bound-acm-bundle.sh
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not generate manifests for bound ACM budnle."
   exit 2
fi
# Above leaves resulting package here:
bound_pkg_dir="$top_of_repo/operator-bundles/bound/advanced-cluster-management"
bound_bundle_dir="$bound_pkg_dir/$bundle_vers"

# Turn annotations.yaml into LABEL statemetns for Dockerfile
# - Drop "annotations:" line
# - Convert all others to LABEL statement
tmp_label_lines="$tmp_dir/label-lines"
tail -n +2 "$bound_bundle_dir/metadata/annotations.yaml" | \
   sed "s/: /=/" | sed "s/^ /LABEL/" > "$tmp_label_lines"

tmp_final_dockerfile="$build_context/Dockerfile"
cat "$my_dir/Dockerfile.bundle" | \
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

# Get rid of previous image if any
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

# Reag and push to remote registry
if [[ -n $remote_rgy_and_ns ]]; then
   docker tag "$local_image_name_and_tag" "$remote_rgy_and_ns/$remote_image_name_and_tag"
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Could not retag local image for remote registry."
      exit 2
   fi
   if [[ -n $DOCKER_USER ]]; then
      remote_rgy=${remote_rgy_and_ns%%/*}
      docker login $remote_rgy -u $DOCKER_USER -p $DOCKER_PASS
      if [[ $? -ne 0 ]]; then
         >&2 echo "Error: Could not do docker login."
         exit 2
      fi
      docker push "$remote_rgy_and_ns/$remote_image_name_and_tag"
      if [[ $? -ne 0 ]]; then
         >&2 echo "Error: Could not push image to remote registry."
         exit 2
      fi
   fi
fi

