#!/bin/bash
#
# This script generates the unbound operator bundle (manifests) for the productized
# Cluster Management Backplane operator bundle by generating and merging the individual
# source operator bundles (manifests) that contribute to the final bundle.
#
# The resulting operator bundle manifests will then be be input to building and
# publishing a bundle image in both upstream and downstream builds.
#
# Cautions:
#
# - Tested only on RHEL 8, not on other Linux nor Mac.
#
# Requires:
#
# - Base 4.3+ (due to use of "local -n" in common functions)
# - readlink
# - Python 3.6 (for underlying scripts that do the real work)

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))

source $my_dir/bundle-common.bash
# top_of_repo is set as side effect of above source'ing.

github="https://$GITHUB_USER:$GITHUB_TOKEN@github.com"
tmp_root="/tmp/cmb-operator-bundle"

pkg_name="cluster-management-backplane"
csv_template="$my_dir/cmb-csv-template.yaml"

# The CSV version and previous CSV version are not really important un the unbound bundle
# because they will be set/overridden anyway in the creation of the bound bundle.

new_csv_vers="$1"
if [[ -z "$new_csv_vers" ]]; then
   >&2 echo "Error: CSV version is required."
   exit 1
fi
prev_csv_vers="$2"

# Historically, community-operator owners are slow to get release-related channels
# into their packages when we begin work on a new feature release.  In the past we've
# just hacked in a temporary bypass, but this is getting to be a theme so we make
# this a bit fancier.

hive_use_previous_release_channel_override=0
# No override currently:
if [[ "$new_csv_vers" == "99.99.99" ]]; then
   hive_use_previous_release_channel_override=1
fi

## Not currently pinned: hive_source_csv_vers="x.y.z"

parse_release_nr "$new_csv_vers"
# Sets rel_x, rel_y, etc.

rel_xy_branch="release-$rel_xy"

tmp_dir="$tmp_root/bundle-manifests"
rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"

source_bundles="$tmp_dir/source-bundles"
mkdir -p "$source_bundles"

unbound_pkg_dir="$top_of_repo/operator-bundles/unbound/$pkg_name"

mkdir -p "$unbound_pkg_dir"

# Wipe out any previous bundle at this version
rm -rf "$unbound_pkg_dir/$new_csv_vers"

# Used by locate_repo_operator and locate_community_operator functions:
clone_repo_spot="$tmp_dir/repo-clones"
community_repo_spot="$clone_repo_spot/community-operators"

bundle_names=()
declare -A bundle_dirs

# -- CMB Installer --

cmb_operator_branch="$rel_xy_branch"
# TEMP SCAFFOLDING
cmb_operator_branch="main"
# END TEMP SCAFFOLDING

# TEMP
# Omit for iteration 0.
# locate_repo_operator "Backplane Installer" "open-cluster-management/backplane-operator" \
#    "$cmb_operator_branch" "bundle/manifests"

# -- Registration operator --

reg_operator_branch="$rel_xy_branch"
# TEMP SCAFFOLDING
reg_operator_branch="release-2.4"
# END TEMP SCAFFOLDING


# TEMP
# Omit for iteration 0.
# locate_repo_operator "Cluster Manager" "open-cluster-management/registration-operator" \
#    "$reg_operator_branch" "deploy/cluster-manager/olm-catalog/cluster-manager/manifests"

# -- Hive --

community_operators_path="redhat-openshift-ecosystem/community-operators-prod.git"
echo "Cloning upstream community-operators repo $community_repo_spot."
git clone "$github/$community_operators_path" "$community_repo_spot"
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not clone Community Operators repo."
   >&2 echo "Aborting."
   exit 2
fi

# TEMP SCAFFOLDING
# Need to ask Hive team for a backplane-related release branch.
hive_branch_prefix="ocm"
hive_rel_xy="2.4"
# END TEMP
locate_community_operator "Hive" "hive-operator" "$hive_branch_prefix" "$hive_rel_xy" \
   "${hive_source_csv_vers:-none}" "${hive_use_previous_release_channel_override:-0}"

# -- Done finding source bundles --


# We currently support only a  single architecture, but structure this to
# make it easier to add additional architectures in the future.

supported_archs=()
supported_op_syss=()

supported_op_syss+=("linux")
supported_archs+=("amd64")

# Generate the unbound composite bundle, which will be the source for producing
# the bound one (by replacing image references, version, prev-version)

gen_unbound_bundle pkg_name new_csv_vers prev_csv_ver \
  csv_template unbound_pkg_dir bundle_names bundle_dirs \
  supported_archs supported_op_syss

