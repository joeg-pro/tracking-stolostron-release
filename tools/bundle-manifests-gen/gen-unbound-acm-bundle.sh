#!/bin/bash
#
# This script generates the unbound operator bundle (manifests) for the composite ACM
# operator bundle by generating and merging the individual source operator bundle (manifests)
# for the OCM Hub operator, App Subscription operator and Hive.
#
# The resulting operator bundle manifest will then be be input to building and "publishing"
# a bundle image in both upstream and downstream builds.
#
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
tmp_root="/tmp/acm-operator-bundle"
tmp_dir="$tmp_root/bundle-manifests"

pkg_name="advanced-cluster-management"
csv_template="$my_dir/acm-csv-template.yaml"
unbound_pkg_dir="$top_of_repo/operator-bundles/unbound/$pkg_name"

# Used by locate_repo_operator and locate_community_operator functions:
clone_repo_spot="$tmp_dir/repo-clones"
community_repo_spot="$clone_repo_spot/community-operators"

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
# if [[ "$new_csv_vers" == "99.99.99" ]]; then
#    appsub_use_previous_release_channel_override=1
# fi

parse_release_nr "$new_csv_vers"
# Sets rel_x, rel_y, etc.

## Not currently pinned: app_sub_source_csv_vers="x.y.z"
## Not currently pinned: hive_source_csv_vers="x.y.z"
## Not currently pinned: ai_source_csv_vers="x.y.z"

rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"

source_bundles="$tmp_dir/source-bundles"

mkdir -p "$source_bundles"
mkdir -p "$unbound_pkg_dir"

# Wipe out any previous bundle at this version
rm -rf "$unbound_pkg_dir/$new_csv_vers"


# To generate the composite ACM bundle, we need some source bundles as input.
#
# For the OCM hub, we generate the source bundle using the hub operator repo
# and the create-unbound-ocm-hub-bundle script found in this repo.
#
# For the application subscription operator, as well as the other community operators
# we merge into ACM, the source bundle material is obtained from the operator's package
# in the community operators repo.  If we're not pinning the version, we pick up the
# current bundle on a release-tracking channel.  If pinned, we use the pinned version.
#
# FUTURE:  For both app sub and community operators, we probably need a better way to
# synchronize the version of the CSV manifests used with the code we pick up for donwstream
# builds.  Options include: (a) generating the CSVs from tooling and artifacts found in the
# operator repo branches we pick up for downstream, assuming that tooling generates
# "complete" CSVs, or (b) pick up from community operators using an ocm-focused
# channel that is managed to track to the release branch used for builds.

bundle_names=()
declare -A bundle_dirs

community_operators_path="redhat-openshift-ecosystem/community-operators-prod.git"
echo "Cloning upstream community-operators repo $community_repo_spot."
git clone "$github/$community_operators_path" "$community_repo_spot"
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not clone Community Operators repo."
   >&2 echo "Aborting."
   exit 2
fi

# -- OCM Hub --

$my_dir/gen-unbound-ocm-hub-bundle.sh "$new_csv_vers"
if [[ $? -ne 0 ]]; then
   # gen-unbound-ocm-hub-bundle will have reported a summary emsg on errors.
   # so we just report that we're quitting here.
   >&2 echo "Aborting."
   exit 2
fi

hub_pkg_dir="$top_of_repo/operator-bundles/unbound/multicluster-hub"
hub_channel="latest"

# echo Running: my_dir/find-bundle-dir.py $hub_channel $hub_pkg_dir
bundle_dir=$($my_dir/find-bundle-dir.py $hub_channel $hub_pkg_dir)
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not find source bundle directory for OCM Hub."
   >&2 echo "Aborting."
   exit 2
fi
bundle_names+=("OCM Hub")
bundle_dirs["OCM Hub"]="$bundle_dir"

# -- App Sub --

locate_community_operator "App Sub" "multicluster-operators-subscription" "release" "$rel_xy" \
   "${app_sub_source_csv_vers:-none}" "${appsub_use_previous_release_channel_override:-0}"
rc=$?
if [[ $rc -ne 0 ]]; then
   # locate_community_operator has already blurted an error msg.
   exit $rc
fi

# -- Hive --

# ACM 2.0 ships with the Hive 1.0.5 bundle, but in order to get around other issues
# with OLM in OCP 4.8, the Hive team has had to remove the Hive 1.0.5 bundle from
# community operators.  As of this writing, we expect that ACM 2.0 only has a few more
# months of active service.  So, we're special casing the Hive merging for 2.0 and pkcing
# up the bundle the stashed-bundles directory in this repo rather than from the
# community operators repo.

if [[ "$rel_xy" == "2.0" ]]; then
   echo "WARN: Using a stashed copy of the Hive 1.0.5 bundle."
   bundle_names+=("Hive")
   bundle_dirs["Hive"]="$top_of_repo/stashed-bundles/hive-1.0.5"
else
   locate_community_operator "Hive" "hive-operator" "ocm" "$rel_xy" \
      "${hive_source_csv_vers:-none}" "${hive_use_previous_release_channel_override:-0}"
   rc=$?
   if [[ $rc -ne 0 ]]; then
      # locate_community_operator has already blurted an error msg.
      exit $rc
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
   >&2 echo "Error: Generation of unbound ACM bundle encountered errors."
fi
exit $rc

