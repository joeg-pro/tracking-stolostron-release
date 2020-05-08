#!/bin/bash

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink  -f $my_dir/../..)
tools_dir="$top_of_repo/tools"

# Approximates what is done in upstream and committed:

$tools_dir/bundle-manifests-gen/gen-unbound-acm-bundle.sh
if [[ $? -ne 0 ]]; then
   >&2 echo "ABORTING! Could not generate unbound ACM bundle manifests."
   exit 2
fi

# And what is done in downstream build:

$tools_dir/bundle-image-gen/downstream.sh
if [[ $? -ne 0 ]]; then
   >&2 echo "ABORTING! Could not generate ACM bundle image locally."
   exit 2
fi

# And what is done when finally publishing:

if [[ -f $my_dir/ITERATION ]]; then
   iter=$(cat $my_dir/ITERATION)
else
   iter=0
fi
((iter=iter+1))

$my_dir/gen-acm-custom-registry.sh 1.0.0-$iter
if [[ $? -ne 0 ]]; then
   >&2 echo "FAILED! Could not generate ACM index image."
   exit 2
fi
echo "$iter" > $my_dir/ITERATION

