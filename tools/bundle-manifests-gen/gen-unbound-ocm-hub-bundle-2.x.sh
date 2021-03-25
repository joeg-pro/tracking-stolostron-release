#!/bin/bash
#
# This script generates the unbound operator bundle (manifests) for the OCM Hub,
# based on the release for which we're budiling a bundle:
#
# - For 1.0.z, the OCM Hub bundle was simple (non-composite) and generated
#   by a script here, which we exec out to.
#
# - For 2.0.z and beyond, the OCM Hub bundle is now composite, consisting of the
#   the "Base Hub operator" bundle plus one or more add-in operator bundles,
#   which we merge together via this script.
#
# The resulting operator bundle manifests will then be be input to building and
# publishing a bundle image in both upstream and downstream builds.
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
tmp_root="/tmp/ocm-hub-operator-bundle"

pkg_name="multicluster-hub"
csv_template="$my_dir/ocm-hub-csv-template.yaml"
unbound_pkg_dir="$top_of_repo/operator-bundles/unbound/$pkg_name"

# The previous (replaced) CSV version is not really important un the  unbound bundle
# because it will be set/overridden anyway in the creation of the bound bundle.
# But we allow it to be set anyway.
#
# Note that the new_csv_version is used to determine what to put into the bundle.

new_csv_vers="$1"
prev_csv_vers="$2"

if [[ -z "$new_csv_vers" ]]; then
   >&2 echo "Error: CSV version is required."
   exit 1
fi

oldIFS=$IFS
IFS=. rel_xyz=(${new_csv_vers%-*})
rel_x=${rel_xyz[0]}
rel_y=${rel_xyz[1]}
rel_z=${rel_xyz[2]}
IFS=$oldIFS

rel_xy="$rel_x.$rel_y"

if [[ "$rel_x" -lt 2 ]]; then
   >&2 echo "Info: Redirecting to release 1.0 version of this script."
   exec $my_dir/gen-unbound-ocm-hub-bundle-1.0.sh "$*"
fi

rel_xy_branch="release-$rel_xy"


# Define the list of source repos/CSVs we merge

# We add repos to the list based on the release for which the components were added
# to ACM as compared to the release we're building the bundle for.  Doing it this way
# lets us keep  this script idential across ACM release branches if we want.

source_info=()

# Since ACM 1.0:

op_git_repo="open-cluster-management/multicloudhub-operator"
op_git_branch="$rel_xy_branch"
op_bundle_dir="deploy/olm-catalog/multiclusterhub-operator/manifests"
op_entry="Base Hub:$op_git_repo:$op_git_branch:$op_bundle_dir"
source_info+=("$op_entry")

# Since ACM 2.0:
if [[ "$rel_x" -ge 2 ]]; then

   # Registration operator
   op_git_repo="open-cluster-management/registration-operator"
   op_git_branch="$rel_xy_branch"
   op_bundle_dir="deploy/cluster-manager/olm-catalog/cluster-manager/manifests"
   op_entry="Cluster Manager:$op_git_repo:$op_git_branch:$op_bundle_dir"
   source_info+=("$op_entry")

   # Since ACM 2.1:
   if [[ "$rel_y" -ge 1 ]]; then

      # Monitoring operator
      op_git_repo="open-cluster-management/multicluster-monitoring-operator"
      op_git_branch="$rel_xy_branch"
      # Bundle moved to new standard location in ACM 2.3:
      if [[ "$rel_y" -ge 3 ]]; then
         op_bundle_dir="bundle/manifests"
      else
         op_bundle_dir="deploy/olm-catalog/multicluster-observability-operator/manifests"
      fi
      op_entry="Monitoring:$op_git_repo:$op_git_branch:$op_bundle_dir"
      source_info+=("$op_entry")
   fi

   # Since ACM 2.2:
   if [[ "$rel_y" -ge 2 ]]; then

      # Submariner add-on
      op_git_repo="open-cluster-management/submariner-addon"
      op_git_branch="$rel_xy_branch"
      op_bundle_dir="deploy/olm-catalog/manifests"
      op_entry="Submariner Addon:$op_git_repo:$op_git_branch:$op_bundle_dir"
      source_info+=("$op_entry")
   fi

   # Since ACM 2.3:
   if [[ "$rel_y" -ge 3 ]]; then

      # Discovery operator
      op_git_repo="open-cluster-management/discovery"
      op_git_branch="$rel_xy_branch"
      # This repo is using operator-sdk v1.x, the following is the default place for v1:
      op_bundle_dir="bundle/manifests"
      op_entry="Discovery:$op_git_repo:$op_git_branch:$op_bundle_dir"
      source_info+=("$op_entry")
   fi

fi

# Manage our temp directories

tmp_dir="$tmp_root/bundle-manifests"
rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"

source_bundles="$tmp_dir/source-bundles"
clone_top="$tmp_dir/repo-clones"
mkdir -p "$source_bundles"
mkdir -p "$clone_top"

# Wipe out any previous bundle at this version
mkdir -p "$unbound_pkg_dir"
rm -rf "$unbound_pkg_dir/$new_csv_vers"


# Clone and verify each of the source-bundle entries

sbd_opts=""
sb_msgs=()

for s in "${source_info[@]}"; do
   oldIFS=$IFS
   IFS=: si=($s)
   s_name="${si[0]}"
   s_repo="${si[1]}"
   s_branch="${si[2]}"
   s_dir="${si[3]}"
   IFS=$oldIFS

   clone_spot="$clone_top/${s_repo##*/}"

   echo "Cloning $s_name operator repo branch $s_branch."
   git clone -b "$s_branch" "$github/$s_repo" "$clone_spot"
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Could not clone $s_name operator repo."
      exit 2
   fi

   manifests_dir="$clone_spot/$s_dir"
   if [[ ! -d "$manifests_dir" ]]; then
      >&2 echo "Error: Expected $s_name bundle manifests directory does not exist."
      exit 2
   fi

   sbd_opts="$sbd_opts  --source-bundle-dir $manifests_dir"
   sb_msgs+=("    $s_name in: $manifests_dir")

done

if [[ -n "$prev_csv_vers" ]]; then
   prev_option="--prev-csv $prev_csv_vers"
fi


# Produce the merged CSV/bundle

echo "Generating unbound bundle manifests for package: $pkg_name"
echo "  From Source OPerator Bundles..."
printf "%s\n" "${sb_msgs[@]}"
echo "  Using CSV template: $csv_template"
echo "  Writing merged unbound bundle manifests to: $unbound_pkg_dir"
echo "  For CSV/bundle version: $new_csv_vers"
if [[ -n "$prev_csv_vers" ]]; then
   echo "  Replacing previous CSV/bundle version: $prev_csv_vers"
fi

$my_dir/merge-bundles.py \
   --pkg-name  $pkg_name --pkg-dir $unbound_pkg_dir \
   --csv-vers "$new_csv_vers" $prev_option \
   --channel "latest" \--csv-template $csv_template \
   $sbd_opts

