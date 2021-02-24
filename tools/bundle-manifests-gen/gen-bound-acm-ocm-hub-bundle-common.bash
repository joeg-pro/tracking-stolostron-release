#!/bin/bash
# Bash, but source me, don't run me!
if ! (return 0 2>/dev/null); then
   >&2 echo "Error: $(basename $0) is intended to be sourced, not run."
   exit 5
fi

# Common logic for generating bound ACM/OCM Hub bundles.  Source this at
# the end of a cover script after setting the following input variables.
#
# Input Bash variables:
#
# pkg_name: (Required)
#    Name of the OLM package (eg. "advanced-cluster-management").
#
# bundle_vers: (Required)
#    Bundle version number in x.y.z[-suffix] form (eg. 2.2.0-1).
#    Presence of a [-suffix] in the bundle version indicates a candiddate/snapshot.
#
# release_channel_prefix: (Required)
#    Channel-name prefix (eg. "release") for final-release bundle versions.
#
# candidate_channel_prefix: (Required)
#    Channel-name prefix (eg. "candidate) for pre-release bundle versions.
#
# image_key_mappings: (Required)
#     Array of image-name-to-key mapping specs.  At least one entry is required.
#
# explicit_default_channel: (Optional, but not really)
#    Default channel name (full name, eg. "release-2.1").
#
#    If set, use this channel as the default channel rather than computing a default
#    based on bundle_vers.  This is currently needed so that eg. the default channel in a
#    2.0.5 bundle that is released after 2.1.0 will keep the default channel as the 2.1
#    one  vs. reverting it to the 2.0 oone.
#
# image_ref_containers:
#    Array that specifies a set containers with deployments within the CSV for which image-
#    reference environment variables (RELATED_IMAGE_*) should be injected. The array entries
#    as strings of the form <deployment_name>/<container_name>.
#
# explicit_prev_csv_vers:
#    Explicit specification of version of Previous bundle/CSV to be replaced by this one.
#    (Optional. If omitted (typical), this is computed automatically.)
#
# skip_list:
#    Array of specific previous bundle/CSV versions to skip.
#
# suppress_all_repl_graph_properties:
#    If non-zero, suppress insertion of all replacement-graph-related properties in the
#    CSV  (replaces, skips, and/or olm.skipRange). Overrides anything specified via the
#    explicit_prev_csv_release or skip_list variables, and automatic determination of
#    these aspects when not explicitly specified.
#
# Reserved for future implementation:
#
# red_hat_downstream:
#    If non-zero, enable Red Hat downstream build mode. Generates the bundle in a way
#    cuttomized for the Red Hat OSBS downstream build process. Optoinal. If omitted, the
#    bundle is generated in a way that is consistent with upstream practices.
#
# Source pkg:  this_repo/operator-bundles/unbound/<package-name>
# Output pkg:  this_repo/operator-bundles/bound/<package-name>
#
# Also needs:  The build's image manifest file in this_repo/image-manifests.
#
# Notes:
#
#-  Requires Bash 4.4 or newer.
#
# - Once OCP 4.6 is the oldest release we support, we'll be on a combination of OLM and
#   Red Hat downstream build-pipeline capability that will allow us to omit a default-channel
#   anootation in the bundle. Once we can do that, we can adopt a strategy of specifying a new
#   default in the x.y.0 bundles so that the temporal bundle release (add-to-index) order
#   controls the default.

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink  -f $my_dir/../..)

source "$my_dir/bundle-common.bash"

#--- Input variable validation ---

suppress_all_repl_graph_properties=${suppress_all_repl_graph_properties:-0}
red_hat_downstream=${red_hat_downstream:-0}

if [[ -z "$pkg_name" ]]; then
   >&2 echo "Error: Bundle package name is required (pkg_name)."
   exit 1
fi
if [[ -z "$bundle_vers" ]]; then
   >&2 echo "Error: Bundle version (x.y.z[-iter]) is required (bundle_vers)."
   exit 1
fi
if [[ -z "$release_channel_prefix" ]]; then
   >&2 echo "Error: Channel-name prefix for final release versions is required (release_channel_prefix)."
   exit 1
fi
if [[ -z "$candidate_channel_prefix" ]]; then
   >&2 echo "Error: Channel-name prefix for pre-release versions is required (candidate_channel_prefix)."
   exit 1
