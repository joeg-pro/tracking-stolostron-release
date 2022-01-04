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
##
# Cautions:
#
# - Tested only on RHEL 8, not on other Linux nor Mac.
#
# Requires:
#
# - readlink
# - Python 3.6 (for underlying scripts that do the real work)

me=$(basename "$0")
my_dir=$(dirname $(readlink -f "$0"))

source $my_dir/bundle-common.bash
# top_of_repo is set as side effect of above source'ing.

github="https://$GITHUB_USER:$GITHUB_TOKEN@github.com"
tmp_root="/tmp/ocm-hub-operator-bundle"
tmp_dir="$tmp_root/bundle-manifests"

pkg_name="multicluster-hub"
csv_template="$my_dir/ocm-hub-csv-template.yaml"
unbound_pkg_dir="$top_of_repo/operator-bundles/unbound/$pkg_name"

# Used by locate_repo_operator and locate_community_operator functions:
clone_repo_spot="$tmp_dir/repo-clones"

# The previous (replaced) CSV version is not really important un the  unbound bundle
# because it will be set/overridden anyway in the creation of the bound bundle.
# But we allow it to be set anyway.
#
# Note that the new_csv_version is used to determine what to put into the bundle.

new_csv_vers="$1"
if [[ -z "$new_csv_vers" ]]; then
   >&2 echo "Error: CSV version is required."
   exit 1
fi

prev_csv_vers="$2"

parse_release_nr "$new_csv_vers"
# Sets rel_x, rel_y, etc.

rel_xy_branch="release-$rel_xy"

# Manage our temp directories

rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"

source_bundles="$tmp_dir/source-bundles"

mkdir -p "$source_bundles"
mkdir -p "$clone_repo_spot"
mkdir -p "$unbound_pkg_dir"

# Wipe out any previous bundle at this version
rm -rf "$unbound_pkg_dir/$new_csv_vers"

bundle_names=()
declare -A bundle_dirs

# Since ACM 1.0:


 # Bundle moved to new standard location in ACM 2.4:
if [[ "$rel_x" -ge 2 ]] && [[ "$rel_y" -ge 4 ]]; then
   hub_bundle_path="bundle/manifests"
else
   hub_bundle_path="deploy/olm-catalog/multiclusterhub-operator/manifests"
fi
locate_repo_operator "Base Hub" "stolostron/multiclusterhub-operator" \
   "$rel_xy_branch" "$hub_bundle_path"

# Since ACM 2.0:

if [[ "$rel_x" -ge 2 ]]; then

   # From ACM 2.0 to 2.4:
   if [[ $using_mce -eq 0 ]]; then
      # Registration operator
      locate_repo_operator "Cluster Manager" "stolostron/registration-operator" \
         "$rel_xy_branch" "deploy/cluster-manager/olm-catalog/cluster-manager/manifests"
   fi

   # Since ACM 2.1:
   if [[ "$rel_y" -ge 1 ]]; then

      # Monitoring operator

      # Bundle moved to new standard location in ACM 2.3 and then to a custom
      # place in ACM 2.4:
      if [[ "$rel_y" -ge 4 ]]; then
         op_bundle_path="operators/multiclusterobservability/bundle/manifests"
      elif [[ "$rel_y" -ge 3 ]]; then
         op_bundle_path="bundle/manifests"
      else
         op_bundle_path="deploy/olm-catalog/multicluster-observability-operator/manifests"
      fi

      locate_repo_operator "Monitoring" "stolostron/multicluster-observability-operator" \
         "$rel_xy_branch" "$op_bundle_path"
   fi

   # Since ACM 2.2:
   if [[ "$rel_y" -ge 2 ]]; then

      # Submariner add-on
      locate_repo_operator "Submariner Addon" "stolostron/submariner-addon" \
         "$rel_xy_branch" "deploy/olm-catalog/manifests"
   fi
fi

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
   if [[ "$rel_y" -ge 4 ]]; then
      supported_archs+=("s390x")
   fi
fi

# Generate the unbound composite bundle, which will be the source for producing
# the bound one (by replacing image references, version, prev-version)

gen_unbound_bundle pkg_name new_csv_vers prev_csv_ver \
  csv_template unbound_pkg_dir bundle_names bundle_dirs \
  supported_archs supported_op_syss
rc="$?"

rm -rf "$tmp_dir"

if [[ $rc -ne 0 ]]; then
   >&2 echo "Error: Generation of unbound OCM bundle encountered errors."
fi
exit $rc

