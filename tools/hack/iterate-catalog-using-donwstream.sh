#!/bin/bash

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink  -f $my_dir/../..)
tools_dir="$top_of_repo/tools"

# Tack on iteration number

if [[ -f $my_dir/ITERATION ]]; then
   iter=$(cat $my_dir/ITERATION)
else
   iter=0
fi
((iter=iter+1))

bundle_image_ref="quay.io/acm-d/acm-operator-bundle:v1.0.0-5"
catalog_vers="1.0.0-$iter"

$my_dir/build-catalog.sh $bundle_image_ref $catalog_vers \
   "jmg-test-acm-custom-registry" "quay.io/open-cluster-management"

if [[ $? -eq 0 ]]; then
   echo "$iter" > $my_dir/ITERATION
fi