fi

if [[ -z "$image_key_mappings" ]]; then
   >&2 echo "Error: At least one image-name-to-key mapping is required (image_key_mappings)."
   exit 1
fi

#--- Done with input var validation ---


# Determine if this is a RC or release build and come up with a "clean" release number
# that omits any iteration number.  The release vs RC determination is used to establish
# the channel on which this bundle is to be published.

if [[ $bundle_vers == *"-"* ]]; then
   is_candidate_build=1
else
   is_candidate_build=0
fi
this_rel_nr=${bundle_vers%-*}  # Remove [-iter] if present.
parse_version "$bundle_vers"  # Sets rel_x, rel_y, etc.


# Determine immediate-predecessor bundle release nr (for replaces property) and prior
# feature release release nrs (for skipRange) automatically based on standard semantic
# versioning conventions.

if [[ $rel_yz == "0.0" ]]; then

   # This is the first feature release of a major version, i.e. 1.0.0 or 2.0.0.
   #
   # By usual semver practices, a change in major version indicates a release that is not
   # backward compatible with any previous one.  So there is no predecessor release to be
   # replaced by this one from an OLM perspective.
   #
   # Note: Maybe in such cases we should also change the OLM package name, eg. namking it
   # advanced-cluster-management-v3, to enforce the notion that it is esssnetially the
   # start of a new product stream?

   replaces_rel_nr=""
   skip_range=""
   specify_default_channel=1

   echo "Release $this_rel_nr is the initial feature release of new major version v$rel_x."
   # echo "The bundle will not have a replaces property specified."
   # echo "The bundle will not have a skipRange annotation specified."

elif [[ "$rel_z" == "0" ]]; then

   # This is the second or subsequent feature release of a major version, i.e.
   # 2.1.0, 2.2.0, etc.
   #
   # It has no in-channel predecessor but is an upgrade from any release (iniitial
   # or patch) of the pprevious feature release x.(y-1).
   #
   # Hence, it has no replaces property but does have a skip range.

   prev_rel_y=$((rel_y-1))
   replaces_rel_nr=""
   skip_range=">=$rel_x.$prev_rel_y.0 <$rel_x.$rel_y.0"
   specify_default_channel=1

   echo "Release $this_rel_nr is a follow-on in-maj-version feature release following $rel_x.$prev_rel_y."
   # echo "The bundle will not have a replaces property specified."
   # echo "The bundle will have a skip-range annotation specifying: $skip_range"

elif [[ "$rel_y" == "0" ]]; then

   # This is a z-stream/patch release of the first feature release of a major
   # version, i.e. 2.0.1, 2.0.2.
   #
   # Its in-channel predecessor is the x.y.(z-1) release (same x.y feature release).
   # There is no predecessor feature release within its major version so there
   # is no previous feature release for which it is an upgrade.
   #
   # For releases prior to 2.2.0:
   #
   # - We want a customers to do stricly squential upgrades within the feature
   #   release's z-stream (.z to .z+1). Thus there is no need to use skipRange to
   #   premit skipping within z-stream.  Future, because this is no predecessor
   #   feature release in major version, there is no need for a skipRange to handle
   #   upgrade from prior feature release.  Hence no skipRange in this case.
   #
   # For releases starting with 2.2.0:
   #
   # - We now allow skipping within a feature release's z-stream, so we apply a skipRange
   #   to allow skipping of all preioir .z releases for this feature release.

   prev_rel_z=$((rel_z-1))

   specify_default_channel=0
   replaces_rel_nr="$rel_x.$rel_y.$prev_rel_z"

   if [[ "$rel_x" -le 2 ]] && [[ "$rel_y" -lt 2 ]]; then
      skip_range=""
   else
      skip_range=">=$rel_x.rel_y.0 <$rel_x.$rel_y.$rel_z"
   fi

   echo "Release $this_rel_nr is a patch release of the first feature release of major version v$rel_x."
   # echo "The bundle will have a replaces property specifying: $replaces_rel_nr."
   # echo "The bundle will not have a skipRange annotation specified."

