#!/bin/bash

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink  -f $my_dir/../..)
tools_dir="$top_of_repo/tools"

bundle_vers="2.0.0"
# bundle_vers="1.0.0"

build_using_downstream=0
use_bundle_image_format=1

# Tack on iteration number

if [[ -f $my_dir/ITERATION ]]; then
   iter=$(cat $my_dir/ITERATION)
else
   iter=0
fi
((iter=iter+1))

bundle_vers_with_iter="$bundle_vers-$iter"

bv_arg=$bundle_vers
dash_t_opt="-t $bundle_vers_with_iter"

$tools_dir/build/build-ocm-hub-bundle-image-and-catalog.sh -P -r quay.io/joeg-pro $dash_t_opt $bv_arg
$tools_dir/build/build-acm-bundle-image-and-catalog.sh -P -r quay.io/joeg-pro $dash_t_opt $bv_arg
if [[ $? -eq 0 ]]; then
   echo "$iter" > $my_dir/ITERATION
fi

