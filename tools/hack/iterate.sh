#!/bin/bash

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink  -f $my_dir/../..)
tools_dir="$top_of_repo/tools"

bundle_vers="1.0.0"
build_using_downstream=1

# Tack on iteration number

if [[ -f $my_dir/ITERATION ]]; then
   iter=$(cat $my_dir/ITERATION)
else
   iter=0
fi
((iter=iter+1))

bundle_vers="$bundle_vers-$iter"

if [[ $build_using_downstream -eq 1 ]]; then

   # Use the downstream's dist-git acm-operator-bundle repo to build an image
   # locally using that Dockerfile/operator bundle manifests.
   #
   # Note: This is done to permit local testing in liew of having a mirror of a
   # downstream-built bundle image.  If you have a mirror of a downstream bundle
   # image, just hand it to gen-acm-custom-registry.sh.

   $my_dir/gen-bundle-image-using-downstream.sh "$bundle_vers"
   bundle_image_ref="quay.io/open-cluster-management/jmg-test-acm-operator-metadata:$bundle_vers"
else

   # Approximates what is done in upstream and committed:
   $tools_dir/bundle-manifests-gen/gen-unbound-acm-bundle.sh
   if [[ $? -ne 0 ]]; then
      >&2 echo "ABORTING! Could not generate unbound ACM bundle manifests."
      exit 2
   fi

   # And what is done in downstream build:
   $tools_dir/bundle-image-gen/downstream.sh \
      -r quay.io/open-cluster-management -n jmg-test-acm-operator-bundle \
      -v "$bundle_vers"
   if [[ $? -ne 0 ]]; then
      >&2 echo "ABORTING! Could not generate ACM bundle image locally."
      exit 2
   fi
   bundle_image_ref="quay.io/open-cluster-management/jmg-test-acm-operator-bundle:$bundle_vers"
fi

# And what is done when finally publishing:
$my_dir/gen-acm-custom-registry.sh -P \
   -b "$bundle_image_ref" \
   -n jmg-test-acm-custom-registry \
   -v "$bundle_vers"
if [[ $? -ne 0 ]]; then
   >&2 echo "FAILED! Could not generate ACM custom catalog image."
   exit 2
fi
echo "$iter" > $my_dir/ITERATION

