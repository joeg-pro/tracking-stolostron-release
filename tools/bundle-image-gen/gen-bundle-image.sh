#!/bin/bash

# Generates a bundle image.
#
# ARgs (all "options", no positional):
#
# -I Input bundle manifest package directory. Required.
# -n Repo (image) name.  Required.
# -v Version (x.y.z[-suffix]) of bundle image.  Required.
# -r Remote registry server/namespace.  Required.
#
# -t Tag for bundle image. (Default: use bundle version)
# -P Push image (switch)
#
# Environment variables:
#
# DOCKER_USER - If set, the script will do a docker loigin to the remote registry
#               using $DOCKER_USER and $DOCKER_PASS before trying to push the image.
# DOCKER_PASS - See above.
#
# Assumptions:
#
# - We assume this script is located two subdirectories below top of the
#   release repo (as it sppears in Git).
# - /tmp exists and is writeable.
#
# Cautions:
#
# - Tested on RHEL 8, not on other Linux nor Mac
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

opt_flags="I:n:v:r:t:P"

push_the_image=0
image_tag=""

while getopts "$opt_flags" OPTION; do
   case "$OPTION" in
      I) bound_pkg_dir="$OPTARG"
         ;;
      n) bundle_repo="$OPTARG"
         ;;
      v) bundle_vers="$OPTARG"
         ;;
      r) remote_rgy_and_ns="$OPTARG"
         ;;
      t) image_tag="$OPTARG"
         ;;
      P) push_the_image=1
         ;;
      ?) exit 1
         ;;
   esac
done
shift "$(($OPTIND -1))"

if [[ -z "$bound_pkg_dir" ]]; then
   >&2 echo "Error: Input package directory (-I) is required."
   exit 5
fi
if [[ -z "$bundle_repo" ]]; then
   >&2 echo "Error: Image repoositry name (-n) is required."
   exit 5
fi
if [[ -z "$bundle_vers" ]]; then
   >&2 echo "Error: Bundle version (-v) is required."
   exit 5
fi
if [[ -z "$remote_rgy_and_ns" ]]; then
   >&2 echo "Error: Remote registry server and namespace (-r) is required."
   exit 5
fi

bound_bundle_dir="$bound_pkg_dir/$bundle_vers"
if [[ ! -d "$bound_bundle_dir" ]]; then
   >&2 echo "Error: Input bundle manifests directory does not exist: $bound_bundle_dir"
   exit 2
fi

tmp_root="${TMPDIR:-/tmp}"
tmp_dir=$(mktemp -d -p "$tmp_root"  "$me.XXXXXXXX")

build_context="$tmp_dir/bundle-image/build-context"
rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"
mkdir -p "$build_context"

# Use bundle version as tag if tag not explicitly specified
if [[ -z "$image_tag" ]]; then
   image_tag="$bundle_vers"
fi

# We expect the bound bundle package directory we're given to be in a hybrid form: the
# package directory itself should have a package.yaml with the bundle in a version-named
# subdirectory, as expected in App Registry format.  But the contents of the bundle directory
# should have manifests and metadata subdirectories as in bundle-image format.  We use this
# hybrid format in the tooling to make it easy to build bundle images in either format.
#
# Note: The need to  build in either format as mentioned above is now historical as we now
# only produce bundles in bundle-image format, but the hybrid input format currently remains
# in place.

echo "Building the bundle image in Bundle Image format."

# Copy the budnle's metadata and manfests dirs into the docker build context
tar -cf - -C $bound_bundle_dir manifests metadata | (cd $build_context; tar xf -)
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not copy bundle manifests into Docker build context."
   exit 2
fi
# Note: We expect the bound bundle manifest tree to already be in the format
# we need so there is no adjustment of manifests before image building.

# Turn metadata/annotations.yaml into LABEL statemetns for Dockerfile
# - Drop "annotations:" line
# - Convert all others to LABEL statement
tmp_label_lines="$tmp_dir/label-lines"
tail -n +2 "$build_context/metadata/annotations.yaml" | \
   sed "s/: /=/" | sed "s/^ /LABEL/" > "$tmp_label_lines"

cat "$my_dir/Dockerfile.template" | \
   sed "/!!ANNOTATION_LABELS!!/r $tmp_label_lines" | \
   sed "/!!ANNOTATION_LABELS!!/d" > "$build_context/Dockerfile"

bundle_image_rgy_ns_and_repo="$remote_rgy_and_ns/$bundle_repo"
bundle_image_ref="$bundle_image_rgy_ns_and_repo:$image_tag"

# Get rid of previous local image if any
images=$(docker images --format "{{.Repository}}:{{.Tag}}" "$bundle_image_rgy_ns_and_repo")
for img in $images; do
   docker rmi "$img" > /dev/null
done

# Build the image locally

docker build -t "$bundle_image_ref" "$build_context"
# FYI: Buildah equivalent:  buildah bud -t "$image_name_and_tag" "$build_context"
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not build operator budnle image."
   exit 2
fi
echo "Succesfully built image locally: $bundle_image_ref"

rm -rf "$tmp_dir"

# Push the image to remote registry if requested

if [[ $push_the_image -eq 1 ]]; then
   if [[ -n $DOCKER_USER ]]; then
      remote_rgy=${remote_rgy_and_ns%%/*}
      docker login $remote_rgy -u $DOCKER_USER -p $DOCKER_PASS
      if [[ $? -ne 0 ]]; then
         >&2 echo "Error: Could not login to image registry $$remote_rgy."
         exit 2
      fi
   else
      echo "Note: DOCKER_USER not set, assuming image registry login already done."
   fi
   docker push "$bundle_image_ref"
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Failed to push to remote registry."
      exit 2
   fi
   echo "Successfully pushed image: $bundle_image_ref"
else
   echo "Not pushing the image."
fi

