#!/bin/bash

# Generates a bundle image (in new bundle-image format by default)
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

# -- Args ---

# -I Input package directory. (required)
# -r Remote registry server/namespace. (required)
# -n image Name (repo).  (required)
# -v Version (x.y.z) of generated bundle image (for tag). (required)
# -s image tag Suffix.  (default: none)
# -P Push image (switch)
# -a generate bundle image in App Registry format (switch)

opt_flags="I:r:n:v:s:Pa"

push_the_image=0
tag_suffix=""
use_bundle_image_format=1

while getopts "$opt_flags" OPTION; do
   case "$OPTION" in
      I) bound_pkg_dir="$OPTARG"
         ;;
      r) remote_rgy_and_ns="$OPTARG"
         ;;
      n) bundle_repo="$OPTARG"
         ;;
      v) bundle_vers="$OPTARG"
         ;;
      s) tag_suffix="$OPTARG"
         ;;
      P) push_the_image=1
         ;;
      a) use_bundle_image_format=0
         ;;
      ?) exit 1
         ;;
   esac
done
shift "$(($OPTIND -1))"

if [[ -z "$bound_pkg_dir" ]]; then
   >&2 echo "Error: Input package directory (-I) is required."
   exit 1
fi
if [[ -z "$remote_rgy_and_ns" ]]; then
   >&2 echo "Error: Remote registry server and namespace (-r) is required."
   exit 1
fi
if [[ -z "$bundle_repo" ]]; then
   >&2 echo "Error: Image repoositry name (-n) is required."
   exit 1
fi
if [[ -z "$bundle_vers" ]]; then
   >&2 echo "Error: Bundle version (-v) is required."
   exit 1
fi

bound_bundle_dir="$bound_pkg_dir/$bundle_vers"


tmp_dir="/tmp/acm-operator-bundle"
build_context="$tmp_dir/bundle-image/build-context"
rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"
mkdir -p "$build_context"

if [[ ! -d "$bound_bundle_dir" ]]; then
   >&2 echo "Error: Input bundle manifests directory does not exist: $bound_bundle_dir"
   exit 2
fi

# Add version suffix if present
if [[ -n "$tag_suffix" ]]; then
   bundle_vers="$bundle_vers-$tag_suffix"
fi

# We expect the bound bundle package directory we're given to be in a hybrid form:
# the package directory itself should have a package.yaml with the bundle in a
# version-named subdirectory, as expected in App Registry format.  But the contents
# of the bundle directory should have manifests and metadata subdirectories as
# in bundle-image format.  We use this hybrid format in the tooling tomake it
# easy to build bundle images in either format.

if [[ $use_bundle_image_format -eq 1 ]]; then

   # Build the operator metadata image in new bundle-image format.

   echo "Building the bundle image in Bundle Image format."

   # Copy the budnle's metadata and manfests dirs into the docker build context
   tar -cf - -C $bound_bundle_dir manifests metadata | (cd $build_context; tar xf -)
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Could not copy bundle manifests into Docker build context."
      exit 2
   fi
   # Note: We expect the bound bundle manifest tree to already be in the format
   # we need so there is no adjustment of manifests before image building,
   # (but there is such adjustment in the App Registry path below).

   # Turn metadata/annotations.yaml into LABEL statemetns for Dockerfile
   # - Drop "annotations:" line
   # - Convert all others to LABEL statement
   tmp_label_lines="$tmp_dir/label-lines"
   tail -n +2 "$build_context/metadata/annotations.yaml" | \
      sed "s/: /=/" | sed "s/^ /LABEL/" > "$tmp_label_lines"

   cat "$my_dir/Dockerfile.template" | \
      sed "/!!ANNOTATION_LABELS!!/r $tmp_label_lines" | \
      sed "/!!ANNOTATION_LABELS!!/d" > "$build_context/Dockerfile"

else

   # Build the operator metadata image in old App Registry format.

   echo "Building the bundle image in App Registry format."

   # Copy the budnle's metadata and manfests dirs into the docker build context
   image_pkg_dir="$build_context/manifests"
   mkdir "$image_pkg_dir"
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Could not create package directory  in Docker build context."
      exit 2
   fi
   tar -cf - -C "$bound_pkg_dir" . | (cd "$image_pkg_dir"; tar xf -)
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Could not copy bundle manifests into Docker build context."
      exit 2
   fi

   # The bound bundle manifest tree we get as input is in bundle-image format,
   # so we have to do a bit of rearrangement to back-port to the older format.

   old_cwd=$PWD
   cum_ec=0
   cd "$image_pkg_dir/$bundle_vers"
   ((cum_ec=cum_ec+$?))
   mv manifests/* .
   ((cum_ec=cum_ec+$?))
   rmdir manifests
   ((cum_ec=cum_ec+$?))
   rm -rf metadata
   ((cum_ec=cum_ec+$?))
   if [[ $cum_ec -ne 0 ]]; then
      >&2 echo "Error: Could not rearrange manifests into App Registry format."
      exit 2
   fi
   cd "$old_cwd"

   # Dockerfile needs no customization -- use as is.
   cat "$my_dir/Dockerfile.appregistry.template" > "$build_context/Dockerfile"

fi

bundle_image_rgy_ns_and_repo="$remote_rgy_and_ns/$bundle_repo"
bundle_image_ref="$bundle_image_rgy_ns_and_repo:$bundle_vers"

# Get rid of previous local image if any
images=$(docker images --format "{{.Repository}}:{{.Tag}}" "$bundle_image_rgy_ns_and_repo")
for img in $images; do
   docker rmi "$img" > /dev/null
done

# Build the image locally
# Note: --squash doesn't work under Travis because appearantly it doesn't have
# experimental docker features enabled.  (Hub?)
docker build -t "$bundle_image_ref" "$build_context"
# FYI: Buildah equivalent:  buildah bud -t "$image_name_and_tag" "$build_context"

if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not build operator budnle image."
   exit 2
fi
echo "Succesfully built image locally: $bundle_image_ref"

# Push the image to remote registry if requested

if [[ $push_the_image -eq 1 ]]; then
   if [[ -n $DOCKER_USER ]]; then
      remote_rgy=${remote_rgy_and_ns%%/*}
      docker login $remote_rgy -u $DOCKER_USER -p $DOCKER_PASS
      if [[ $? -ne 0 ]]; then
         >&2 echo "Error: Error doing docker login to remote registry."
         exit 2
      fi
   else
      echo "Note: DOCKER_USER not set, assuming docker login already done."
   fi
   docker push "$bundle_image_ref"
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Failed to push to remote registry."
      exit 2
   fi
   echo "Successfully pushed image: $bundle_image_ref"
fi

