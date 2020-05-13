#!/bin/bash

# INTENDED FOR INFORMAL HACKING ONLY.
#
# This builds an ACM operator bundle using the manfiests and Dockerfile
# commited in the mistream/downstream (?) acm-operator-bundle repo.
#
# Requires RH VPN to be up since this Git server is inside the RH firewall.

release_tag="${1:-1.0.0}"

dist_git_repo="pkgs.devel.redhat.com/containers/acm-operator-bundle"
dist_git_branch="rhacm-1.0-rhel-8"

bundle_image_name="quay.io/open-cluster-management/jmg-test-acm-operator-metadata"

tmp_root="/tmp/acm-operator-bundle"

mkdir -p "$tmp_root"
tmp_dir="$tmp_root/downstream-bundle"
rm -rf "$tmp_dir"
repo_spot="$tmp_dir/repo-from-dist-git"
mkdir -p "$repo_spot"

git clone -b $dist_git_branch git://$dist_git_repo $repo_spot
#TEMP:
repo_spot="/home/jmg/workspaces/git/downstream/acm-operator-bundle"

bundle_image_name_and_tag="$bundle_image_name:$release_tag"

docker login -u=${DOCKER_USER} -p=${DOCKER_PASS} quay.io

# Clean up any image from previous iteration
old_images=$(docker images --format "{{.Repository}}:{{.Tag}}" "$bundle_image_name")
for img in $old_images; do
   docker rmi "$img" > /dev/null
done

cd "$repo_spot"

docker build -t "$bundle_image_name_and_tag" .
docker push "$bundle_image_name_and_tag"





