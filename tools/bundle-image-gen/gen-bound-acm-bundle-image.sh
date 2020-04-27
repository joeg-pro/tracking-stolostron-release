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

# Set $docer to "podman" if you have that w/o the podman-docker compat package.
docker="docker"

tmp_dir="/tmp/acm-bundle-build"
build_context="$tmp_dir/build-context"
rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"
mkdir -p "$build_context"

$top_of_repo/tools/bundle-manifests-gen/gen-bound-acm-bundle.sh
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not generate manifests for bound ACM budnle."
   exit 2
fi
# Leaves resulting package here:
bound_pkg_dir="$top_of_repo/operator-bundles/bound/advanced-cluster-management"
bound_bundle_dir="$bound_pkg_dir/1.0.0"

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

# Build the image
$docker build -t "acm-operator-bundle:latest" --file "$tmp_final_dockerfile"
