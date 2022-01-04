#!/bin/bash

# This script executes the steps performed (entirely) upstream to
# produce an upstream/"community"-packaged operator bundle for ACM.
#
# Args:
#
# $1 Bundle version for this bundle (Format: x.y.z[-iter]).  (Required)
#
# -r remote Registry server/namespace. (Default: quay.io/stolostron)
# -b Budnle repository name (default: acm-operator-bundle)
# -c Custom catalog repository Name (Default: acm-custom-registry)
# -t image Tag for bundle/catalog (Default: use bundle version)
# -P Push the bundle image and catalogs to remote registry after producing it (switch)
#
# -J Prefix for repo names (for testing).  (Default: none)
#
# For use by scripts covering wrapping this one:
#
# -w Qualifier appended to names of lower-level scripts we invoke.
# -W "what kind" string for messages.
#
# Assumptions:
# - We assume this script lives two directory levles below the top of the repo.

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))

default_bundle_repo="acm-operator-bundle"
default_catalog_repo="acm-custom-registry"

exec $my_dir/build-ocm-hub-bundle-image-and-catalog.sh \
   -b $default_bundle_repo -c $default_catalog_repo \
   -w acm -W "ACM" "$@"

