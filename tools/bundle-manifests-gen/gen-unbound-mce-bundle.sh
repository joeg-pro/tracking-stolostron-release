#!/bin/bash
#
# This script generates the unbound operator bundle (manifests) for the productized
# Multicluster Engine operator bundle by generating and merging the individual
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
tmp_root="/tmp/mce-operator-bundle"

pkg_name="multicluster-engine"
csv_template="$my_dir/mce-csv-template.yaml"

# The CSV version and previous CSV version are not really important un the unbound bundle
# because they will be set/overridden anyway in the creation of the bound bundle.

new_csv_vers="$1"
if [[ -z "$new_csv_vers" ]]; then
   >&2 echo "Error: CSV version is required."
   exit 1
fi
prev_csv_vers="$2"

parse_release_nr "$new_csv_vers"
# Sets rel_x, rel_y, etc.

rel_xy_branch="backplane-$rel_xy"

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

locate_repo_operator "Backplane Installer" "stolostron/backplane-operator" \
   "$cmb_operator_branch" "bundle/manifests"

# -- Done finding source bundles --


# We currently support only a  single architecture, but structure this to
# make it easier to add additional architectures in the future.

supported_archs=()
supported_op_syss=()

supported_op_syss+=("linux")
supported_archs+=("amd64")

if [[ "$rel_x" -ge 1 ]]; then
   if [[ "$rel_y" -ge 1 ]]; then
      supported_archs+=("ppc64le")
      supported_archs+=("s390x")
   fi
fi
if [[ "$rel_x" -ge 2 ]]; then
   supported_archs+=("ppc64le")
   supported_archs+=("s390x")
   supported_archs+=("arm64")
fi

# Generate the unbound composite bundle, which will be the source for producing
# the bound one (by replacing image references, version, prev-version)

gen_unbound_bundle pkg_name new_csv_vers prev_csv_ver \
  csv_template unbound_pkg_dir bundle_names bundle_dirs \
  supported_archs supported_op_syss
rc="$?"

rm -rf "$tmp_dir"

if [[ $rc -ne 0 ]]; then
   >&2 echo "Error: Generation of unbound MCE bundle encountered errors."
fi
exit $rc

