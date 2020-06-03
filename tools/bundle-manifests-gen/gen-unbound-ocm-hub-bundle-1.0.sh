#!/bin/bash
#
# Requires:
#
# - readlink
# - Python 3.6 (for underlying scripts)
#
# This script creates an "unbound" operator bundle for the OCM Hub operator based on
# a template and operator-sdk generated artifacts.
#
# By "unbound bundle" (*), we mean one that is structurally complete except that:
#
# - Image references iwthin the CSV have not been updated/bound to specify a specific/pinned
#   operator image (for a snapshot, or an actual release), and
#
# - The bundle/CSV name and the CSV's replaces property have not been set in a way that
#   positions this bundle in replaces-chain sequence of released instances of the operator.
#
# (*) Suggestions for better terminology cheerfully considered.
#
# Pre-reqs:
#
# - operator-sdk (or other means) has generated the operator's owned CRDs, requierd CRDs, roles
#   and deployment manifests and left them in the deploy directory of the Hub operator repo.
#
# Assumptions:
#
# - We assume this directory is located two subdirs below the top of the repo.
#
# Cautions:
#
# - Tested on Linux, not Mac.

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink -f $my_dir/../..)

github="https://$GITHUB_USER:$GITHUB_TOKEN@github.com"
tmp_root="/tmp/ocm-hub-operator-bundle"

hub_pkg_name="multicluster-hub"
hub_channel="latest"

# TODO RELEASE-REWORK:
# Need to move this to a per-release spot:
csv_template=$my_dir/ocm-hub-csv-template.yaml

# The CSV version and previous CSV version are not really important un the unbound bundle
# because they will be set/overridden anyway in the creation of the bound bundle.

new_csv_vers="${1:-1.0.0}"
prev_csv_vers="$2"

old_IFS=$IFS
IFS=. rel_xyz=(${new_csv_vers%-*})
rel_x=${rel_xyz[0]}
rel_y=${rel_xyz[1]}
rel_z=${rel_xyz[2]}
IFS=$old_IFS

feature_release_nr="$rel_x.$rel_y"
if [[ "$feature_release_nr" != "1.0" ]]; then
   hub_release_branch="release-$feature_release_nr"
else
   hub_release_branch="release-1.0.0"
fi


tmp_dir="$tmp_root/bundle-manifests"
rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"

unbound_hub_pkg_dir=$top_of_repo/operator-bundles/unbound/$hub_pkg_name

mkdir -p "$unbound_hub_pkg_dir"

# Wipe out any previous bundle at this version
rm -rf "$unbound_hub_pkg_dir/$new_csv_vers"

clone_spot="$tmp_dir/repo-clones"
hub_repo_spot="$clone_spot/ocm-hub"

echo "Using Hub operator repo branch $hub_release_branch."
git clone -b "$hub_release_branch" "$github/open-cluster-management/multicloudhub-operator.git" $hub_repo_spot
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not clone OCM Hub operator repo."
   >&2 echo "Aborting."
   exit 2
fi

deploy_dir="$hub_repo_spot/deploy"

$my_dir/create-unbound-ocm-hub-bundle.py \
   --deploy-dir $deploy_dir --pkg-dir $unbound_hub_pkg_dir --pkg-name $hub_pkg_name \
   --csv-template $csv_template \
   --csv-vers $new_csv_vers --channel $hub_channel

