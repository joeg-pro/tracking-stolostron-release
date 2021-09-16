#!/bin/bash

# Generates bound Multicloud Engine bundle.
#
# Args:
#
# $1 = Bundle version number in x.y.z[-suffix] form.  Presence of a suffix
#      starting with a dash indicates an RC/SNAPSHOT build.  Required.
#
# $2 = Method for handling generation of replacement-graph properties.  If specified as
#      the value "none" then no upgrade-graph properties are put into the CSV/bundle
#      (to support upstream builds which don't yet build a  multi-bundle catalog).
#      Otherwise, teh value is ignored and is treated  as "auto" indicating that
#      replacment-graph properties are automatically computed and placed in the CSV.
#
#      (Historically, the treatment of the second argument to scripts like this has
#      evolved over time, starting as an explicit previous-release number with that
#      form now completely deprecated.)
#
# $3 = Explicit default-channel name, overrides any automatic determination or
#      management of same.
#
# Source pkg:  this_repo/operator-bundles/unbound/multicluster-engine
# Output pkg:  this_repo/operator-bundles/bound/multicluster-engine
#
# Also needs:  The build's image manifest file in this_repo/image-manifests.
#
# Note: Requires Bash 4.4 or newer.

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))

source $my_dir/bundle-common.bash
# top_of_repo is set as side effect of above source'ing.

pkg_name="multicluster-engine"
release_channel_prefix="stable"
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

# Define the list of image-key mappings for use in image pinning.

# We add mappings to the list based on the release for which the components were added
# to ACM as compared to the release we're building the bundle for.  Doing it this way
# lets us keep  this script idential across ACM release branches if we want.

image_key_mappings=()
image_key_mappings+=("backplane-operator:backplane_operator")

# Define the list of CSV deployment containers that are to have image-ref
# environment variables injected for the bundle's related images.

image_ref_containers+=("backplane-operator/backplane-operator")

# Specify specific version skips we need to bypass bad releases:

skip_list=()
explicit_prev_csv_vers=""
red_hat_downstream=0

gen_bound_bundle pkg_name bundle_vers \
   release_channel_prefix candidate_channel_prefix \
   image_key_mappings image_ref_containers \
   explicit_default_channel \
   explicit_prev_csv_vers skip_list \
   suppress_all_repl_graph_properties \
   red_hat_downstream