else

   # This is a z-stream/patch release of a second or subsequente feature release,
   # i.e. 2.1.1 or 2.2.1.
   #
   # Its in-channel predecessor is the x.y.(z-1) release (same x.y feature release).
   # It is also an upgrade from any release (initial or patch) of the previous
   # feature release x.(y-1).
   #
   # For releases prior to 2.2.0:
   #
   # - We want a customers to do stricly squential upgrades within the feature
   #   release's z-stream (.z to .z+1). Thus there is no need to use skipRange to
   #   premit skipping within z-stream. But we need to allow an upgrade from any
   #   release (initial or path) of the prior feature release stream.  So we
   #   specify a skipRange that allows just that.
   #
   # For releases starting with 2.2.0:
   #
   # - We now allow skipping within a feature release's z-stream, so we apply a
   #   skipRange to allow skipping of all preioir .z releases for this feature
   #   release.  And since we also need to premit upgrade from the prior release,
   #   we expand the skipRange to include all releases of the prior feature
   #   release (initial and patch) as well.
   #
   #   Intuition might suggest that with this skipRange now in effect there is no
   #   need to specify the replaces property anymore.  But because we still want to
   #   allow the customer to install prior releases (and we certainly need to do this
   #   in dev for testing of upgrade combinations), we need to continue to specify
   #   the replace property to keep prior versions in the index.  This is discussed
   #   in the following Google doc prepared by the operator pipeline/OLM team:
   #
   #   https://docs.google.com/document/d/1N29w764eZroOywvLK1tb00XqX40A9yo4ghmSLE9PaMI/edit#heading=h.rmlu2bexicpd

   prev_rel_y=$((rel_y-1))
   prev_rel_z=$((rel_z-1))

   specify_default_channel=0
   replaces_rel_nr="$rel_x.$rel_y.$prev_rel_z"

   if [[ "$rel_x" -le 2 ]] && [[ "$rel_y" -lt 2 ]]; then
      skip_range=">=$rel_x.$prev_rel_y.0 <$rel_x.$rel_y.0"
   else
      skip_range=">=$rel_x.$prev_rel_y.0 <$rel_x.$rel_y.$rel_z"
   fi

   echo "Release $this_rel_nr is a patch release of follow-on in-maj-version feature release $rel_x.$rel_y."
   # echo "The bundle will have a replaces property specifying: $replaces_rel_nr."
   # echo "The bundle will have a skip-range annotation specifying: $skip_range"

fi

if [[ $suppress_all_repl_graph_properties -eq 0 ]]; then
   if [[ -n "$explicit_prev_csv_vers" ]]; then
      echo "NOTE: Explicitly-specified previous release number is being used."
      replaces_rel_nr=$explicit_prev_csv_vers
   fi
fi

# Random notes on replacement-chain approach for upstream snapshots:
#
# If we're going to build and publish a sequence of snapshots/release candidates and
# want then to be upgradeable from one to the next, we'll need to:
#
# - Create a unique bundle version for each, perhaps by decoaring the $this_rel_nr
#   with some suffix to create bundle version (eg. bundle_vers="$this_rel_nr-$seq_nr".
#
# - Manage teh previous-version (aka replaces) property of each bundle (-p) so
#   that the bundle for release candidate N+1 is marked to replace the bundle for
#   release candidate N.  That implies either some saved state or assumption about
#   seq_nr generation.
#
# - We might also want to be able to skip intermediate snapshots too, via skip-range.
#   But we would also want to use skip-range so that snapshots for feature releaase x.y
#   would be upgrades fro snapshots for the prior feature release too.  Its not clear
#   how we could use skip range to do both.  (Maybe multiple skip ranges?)
#
# - Our auto-calculation of replaces/skip-range probably won't work, will require
#   explicit specification of both the replaced release and the skip range.

manifest_file="$top_of_repo/image-manifests/$this_rel_nr.json"
unbound_pkg_dir="$top_of_repo/operator-bundles/unbound/$pkg_name"
bound_pkg_dir="$top_of_repo/operator-bundles/bound/$pkg_name"


