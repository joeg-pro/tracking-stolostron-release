#!/bin/bash

# requires:
# jq (no reasonably involvd script can live without it).

# Hardcoding:

opm="$HOME/bin/opm"
opm_vers="v1.6.1"

# -- Args --
#
# -B full image ref (rgy/ns/repo[:tag][@diagest]) of input Bundle image (required).
# -r remote Registry server/namespace for generated catalog image. (Default: same as input bundle)
# -n repository Name for generated catalog image (required)
# -v Version (x.y.z) of generated catalog image (for tag).  (default: 1.0.0)
# -s image tag Suffix for generated catalog image.  (default: none)
# -P Push the image (switch)

opt_flags="B:r:n:v:s:P"

push_the_image=0

while getopts "$opt_flags" OPTION; do
   case "$OPTION" in
      B) bundle_image_ref="$OPTARG"
         ;;
      r) catalog_image_rgy_and_ns="$OPTARG"
         ;;
      n) catalog_image_repo="$OPTARG"
         ;;
      v) catalog_image_vers="$OPTARG"
         ;;
      s) vers_suffix="$OPTARG"
         ;;
      P) push_the_image=1
         ;;
      ?) exit 1
         ;;
   esac
done
shift "$(($OPTIND -1))"

if [[ -z "$bundle_image_ref" ]]; then
   >&2 echo "Error: Input bundle image reference (-b) is required."
   exit 1
fi
if [[ -z "$catalog_image_repo" ]]; then
   >&2 echo "Error: Catalog image repository name (-n) is required."
   exit 1
fi

# Parse image ref:
# <rgy>/<ns>/<repo>[:<tag>][@<digest>]

bundle_image_name=${bundle_image_ref%:*}
bundle_image_rgy_and_ns=${bundle_image_ref%/*}
bundle_image_rgy=${bundle_image_ref%%/*}

# By default, put the calog back into the same rregistry/namespace
# as the input bundle, with the same tag.

catalog_image_rgy_and_ns="${catalog_image_rgy_and_ns:-$bundle_image_rgy_and_ns}"
catalog_image_tag="${catalog_image_vers:-1.0.0}"

if [[ -n "$vcers_suffix" ]]; then
   catalog_image_tag="$catalog_image_tag-$vcers_suffix"
fi

catalog_image_name="$catalog_image_rgy_and_ns/$catalog_image_repo"
catalog_image_ref="$catalog_image_name:$catalog_image_tag"
catalog_image_rgy=${catalog_image_ref%%/*}

# Since we currently have only a single DOCKER_USER/PASS value, we're going to require
# that input and output images live in the same registry and that this single docker
# cred has access to both.

if [[ "$bundle_image_rgy" != "$catalog_image_rgy" ]]; then
   >&2 echo "Error: Input bundle image and output catalog image are not in the same image registry."
   exit 1
fi
login_to_image_rgy="$bundle_image_rgy"

# Clean up any image from previous iteration
old_images=$(docker images --format "{{.Repository}}:{{.Tag}}" "$catalog_image_name")
for img in $old_images; do
   docker rmi "$img" > /dev/null
done


if [[ -n $DOCKER_USER ]]; then
   docker login -u=${DOCKER_USER} -p=${DOCKER_PASS} "$login_to_image_rgy"
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Error doing docker login to remote registry."
      exit 2
   fi
else
   echo "Note: DOCKER_USER not set, assuming docker login already done."
fi

# Check the bundle image's com.redhat.delivery.appregistry label.  If present and "true"
# then the bundle is in the legacy App Registry format and we'll handle thusly, else we
# will handle according to the new bundle-image format.

docker pull "$bundle_image_ref"
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not pull input bundle $bundle_image_ref."
   exit 2
fi
inspect_results=$(docker image inspect "$bundle_image_ref")
appregistry_setting=$(echo "$inspect_results" | jq -r '.[0].Config.Labels["com.redhat.delivery.appregistry"]')

if [[ $appregistry_setting == "true" ]]; then
   echo "INFO: Bundle image is in App Registry format."
   handle_as_bundle_image=0
else
   echo "INFO: Bundle image is in Bundle Image format."
   handle_as_bundle_image=1
fi

if [[ $handle_as_bundle_image -eq 1 ]]; then

   # Bundle is in bundle-image format, so we can create a catalog using opm.

   docker pull quay.io/operator-framework/upstream-registry-builder:$opm_vers
   docker tag quay.io/operator-framework/upstream-registry-builder:$opm_vers quay.io/operator-framework/upstream-registry-builder:latest
   docker pull quay.io/operator-framework/operator-registry-server:$opm_vers
   docker tag quay.io/operator-framework/operator-registry-server:$opm_vers quay.io/operator-framework/operator-registry-server:latest

   $opm index add -c docker \
      --bundles "$bundle_image_ref" --tag "$catalog_image_ref"
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Could not build custom catalog image $catalog_image_ref."
      exit 2
   fi

else

   # Bundle is in App Registry/metadata format, so we create a calog by building
   # an image based on the catalog bundler.

   docker build -t "$catalog_image_ref" \
      -f Dockerfile.app-rgy-catalog \
      --build-arg "bundle_image_ref=$bundle_image_ref" .
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Could not build custom catalog image $catalog_image_ref."
      exit 2
   fi

fi

# Maybe a little heavy handed.  Should look for <none>-tagged images only?
docker image prune -f 2> /dev/null
if [[ $? -ne 0 ]]; then
   # If that failed, it could be we're actually running podman with the docker-compatibility
   # wrappers at a version that doesn't like -f or --force at all.  Try again running ppodman
   # directly (or could just do docker image prune w/o the -f)
   podman image prune
fi

if [[ $push_the_image -eq 1 ]]; then
   docker push "$catalog_image_ref"
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Could not push custom catalog image $catalog_image_ref."
      exit 2
   fi
   echo "Pushed custom catalog image: $catalog_image_ref"
fi

