#!/bin/bash

# Generates bound ACM bundle.
#
# Args:
#
# $1 = Bundle version number in x.y.z[-suffix] form.  Presence of a suffix
#      starting with a dash indicates an RC/SNAPSHOT build.  Required.
#
# $2 = Method for handling generation of replacement-graph properties.  If specified as
#      the value "none" then no upgrade-graph properties are put into the CSV/bundle
#      (to support upstream builds which don't yet build a  multi-bundle catalog).
#      If specified as "auto" or omitted or null, replacment-graph properties are
#      automatically computed and placed in the CSV.
#
#      Historically, this position parameter used to speciy the previon-release
#      version number for use in forming the replacement-graph properties.
#
# $3 = Explicit default-channel name, overrides any automatic determination or
#      management of same.
#
# Source pkg:  this_repo/operator-bundles/unbound/advanced-cluster-management
# Output pkg:  this_repo/operator-bundles/bound/advanced-cluster-management
#
# Also needs:  The build's image manifest file in this_repo/image-manifests.
#
# Note: Requires Bash 4.4 or newer.

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

# Note: The handling of $2 has evolved a lot, from originally being the number
# of the immediately predecessor release, to being fully ignored, to now being
# a way to suppress insertion of replacement-graph properties.

if [[ "$2" == "none" ]]; then
   suppress_repl_graph_stuff=1
else
   suppress_repl_graph_stuff=0
fi

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

# Since ACM 2.x:
if [[ "$rel_x" -ge 2 ]]; then

   # Since ACM 2.0:
   image_key_mappings+=("registration-operator:registration_operator")

   # Since ACM 2.1:
   if [[ "$rel_y" -ge 1 ]]; then
      image_key_mappings+=("multicluster-observability-operator:multicluster_observability_operator")
   fi

   # Since ACM 2.2:
   if [[ "$rel_y" -ge 2 ]]; then
      image_key_mappings+=("submariner-addon:submariner_addon")
  fi

   # Since ACM 2.3:
   if [[ "$rel_y" -ge 3 ]]; then
      image_key_mappings+=("discovery-operator:discovery_operator")
  fi
fi

# Define the list of CSV deployment containers that are to have image-ref
# environment variables injected for the bundle's related images.

image_ref_containers=()

# Since ACM 2.x:
if [[ "$rel_x" -ge 2 ]]; then

   # Since ACM 2.3:
   if [[ "$rel_y" -ge 3 ]]; then
      image_ref_containers+=("multiclusterhub-operator/multiclusterhub-operator")
  fi
fi

# Squash all replacement graph stuff if requested.
if [[ $suppress_repl_graph_stuff -eq 1 ]]; then
   suppress_repl_graph_option="-U"
fi

# Pass along an explicit default channel if specified.
if [[ -n "$explicit_default_channel" ]]; then
   dash_lower_d_opt=("-d" "$explicit_default_channel")
fi

# Convert list of image-key-mappings to corresponding list of -i arguments:
dash_lower_i_opts=()
for m in "${image_key_mappings[@]}"; do
   dash_lower_i_opts+=("-i" "$m")
done

# Do the same kind of conversion for the list of add-image-ferfs-to container specs:
dash_lower_e_opts=()
for c in "${image_ref_containers[@]}"; do
   dash_lower_e_opts+=("-e" "$c")
done

# Specify specific version skips we need to bypass bad releases:
dash_upper_k_opts=()
dash_lower_p_opt=()
if [[ $suppress_repl_graph_stuff -eq 0 ]]; then
   if [[ "$bundle_vers" == "2.1.2" ]]; then
      dash_upper_k_opts+=("K" "2.1.1")
      dash_lower_p_opt=("-p" "2.1.0")
   fi
fi

$my_dir/gen-bound-acm-ocm-hub-bundle-common.sh \
   -n "$pkg_name" -v "$bundle_vers" \
   "${dash_upper_k_opts[@]}" "${dash_lower_p_opt[@]}" \
   $suppress_repl_graph_option \
   -c $release_channel_prefix -C $candidate_channel_prefix \
   "${dash_lower_d_opt[@]}" \
   "${dash_lower_i_opts[@]}" "${dash_lower_e_opts[@]}"

