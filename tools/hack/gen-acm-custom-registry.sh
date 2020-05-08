#!/bin/bash

index_tag="${1:-1.0.0}"
bundle_tag="1.0.0"
bundle_image_name_and_tag="quay.io/open-cluster-management/jmg-test-acm-operator-bundle:$bundle_tag"
index_image_name="quay.io/open-cluster-management/jmg-test-acm-catalog-index"

opm="$HOME/bin/opm"

opm_vers="v1.6.1"

docker login -u=${DOCKER_USER} -p=${DOCKER_PASS} quay.io
docker pull quay.io/operator-framework/upstream-registry-builder:$opm_vers
docker tag quay.io/operator-framework/upstream-registry-builder:$opm_vers quay.io/operator-framework/upstream-registry-builder:latest
docker pull quay.io/operator-framework/operator-registry-server:$opm_vers
docker tag quay.io/operator-framework/operator-registry-server:$opm_vers quay.io/operator-framework/operator-registry-server:latest

index_img_name_and_tag="$index_image_name:$index_tag"

# Clean up any image from previous iteration
old_images=$(docker images --format "{{.Repository}}:{{.Tag}}" "$index_image_name")
for img in $old_images; do
   docker rmi "$img" > /dev/null
done

$opm index add \
   --bundles "$bundle_image_name_and_tag" \
   --tag     "$index_img_name_and_tag" \
   -c docker

docker push "$index_img_name_and_tag"
echo "Pushed index image: $index_img_name_and_tag"

