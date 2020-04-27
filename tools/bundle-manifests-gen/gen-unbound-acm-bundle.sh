#!/bin/bash
#
# This script generates the unbound operator bundle (manifests) for the composite ACM
# operator bundle by generating and merging the individual source operator bundle (manifests)
# for the OCM Hub operator, App Subscription operator and Hive.
#
# The resulting operator bundle manifest will then be be input to building and "publishing"
# a bundle image in both upstream and downstream builds.
#
# Assumptions:
#
# - We assume this script is located two directorries below top of this repo.
#
# Cautions:
#
# - Tested only on RHEL 8, not on other Linux nor Mac.
#
# Requires:
#
# - readlink
# - Python 3.6 (for underlying scripts that do the real work)

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))

top_of_repo=$(readlink  -f $my_dir/../..)

github="git@${GITHUB:-github.com}"
tmp_root="/tmp/acm-bundle-manifests-build"

# The CSV version and previous CSV version are not really important un the unbound bundle
# because they will be set/overridden anyway in the creation of the bound bundle.

new_csv_vers="1.0.0"
prev_csv_vers=""

mkdir -p "$tmp_root"
tmp_dir="$tmp_root/work"
rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"

source_bundles="$tmp_dir/source-bundles"
mkdir -p "$source_bundles"

acm_pkg_name="advanced-cluster-management"
unbound_acm_pkg_dir="$top_of_repo/operator-bundles/unbound/$acm_pkg_name"

mkdir -p "$unbound_acm_pkg_dir"

# Wipe out any previous bundle at this version
rm -rf "$unbound_acm_pkg_dir/$new_csv_vers"


# To generate the composite ACM bundle, we need some source bundles as input.
#
# For Hive, we generate the source bundle using the Hive operator repo and
# a generation script found there.
#
# For the OCM hub, we generate the source bundle using the hub operator repo
# and the create-unbound-ocm-hub-bundle script found here.
#
# For the application subscription operator, for the moment we grab the source bundle
# from what is posted as a comomunity operato.  But in order to syncronize the
# bundle with the code snapshot being used for downstream build, we should change this
# to either (a) generate usng a repo-provided script, or (b) pick up an already
# generated bundle from within the repo.

clone_spot="$tmp_dir/repo-clones"

# -- App Sub --

community_repo_spot="$clone_spot/community-operators"
git clone "$github:operator-framework/community-operators.git" "$community_repo_spot"
app_sub_pkg="$community_repo_spot/community-operators/multicluster-operators-subscription"
app_sub_channel="alpha"

app_sub_bundle=$($my_dir/find-bundle-dir.py $app_sub_channel $app_sub_pkg)
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not find source bundle directory for Multicluster Subscription."
   >&2 echo "Aborting."
   exit 2
fi
app_sub_bundle_spot="$source_bundles/app-sub"
ln -s "$app_sub_bundle" $app_sub_bundle_spot

# -- Hive --

hive_repo_spot="$clone_spot/hive"
hive_stable_release_branch="ocm-4.4.0"
git clone -b "$hive_stable_release_branch" "$github:openshift/hive.git" $hive_repo_spot

hive_bundle_work=$tmp_dir/hive-bundle
mkdir -p "$hive_bundle_work"

echo "Generating Hive source bundle."

# Seems the generation script assumes CWD is top of repo.

save_cwd=$PWD
cd $hive_repo_spot
hive_image_placeholder="quay.io/openshift-hive/hive:dont-care"
python2.7 ./hack/generate-operator-bundle.py $hive_bundle_work dont-care 0 "-none" "$hive_image_placeholder"
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not generate Hive source bundle."
   >&2 echo "Aborting."
   exit 2
fi
cd $save_cwd

hive_bundle_spot="$source_bundles/hive"
ln -s "$hive_bundle_work/0.1.0-sha-none" $hive_bundle_spot

# -- OCM Hub --

hub_repo_spot="$clone_spot/ocm-hub"

# TEMP
hub_stable_release_branch="master"
git clone -b "$hub_stable_release_branch" "$github:open-cluster-management/multicloudhub-operator.git" $hub_repo_spot
"$hub_repo_spot/build-scripts/bundle-gen/gen-unbound-ocm-hub-bundle.sh" x.y.z
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not generate source bundle for OCM Hub."
   >&2 echo "Aborting."
   exit 2
fi

hub_pkg="$hub_repo_spot/operator-bundles/unbound/open-cluster-management-hub"
hub_channel="latest"
hub_bundle=$($my_dir/find-bundle-dir.py $hub_channel $hub_pkg)
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not find source bundle directory for OCM Hub."
   >&2 echo "Aborting."
   exit 2
fi

hub_bundle_spot="$source_bundles/ocm-hub"
ln -s "$hub_bundle" "$hub_bundle_spot"

# Generate the unbound composite bundle, which will be the source for producing
# the bound one (by replacing image references, version, prev-version)

if [[ -n "$prev_csv_vers" ]]; then
   prev_option="--prev-csv $prev_csv_vers"
fi

$my_dir/create-unbound-acm-bundle.py \
   --pkg-name  $acm_pkg_name --pkg-dir $unbound_acm_pkg_dir \
   --csv-vers "$new_csv_vers" $prev_option \
   --channel "latest" \
   --csv-template $my_dir/acm-csv-template.yaml \
   --source-bundle-dir $hub_bundle_spot \
   --source-bundle-dir $hive_bundle_spot \
   --source-bundle-dir $app_sub_bundle_spot

