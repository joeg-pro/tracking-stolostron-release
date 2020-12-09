#!/bin/bash

# Generates bound ACM bundle.
#
# Args:
#
# $1 = Bundle version number in x.y.z[-suffix] form.  Presence of a suffix
#      starting with a dash indicates an RC/SNAPSHOT build.  Required.
#
# $2 = Obsolete and now ignored: Version of the immediately-previous bundle to be
#      replaced by this one via the replaces attribute. or "auto" to determine htis
#      based on semver practices.
#
#      Now: Always treated as if "auto" was specified.
#
# $3 = Explicit default-channel name, overrides any automatic determination or
#      management of same.
#
# Source pkg:  this_repo/operator-bundles/unbound/advanced-cluster-management
# Output pkg:  this_repo/operator-bundles/bound/advanced-cluster-management
#
# Also needs:  The build's image manifest file in this_repo/image-manifests.

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink  -f $my_dir/../..)

pkg_name="advanced-cluster-management"
release_channel_prefix="release"
candidate_channel_prefix="candidate"

bundle_vers="$1"
if [[ -z "$bundle_vers" ]]; then
   >&2 echo "Error: Bundle version (x.y.z[-iter]) is required."
   exit 1
fi
this_rel_nr=${bundle_vers%-*}  # Remove [-iter] if present.

replaces_rel_nr="auto"
# Syntax compatibility, but ignore $2.  Underlying -common script always does "auto".

explicit_default_channel="$3"

old_IFS=$IFS
IFS=. rel_xyz=(${this_rel_nr%-*})
rel_x=${rel_xyz[0]}
rel_y=${rel_xyz[1]}
rel_z=${rel_xyz[2]}
IFS=$old_IFS

rel_yz="$rel_y.$rel_z"


# Define the list of image-key mappings for use in image pinning.

# We add mappings to the list based on the release for which the components were added
# to ACM as compared to the release we're building the bundle for.  Doing it this way
# lets us keep  this script idential across ACM release branches if we want.

image_key_mappings=()

# Since 1.0:

image_key_mappings+=("multiclusterhub-operator:multiclusterhub_operator")
image_key_mappings+=("multicluster-operators-placementrule:multicluster_operators_placementrule")
image_key_mappings+=("multicluster-operators-subscription:multicluster_operators_subscription")
image_key_mappings+=("multicluster-operators-deployable:multicluster_operators_deployable")
image_key_mappings+=("multicluster-operators-channel:multicluster_operators_channel")
image_key_mappings+=("multicluster-operators-application:multicluster_operators_application")
image_key_mappings+=("hive:openshift_hive")

# Since ACM 2.0:
if [[ "$rel_x" -ge 2 ]]; then
   image_key_mappings+=("registration-operator:registration_operator")

   # Since ACM 2.1:
   if [[ "$rel_y" -ge 1 ]]; then
      image_key_mappings+=("multicluster-observability-operator:multicluster_observability_operator")
   fi

   # Since ACM 2.2:
   if [[ "$rel_y" -ge 2 ]]; then
      image_key_mappings+=("submariner-addon:submariner_addon")
  fi

fi

# Pass along an explicit default channel if specified.
if [[ -n "$explicit_default_channel" ]]; then
   dash_lower_d_option="-d $explicit_default_channel"
fi

# Form the list of -i image-key-mapping arguments from the image_key_mappings:
dash_lower_i_opts=()
for m in "${image_key_mappings[@]}"; do
   dash_lower_i_opts+=("-i" "$m")
done

$my_dir/gen-bound-acm-ocm-hub-bundle-common.sh \
   -n "$pkg_name" -v "$bundle_vers" \
   -c $release_channel_prefix -C $candidate_channel_prefix \
   $dash_lower_d_option \
   ${dash_lower_i_opts:+"${dash_lower_i_opts[@]}"}

