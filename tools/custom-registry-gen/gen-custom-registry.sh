#!/bin/bash
#
# Builds an OLM registry from operator metadata in either bundle image
# or App Registry format.
#
# requires:
# jq (no reasonably involvd script can live without it).

opm_vers="v1.17.5"

operator_rgy_repo_url="https://github.com/operator-framework/operator-registry"
opm_download_url="$operator_rgy_repo_url/releases/download/$opm_vers/linux-amd64-opm"

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))

# -- Args --
#
# -B full image ref (rgy/ns/repo[:tag][@diagest]) of input Bundle image (required, repeated).
# -r remote Registry server/namespace for generated catalog image. (Default: same as input bundle)
# -n repository Name for generated catalog image (required)
# -t image Tag for generated catalog image.  (required)
# -P Push the image (switch)

opt_flags="B:r:n:t:P"

push_the_image=0
catalog_image_tag=""

bundle_image_refs=()

while getopts "$opt_flags" OPTION; do
   case "$OPTION" in
      B) bundle_image_refs+=("$OPTARG")
         ;;
      r) catalog_image_rgy_and_ns="$OPTARG"
         ;;
      n) catalog_image_repo="$OPTARG"
         ;;
      t) catalog_image_tag="$OPTARG"
         ;;
      P) push_the_image=1
         ;;
      ?) exit 1
         ;;
   esac
done
shift "$(($OPTIND -1))"

if [[ ${#bundle_image_refs[@]} -eq 0  ]]; then
   >&2 echo "Error: At least one bundle image reference (-B) is required."
   exit 1
fi
if [[ -z "$catalog_image_repo" ]]; then
   >&2 echo "Error: Catalog image repository name (-n) is required."
   exit 1
fi
if [[ -z "$catalog_image_tag" ]]; then
   >&2 echo "Error: Catalog image tag (-t) is required."
   exit 1
fi

bundle_image_ref="${bundle_image_refs[0]}"

# Parse image ref:
# <rgy>/<ns>/<repo>[:<tag>][@<digest>]

bundle_image_name=${bundle_image_ref%:*}
bundle_image_rgy_and_ns=${bundle_image_ref%/*}
bundle_image_rgy=${bundle_image_ref%%/*}

# By default, put the registry back into the same rregistry/namespace
# as the input bundle, with the same tag.

catalog_image_rgy_and_ns="${catalog_image_rgy_and_ns:-$bundle_image_rgy_and_ns}"

catalog_image_name="$catalog_image_rgy_and_ns/$catalog_image_repo"
catalog_image_ref="$catalog_image_name:$catalog_image_tag"
catalog_image_rgy=${catalog_image_ref%%/*}

# Since we currently have only a single DOCKER_USER/PASS pair, we're going to assume
# they are for the registry we push to.  If the source bundles are coming from a
# different registry then we will leave it up to the invoker to do logins to
# those registries before inovking this script.

login_to_image_rgy="$catalog_image_rgy"

# Clean up any image from previous iteration
old_images=$(docker images --format "{{.Repository}}:{{.Tag}}" "$catalog_image_name")
for img in $old_images; do
   docker rmi "$img" > /dev/null
done

if [[ -n $DOCKER_USER ]]; then
   docker login -u=${DOCKER_USER} -p=${DOCKER_PASS} "$login_to_image_rgy"
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Coud not login to image registry $login_to_image_rgy."
      exit 2
   fi
else
   echo "Note: DOCKER_USER not set, assuming login to image registry already done."
fi

tmp_root="${TMPDIR:-/tmp}"
tmp_dir=$(mktemp -d -p "$tmp_root"  "$me.XXXXXXXX")

rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"
build_context="$tmp_dir"

# As of v1.13.3, "opm index add" countues to be a pain in that it pulls its upstream
# images based on a floating tag (latest), and worse yet produces an image which
# does not run on OCP (Permission denied on /etc/nsswitch.conf).  To circumvent
# we use "opm registry add" ourselves to build the database (this is what the
# "opm index add" command does under the covers, and then generate the image
# oursleves using a patched Dockerfile captured from "opm index add ... --generate".

old_cwd=$PWD
cd $build_context

# Fetch the desired version of OPM

opm="./opm"
http_status=$(curl -Ls -o "$opm" --write-out "%{http_code}" "$opm_download_url")
if [[ $http_status -ne 200 ]]; then
   >&2 echo "Error: Could not fetch OPM binary from $opm_download_url (HTTP Status Code: $http_status)"
   exit 2
fi
chmod +x "$opm"

# Build registry database
#
# Note:  If your workstation is running podman with the podman-docker compat layer
# rather than genuine docker and you run into 401 Unauthroized errors on opm add,
# you might need this env var in effect:
#
# export REGISTRY_AUTH_FILE=$HOME/.docker/config.json

mkdir "database"

for bundle_image_ref in "${bundle_image_refs[@]}"; do
   echo "Adding bundle: $bundle_image_ref"
   $opm registry add -b "$bundle_image_ref" -d "database/index.db"
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Could not add bundle to registry database: $bundle_image_ref."
      exit 2
   fi
done

cp "$my_dir/Dockerfile.index" .
mkdir "etc"
touch "etc/nsswitch.conf"
chmod a+r "etc/nsswitch.conf"

docker build -t "$catalog_image_ref" -f Dockerfile.index \
   --build-arg "opm_vers=$opm_vers" .
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not build custom catalog image $catalog_image_ref."
   exit 2
fi
cd $old_cwd

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

