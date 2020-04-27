#!/bin/bash

# Generates bound ACM bundle image.

# Source pkg:  this_repo/operator-bundles/unbound/advanced-cluster-management
# Output pkg:  this_repo/operator-bundles/bound/advanced-cluster-management
#
# Assumptions:
# - We assume this script is located two subdirectories below top of repo.
#
# Cautions:
# - Tested on RHEL 8, not on other Linux nor Mac
# - This script uses sed, so Mac-compatbility problems may exist.

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))

top_of_repo=$(readlink  -f $my_dir/../..)

# Set $docer to "podman" if you have that w/o the podman-docker compat package.
docker="docker"

tmp_dir="./build-temp"
build_context="$tmp_dir/build-context"
rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"
mkdir -p "$build_context"

$top_of_repo/tools/bundle-manifests-gen/gen-bound-acm-bundle.sh
# Leaves resulting package here:
bound_pkg_dir="$top_of_repo/operator-bundles/bound/advanced-cluster-management"
bound_bundle_dir="$bound_pkg_dir/1.0.0"

# Turn annotations.yaml into LABEL statemetns for Dockerfile
# - -Drop "annotations:" line
# - Convert all others to LABEL statement
tmp_label_lines="$tmp_dir/label-lines"
tail -n +2 "$bound_bundle_dir/metadata/annotations.yaml" | \
   sed "s/: /=/" | sed "s/^ /LABEL/" > "$tmp_label_lines"

tmp_final_dockerfile="$build_context/Dockerfile"
cat "$my_dir/Dockerfile.bundle" | \
   sed "/!LABELS!/r $tmp_label_lines" | \
   sed "/!LABELS!/d" > "$tmp_final_dockerfile"

# Copy bundle dirs into the docker build context
tar -cf - -C $bound_bundle_dir manifests metadata | (cd $build_context; tar xf -)

# Build the image
$docker build -t "acm-operator-bundle:latest" --file "$tmp_final_dockerfile"
