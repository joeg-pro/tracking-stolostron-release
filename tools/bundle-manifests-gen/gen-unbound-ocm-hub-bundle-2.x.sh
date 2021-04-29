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

bundle_names=()
declare -A bundle_dirs

function locate_repo_operator {

   local op_display_name="$1"
   local git_repo="$2"
   local git_branch="$3"
   local bundle_path="$4"

   local clone_spot="$clone_top/${git_repo##*/}"

   echo "Cloning $op_display_name operator repo branch $git_branch."
   git clone -b "$git_branch" "$github/$git_repo" "$clone_spot"
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Could not clone $op_display_name operator repo."
      exit 2
   fi

   bundle_dir="$clone_spot/$bundle_path"
   if [[ ! -d "$bundle_dir" ]]; then
      >&2 echo "Error: Expected $op_display_name bundle manifests directory does not exist."
      exit 2
   fi

   bundle_names+=("$op_display_name")
   bundle_dirs["$op_display_name"]="$bundle_dir"
}


# Clone and verify each of the source-bundles merge together

# Since ACM 1.0:

locate_repo_operator "Base Hub" "open-cluster-management/multicloudhub-operator" \
   "$rel_xy_branch" "deploy/olm-catalog/multiclusterhub-operator/manifests"


# Since ACM 2.0:
if [[ "$rel_x" -ge 2 ]]; then

   # Registration operator
   locate_repo_operator "Cluster Manager" "open-cluster-management/registration-operator" \
      "$rel_xy_branch" "deploy/cluster-manager/olm-catalog/cluster-manager/manifests"

   # Since ACM 2.1:
   if [[ "$rel_y" -ge 1 ]]; then

      # Monitoring operator

      # Bundle moved to new standard location in ACM 2.3:
      if [[ "$rel_y" -ge 3 ]]; then
         op_bundle_path="bundle/manifests"
      else
         op_bundle_path="deploy/olm-catalog/multicluster-observability-operator/manifests"
      fi

      locate_repo_operator "Monitoring" "open-cluster-management/multicluster-monitoring-operator" \
         "$rel_xy_branch" "$op_bundle_path"
   fi

   # Since ACM 2.2:
   if [[ "$rel_y" -ge 2 ]]; then

      # Submariner add-on
      locate_repo_operator "Submariner Addon" "open-cluster-management/submariner-addon" \
         "$rel_xy_branch" "deploy/olm-catalog/manifests"
   fi
fi

if [[ -n "$prev_csv_vers" ]]; then
   prev_option="--prev-csv $prev_csv_vers"
fi

source_bundle_dir_opts=()
for k in "${bundle_names[@]}"; do
   source_bundle_dir_opts+=("--source-bundle-dir" "${bundle_dirs[$k]}")
done

# Starting with ACM 2.3, we support multiple architectures. Specify the list
# of supported architectures to get the CSV labeled right.

supported_archs=()
supported_op_syss=()

if [[ "$rel_x" -ge 2 ]]; then
   if [[ "$rel_y" -ge 3 ]]; then
      supported_op_syss+=("linux")
      supported_archs+=("amd64")
      supported_archs+=("ppc64le")
   fi
fi

supported_thing_opts=()
for e in "${supported_archs[@]}"; do
   supported_thing_opts+=("--supported-arch" "$e")
done
for e in "${supported_op_syss[@]}"; do
   supported_thing_opts+=("--supported-os" "$e")
done


# Produce the merged CSV/bundle

echo ""
echo "----------------------------------------------------------------------------"
echo "Generating unbound bundle manifests for package: $pkg_name"
echo "  From Source OPerator Bundles..."
for k in "${bundle_names[@]}"; do
   echo "     $k in: ${bundle_dirs[$k]}"
done

echo "  Using CSV template: $csv_template"

if [[ -n "$supported_thing_opts" ]]; then
   echo "  With supported architectures: ${supported_archs[@]}"
   echo "     abd supported operating systems: ${supported_op_syss[@]}"
fi

echo "  Writing merged unbound bundle manifests to: $unbound_pkg_dir"
echo "  For CSV/bundle version: $new_csv_vers"

if [[ -n "$prev_csv_vers" ]]; then
   echo "  Replacing previous CSV/bundle version: $prev_csv_vers"
fi
echo "----------------------------------------------------------------------------"
echo ""

$my_dir/merge-bundles.py \
   --pkg-name  $pkg_name --pkg-dir $unbound_pkg_dir \
   --csv-vers "$new_csv_vers" $prev_option \
   --channel "latest" \--csv-template $csv_template \
   "${supported_thing_opts[@]}" \
   "${source_bundle_dir_opts[@]}"