# Generate channel names using this strategy:
#
# For a given feature release "x.y" (eg. 1.0, 2.0, 2.1), we maintain two channels as follows.
#
# - The published-release channel "<release_channel_prefix>-x.y" (eg. release-2.0):
#
#   Purpose:
#
#   This channel provides a mechanism for a customer to "follow" only the official initial
#   and fix-pack releeases for a given x.y feature release.
#
#   If a customer configures a subscription to this channel with automatic updates
#   (automaitc install-plan approval) enabled,  the operator will be automatically
#   updated by OLM as official z-stream fix-packs are published by the engineering team
#   for the  given feature release.  If the subscrive to this channel but with manual
#   install-plan approval in effect, OLM will create pending install plans as z-stream
#   fix-packs are published.  (Configuration of automatic or manual insall-plan approval
#   is orthoginal to specifying the channel "followed" by the subscription.)
#
#   This is specified as the default channel for the package when the release is
#   an x.y.0 feature release. That is, its the channel subscription will use if that
#   subscription does not identify a particular channel.  My specifying it as default
#   only on a feature release, we avoid having a subsequently-published patch (z-stream)
#   release for a prior x.y release set the edfault channel to something other than
#   the most recently publisyed x.y.
#
#   Engineering implications:
#
#   An RC for an x.y.z release can be published to this channel ONLY when it passes all of
#   our public-release gates and is dubbed the official build for that x.y.z release.
#   This is maybe done by some promition-time rebuild of the bundle in the downstream.
#
#   The CSV version for a release published on this channel should be of the form
#   "x.y.z" with no RC/iteration decoration of that release number.
#
# ---
#
# - The release-canidates channel "<canidate_channel_prefix>-x.y" (eg. candidate-1.0):
#
#   Purpose:
#
#   This channel provides a mechanism for a customer to be bleeding edge and "follow"
#   all of the release candidates (for initial release and then subsequent fix-packs)
#   for a given x.y feature release.
#
#   If a customer configures a subscription to this channel, the operator will be
#   automatically updated or pending install plans created by OLM (depnding on the customer's
#   choice for install-plan approval), as the engineering team publishes public candidates
#   for the given feature release's initial release or fix-pack update.
#
#   Since this is not the default channel for the package, a customer will have to make
#   an explicit choice to follow this channel.
#
#   Engineering implications:
#
#   All to-be-public RCs for an iniital or fix-pack update for for an x.y.feature release
#   are published on this channel.
#
#   Version numbers for CSVs published on this channel would be of the form "x.y.z-suffix"
#   where "-suffix" indicates eg. an RC number, or RC date, etc.
#
#   Except for the first RC for the initial release of a feature release (the x.y.0 release),
#   all CSVs published on this channel must indicate that they superced (replace) the
#   immediately preceeding CSV published on this channel.

feature_release_channel="$release_channel_prefix-$rel_x.$rel_y"
feature_release_rc_channel="$candidate_channel_prefix-$rel_x.$rel_y"

if [[ $is_candidate_build -eq 1 ]]; then
   publish_to_channel="$feature_release_rc_channel"
else
   publish_to_channel="$feature_release_channel"
fi

default_channel=""
if [[ -n "$explicit_default_channel" ]]; then
   default_channel="$explicit_default_channel"
elif [[ $specify_default_channel -eq 1 ]]; then
   default_channel="$feature_release_channel"
fi
if [[ -n "$default_channel" ]]; then
   dash_lower_d_opt=("-d" "$default_channel")
fi

# Form the previous-bundle arg and/or skip-range and/or skip args if appropraite
# unless we're skipping all replacement-graph stuff.

if [[ $suppress_all_repl_graph_properties -eq 0 ]]; then

   if [[ -n "$replaces_rel_nr" ]]; then
      dash_lower_p_opt=("-p" "$replaces_rel_nr")
   fi
   if [[ -n "$skip_range" ]]; then
      # Skip range probably contains blank separated expressions which need to be kept
      # together and passsed as a single argument element. So we either have to contribute
      # nothing to the final command (i.e. not including a null-valued arg entry), or an
      # ooption followed by its args as a two argument entries.
      #
      # It might be possible to achieve this by runnning the final command through "eval"
      # together with appropriately escaped-quoting in setting dash_lower_k_opt here,
      # but use of eval is obscure/subtle and might have side effects on other parts of
      # htis code not written thinking the final command weould go through an eval resolution
      # befoer being passed to the shell.
      #
      # So instead, we can do this via use of  an array, together with ${var:+value} expression
      # to consume the value later.

      dash_lower_k_opt=("-k" "$skip_range")
   fi

   dash_upper_k_opts=()
   for skip in $skip_list; do
      dash_upper_k_opts+=("-K" "$skip")
   done

