#!/bin/bash
#
# Determines the current operator image references for external (not
# built by the ACM upstream pipeline) images used by the ACM bundle.
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
tmp_dir="/tmp/acm-operator-image-refs"

# Used by locate_repo_operator and locate_community_operator functions:
clone_repo_spot="$tmp_dir/repo-clones"
community_repo_spot="$clone_repo_spot/community-operators"

new_csv_vers="$1"
if [[ -z "$new_csv_vers" ]]; then
   >&2 echo "Error: CSV version is required."
   exit 1
fi

# Historically, community-operator owners are slow to get release-related channels
# into their packages when we begin work on a new feature release.  In the past we've
# just hacked in a temporary bypass, but this is getting to be a theme so we make
# this a bit fancier.

hive_use_previous_release_channel_override=0
# if [[ "$new_csv_vers" == "99.99.99" ]]; then
#    hive_use_previous_release_channel_override=1
# fi

parse_release_nr "$new_csv_vers"
# Sets rel_x, rel_y, etc.

## Not currently pinned: hive_source_csv_vers="x.y.z"

rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"

log_file="$tmp_dir/logs"

bundle_names=()
declare -A bundle_dirs
declare -A contianer_specs

community_operators_path="redhat-openshift-ecosystem/community-operators-prod.git"
echo "Cloning upstream community-operators repo $community_repo_spot." >> $log_file
git clone "$github/$community_operators_path" "$community_repo_spot" >> $log_file 2>&1
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not clone Community Operators repo."
   >&2 echo "(See $log_file for additional messages from this script run.)"
   >&2 echo "Aborting."
   exit 3
fi

# -- Hive --

locate_community_operator "hive" "hive-operator" "ocm" "$rel_xy" \
   "${hive_source_csv_vers:-none}" "${hive_use_previous_release_channel_override:-0}" >> $log_file 2>&1
if [[ $? -ne 0 ]]; then
   >&2 echo "Error: Could not find source bundle directory for Hive operator."
   >&2 echo "(See $log_file for additional messages from this script run.)"
   >&2 echo "Aborting."
   exit 3
fi
container_specs["Hive"]="hive-operator:hive-operator"


# Lookup and emit all requested image references

for bn in "${bundle_names[@]}"; do
   image=$($my_dir/find-bundle-operator-image.py --container "${container_specs[$bn]}" "${bundle_dirs[$bn]}")
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Could not find operator image(s) for $bn bundle."
      >&2 echo "(See $log_file for additional messages from this script run.)"
      >&2 echo "Aborting."
      exit 3
   fi
   echo "$bn|$image"
done

rm -rf "$tmp_dir"
