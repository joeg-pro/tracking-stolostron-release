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

source "$my_dir/bundle-common.bash"

pkg_name="advanced-cluster-management"
release_channel_prefix="release"
candidate_channel_prefix="candidate"

bundle_vers="$1"
if [[ -z "$bundle_vers" ]]; then
   >&2 echo "Error: Bundle version (x.y.z[-iter]) is required."
   exit 5
fi
this_rel_nr=${bundle_vers%-*}  # Remove [-iter] if present.
parse_release_nr "$bundle_vers"   # Sets rel_x, rel_y, etc.

# Note: The handling of $2 has evolved a lot, from originally being the number
# of the immediately predecessor release, to being fully ignored, to now being
# a way to suppress insertion of replacement-graph properties.

suppress_all_repl_graph_properties=0
if [[ "$2" == "none" ]]; then
   suppress_all_repl_graph_properties=1
fi

explicit_default_channel="$3"

# Starting with ACM 2.5, ACM reliese on MCE so we drop from ACM those
# components that are now provided by MCE.

using_mce=1
if [[ $rel_x -le 2 ]] && [[ $rel_y -lt 5 ]]; then
   using_mce=0
fi

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

# From ACM 1.0 to 2.4:
if [[ $using_mce -eq 0 ]]; then
   image_key_mappings+=("hive:openshift_hive")
fi

# Since ACM 2.x:
if [[ "$rel_x" -ge 2 ]]; then

   # From ACM 2.0 to 2.4:
   if [[ $using_mce -eq 0 ]]; then
      image_key_mappings+=("registration-operator:registration_operator")
   fi

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

   # Since ACM 2.4:
   if [[ "$rel_y" -ge 4 ]]; then
       # Added to AppSub operator
      image_key_mappings+=("multicloud-integrations:multicloud_integrations")
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

# Specify specific version skips we need to bypass bad releases:
skip_list=()
explicit_prev_csv_vers=""
if [[ $suppress_repl_graph_stuff -eq 0 ]]; then
   if [[ "$bundle_vers" == "2.1.2" ]]; then
      skip_list+=("2.1.1")
      explicit_prev_csv_vers="2.1.0"
   fi
fi
red_hat_downstream=0

gen_bound_bundle pkg_name bundle_vers \
   release_channel_prefix candidate_channel_prefix \
   image_key_mappings image_ref_containers \
   explicit_default_channel \
   explicit_prev_csv_vers skip_list \
   suppress_all_repl_graph_properties \
   red_hat_downstream