else
   echo "NOTE: All replacement-graph-related properties are being suppressed for the CSV/bundle."
   dash_lower_p_opt=()
   dash_lower_k_opt=()
   dash_upper_k_opts=()
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

# We probably have to think through how community contributors will build the entire
# set of OCM parts, including the budnle.
#
# One possibility might be that regardless of how they get the images built and into
# some registry, they would also have to also generate/maintain an image-manifest
# in our expected format in order to use as an input to the bundle-building process.
# In which case, maybe nothing unique will be needed here. (WE already allow an
# invoker to specify the location of same, along with other input and output
# directories).
#
# But maybe we could offer something simpler.  The first requirement a contributor
# fases is the need to put the images somewhere other than quay.io/o-c-m.  Ada next
# challenge would be the need to maintain the image manifest so as to convey the
# image digests to us as we currently insist on digest-based pinning.  Maybe we can
# address these two things by allowing registry remapping and tag-based "pinning".
# With that in place, the image manifest file really devolves into being just a
# list of image (repository) names, wiht the other info coming from outside of
# tha tfile.  Then, a contributor could just use one of the recent image manifest
# files in the release repo rather than having to have one of thier own.
#
# So, as a stab in that direction, we look for a couple of enviornment variables,
# and if set, use them to do image-and-namespace mapping and tag-based "pininnng"
# of image references we find.

rgy_and_ns_override="$BUNDLE_GEN_RGY_AND_NAMESPACE"
pin_using_tag_override="$BUNDLE_GEN_PIN_TO_TAG"

dash_lower_r_opts=()
if [[ -n "$rgy_and_ns_override" ]]; then
   # Assume the image manifest will be using quay.io/open-cluster-management
   # and map from tha tto what is mentioned in the env var.
   dash_lower_r_opts+=("-r" "quay.io/open-cluster-management:$rgy_and_ns_override")
fi
if [[ -n "$pin_using_tag_override" ]]; then
   dash_lower_t_opt=("-t" "$pin_using_tag_override")
fi

# Enough setup.  Lets to this...
echo ""
echo "----------------------------------------------------------------------------"
echo "Generating bound bundle manifests for package: $pkg_name"
echo "  For CSV/bundle version: $bundle_vers"
echo "  To be published on channel: $publish_to_channel"
if [[ -n "$default_channel" ]]; then
   echo "  With default channel: $default_channel"
else
   echo "  With no default channel specified"
fi
if [[ -n "$dash_lower_p_opt" ]]; then
   echo "  Replacing previous CSV/bundle version: $replaces_rel_nr"
fi
if [[ -n "$dash_lower_k_opt" ]]; then
   echo "  Skipping previous CSV/bundle range: $skip_range"
fi
if [[ -n "$dash_upper_k_opts" ]]; then
   echo "  Skipping specific previous CSV/bundle versions: $skip_list"
fi
if [[ -n "$dash_lower_e_opts" ]]; then
   cnt=$(( ${#dash_lower_e_opts[@]} / 2 ))
   containers="containers"
   if [[ $cnt -eq 1 ]]; then
      containers="container"
   fi
   echo "  With inage-ref enviornment variables being injected into $cnt operator $containers"
fi
if [[ -n "$dash_lower_r_opts" ]]; then
   echo "  Remapping all image references to registry/namespace $rgy_and_ns_override"
fi
if [[ -n "$dash_lower_t_opt" ]]; then
   echo "  Pinning all image references to tag $pin_using_tag_override"
fi
echo "  From uUnbound bundle manifests in: $unbound_pkg_dir"
echo "  Writing bound bundle manifests to: $bound_pkg_dir"
echo "  Using image manifests file: $manifest_file"
echo "----------------------------------------------------------------------------"
echo ""
$my_dir/gen-bound-bundle.sh \
   -n "$pkg_name" -v "$bundle_vers" \
   -c "$publish_to_channel" "${dash_lower_d_opt[@]}" \
   "${dash_lower_p_opt[@]}" "${dash_lower_k_opt[@]}" "${dash_upper_k_opts[@]}" \
   "${dash_lower_r_opts[@]}" "${dash_lower_t_opt[@]}"  \
   -I "$unbound_pkg_dir" -O "$bound_pkg_dir" -m "$manifest_file" \
   "${dash_lower_i_opts[@]}" "${dash_lower_e_opts[@]}"

