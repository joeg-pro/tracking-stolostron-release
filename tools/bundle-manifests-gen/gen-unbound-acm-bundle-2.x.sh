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

github="https://$GITHUB_USER:$GITHUB_TOKEN@github.com"
tmp_root="/tmp/acm-operator-bundle"

acm_pkg_name="advanced-cluster-management"

# And the template needs to be per-release too:
csv_template="$my_dir/acm-csv-template.yaml"

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

appsub_use_previous_release_channel_override=0
hive_use_previous_release_channel_override=0
if [[ "$new_csv_vers" == "2.3.0" ]]; then
   appsub_use_previous_release_channel_override=1
   hive_use_previous_release_channel_override=1
fi

oldIFS=$IFS
IFS=. rel_xyz=(${new_csv_vers%-*})
rel_x=${rel_xyz[0]}
rel_y=${rel_xyz[1]}
rel_z=${rel_xyz[2]}
IFS=$oldIFS

rel_xy="$rel_x.$rel_y"

# Works for x.y with y>0:
prev_rel_y=$((rel_y-1))
prev_rel_xy="$rel_x.$prev_rel_y"

## Not currently pinned: app_sub_source_csv_vers="x.y.z"
## Not currently pinned: hive_source_csv_vers="x.y.z"

tmp_dir="$tmp_root/bundle-manifests"
rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"

source_bundles="$tmp_dir/source-bundles"
mkdir -p "$source_bundles"

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
# and the create-unbound-ocm-hub-bundle script found in this repo.
#
# For the application subscription operator, for the moment we grab the source bundle
# from what is posted as a comomunity operator. Because the community operator
# package doesn't have an ocm-tracking channel we pin the version we pick by by
# hardcoding it here.
#
# For Hive, we do the same thing as we do for the application subscription ooperator.
#
# FUTURE:  For both app sub and Hive, we probably need a better way to synchronize the
# version of the CSV manifests used with the code we pick up for donwstream builds.
# Options include: (a) generating the CSVs from tooling and artifacts found in the
# operator repo branches we pick up for downstream, assuming that tooling generates
# "complete" CSVs, or (b) pick up from community operators using an ocm-focused
# channel that is managed to track to the release branch used for builds.

clone_spot="$tmp_dir/repo-clones"

# -- App Sub --

community_repo_spot="$clone_spot/community-operators"
git clone "$github/operator-framework/community-operators.git" "$community_repo_spot"
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not clone Community Operators repo."
   >&2 echo "Aborting."
   exit 2
fi

if [[ -z "$app_sub_source_csv_vers" ]]; then

   # Find latest version posted on a channel:

   app_sub_pkg_dir="$community_repo_spot/community-operators/multicluster-operators-subscription"
   app_sub_channel="release-$rel_xy"
   if [[ $appsub_use_previous_release_channel_override -eq 1 ]]; then
      echo "Warning: Previous-release-channel override is in effect for App Sub operator."
      app_sub_channel="release-$prev_rel_xy"
   fi

   app_sub_bundle_dir=$($my_dir/find-bundle-dir.py $app_sub_channel $app_sub_pkg_dir)
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Could not find source bundle directory for Multicluster Subscription."
      >&2 echo "Aborting."
      exit 2
   fi
   app_sub_bundle_version=${app_sub_bundle_dir##*/}
   echo "Info: Using most recent App Sub bundle posted to channel: $app_sub_channel ($app_sub_bundle_version)."

else
   # PIN TO  VERSION:
   echo "Info: Using pinned App Sub bundle version: $app_sub_source_csv_vers."
   app_sub_bundle_dir="$community_repo_spot/community-operators/multicluster-operators-subscription/$app_sub_source_csv_vers"
fi

# -- Hive --

if [[ -z "$hive_source_csv_vers" ]]; then
   # Find latest version posted on a channel:

   hive_pkg_dir="$community_repo_spot/community-operators/hive-operator"
   hive_channel="ocm-$rel_xy"
   if [[ $hive_use_previous_release_channel_override -eq 1 ]]; then
      echo "Warning: Previous-release-channel override is in effect for Hive operator."
      hive_channel="ocm-$prev_rel_xy"
   fi

   hive_bundle_dir=$($my_dir/find-bundle-dir.py $hive_channel $hive_pkg_dir)
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Could not find source bundle directory for Hive."
      >&2 echo "Aborting."
      exit 2
   fi
   hive_bundle_version=${hive_bundle_dir##*/}
   echo "Info: Using most recent Hive bundle posted to channel: $hive_channel ($hive_bundle_version)."

else
   # PIN TO VERSION:
   echo "Info: Using pinned Hive bundle version: $hive_source_csv_vers."
   hive_bundle_dir="$community_repo_spot/community-operators/hive-operator/$hive_source_csv_vers"
fi

# -- OCM Hub --

$my_dir/gen-unbound-ocm-hub-bundle.sh "$new_csv_vers"
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not generate OCM Hub source bundle."
   >&2 echo "Aborting."
   exit 2
fi

hub_pkg_dir="$top_of_repo/operator-bundles/unbound/multicluster-hub"
hub_channel="latest"

hub_bundle_dir=$($my_dir/find-bundle-dir.py $hub_channel $hub_pkg_dir)
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not find source bundle directory for OCM Hub."
   >&2 echo "Aborting."
   exit 2
fi

# Generate the unbound composite bundle, which will be the source for producing
# the bound one (by replacing image references, version, prev-version)

if [[ -n "$prev_csv_vers" ]]; then
   prev_option="--prev-csv $prev_csv_vers"
fi

echo "Generating unbound bundle manifests for package: $acm_pkg_name"
echo "  From OCM hub bundle in:   $hub_bundle_dir"
echo "     and Hive bundle in:    $hive_bundle_dir"
echo "     and App Sub bundle in: $app_sub_bundle_dir"
echo "  Writing merged unbound bundle manifests to: $unbound_acm_pkg_dir"
echo "  For CSV/bundle version: $new_csv_vers"
if [[ -n "$prev_csv_vers" ]]; then
   echo "  Replacing previous CSV/bundle version: $prev_csv_vers"
fi

$my_dir/merge-bundles.py \
   --pkg-name  $acm_pkg_name --pkg-dir $unbound_acm_pkg_dir \
   --csv-vers "$new_csv_vers" $prev_option \
   --channel "latest" \
   --csv-template $csv_template \
   --source-bundle-dir $hub_bundle_dir \
   --source-bundle-dir $hive_bundle_dir \
   --source-bundle-dir $app_sub_bundle_dir

