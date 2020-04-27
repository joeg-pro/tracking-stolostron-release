#!/bin/bash

# Generates bound ACM bundle.

# Source pkg:  this_repo/operator-bundles/unbound/advanced-cluster-management
# Output pkg:  this_repo/operator-bundles/bound/advanced-cluster-management

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))

top_of_repo=$(readlink  -f $my_dir/../..)

pkg_name="advanced-cluster-management"

$my_dir/gen-bound-bundle.sh \
   -v 1.0.0 \
   -m ./1.0.0.json \
   -I $top_of_repo/operator-bundles/unbound/$pkg_name \
   -O $top_of_repo/operator-bundles/bound/$pkg_name \
   -n $pkg_name \
   -d "release-1.0" \
   -c "latest-1.0" \
   -i "multiclusterhub_operator:multiclusterhub-operator" \
   -i "multicluster_operators_placementrule:multicluster-operators-placementrule" \
   -i "multicluster_operators_subscription:multicluster-operators-subscription" \
   -i "multicluster_operators_deployable:multicluster-operators-deployable" \
   -i "multicluster_operators_channel:multicluster-operators-channel" \
   -i "multicluster_operators_application:multicluster-operators-application" \
   -i "hive:hive"

