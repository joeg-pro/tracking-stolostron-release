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

default_bundle_repo="acm-operator-bundle"
default_catalog_repo="acm-custom-registry"

exec $my_dir/gen-ocm-hub-custom-registry.sh \
   -b "$default_bundle_repo" -c "$default_catalog_repo" "$@"

