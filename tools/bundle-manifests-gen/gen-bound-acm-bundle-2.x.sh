#!/bin/bash

# Generates bound ACM bundle.
#
# Args:
#
# $1 = Bundle version number in x.y.z[-suffix] form.  Presence of a suffix
#      starting with a dash indicates an RC/SNAPSHOT build.  Required.
#
# $2 = Version of the immediately-previous bundle to be replaced by this
#      one via the replaces attribute. or "auto" to determine htis based on
#      semver practices.  Default: None
#
# Source pkg:  this_repo/operator-bundles/unbound/advanced-cluster-management
# Output pkg:  this_repo/operator-bundles/bound/advanced-cluster-management
#
# Also needs:  The build's image manifest file in this_repo/image-manifests.

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink  -f $my_dir/../..)

pkg_name="advanced-cluster-management"
feature_release_channel_prefix="release"
feature_release_rc_channel_prefix="candidate"

bundle_vers="$1"
if [[ -z "$bundle_vers" ]]; then
   >&2 echo "Error: Bundle version (x.y.z[-iter]) is required."
   exit 1
fi
this_rel_nr=${bundle_vers%-*}  # Remove [-iter] if present.

replaces_rel_nr="$2"
# This needs to be optional because the first release in a version stream
# (a new x in an x.y.z release id) or maybe even of a new feature release
# stream (a new y in x.y.z) would not have a previous bundle to be replaced.

# Allow the replaces-release-nr to be omitted via a dummy value so
# invoker can specify an explicit default channel w/o replaces release.
# (Shouldn't have used positional args, I guess.)
if [[ "$replaces_rel_nr" == "none" ]]; then
   replaces_rel_nr=""
fi

explicit_default_channel="$3"
# If specified, use this channel as the default channel rather than computing
# a default based on $bundle_vers.  This is needed so that eg. the default
# channel in a 2.0.5 bundle that is released after 2.1.0 will keep the
# default channel as the 2.1 one vs. reverting it to the 2.0 oone.
#
# This should be the entire channel name, eg. "release-2.0".
#
# Note: Once OCP 4.5 is the oldest release we support, we can drop this
# explicit default channel stuff because it will then be possible to just
# omit the default channel in z-stream releases.  This logic is already
# coded into the script by gets trumped by the explicit default channel
# if specified.

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

fi

# Determine if this is a RC or release build.  This is used to determine
# the channel on which this bundle is to be published.

if [[ $bundle_vers == *"-"* ]]; then
   is_candidate_build=1
else
   is_candidate_build=0
fi

# If requested by "auto", determine immediate-predecessor bundle release nr (for replaces
# property) and priori feature release release nrs (for skipRange) automatically based on
# standard semantic versioning conventions.

if [[ "$replaces_rel_nr" == "auto" ]]; then

   if [[ $rel_yz == "0.0" ]]; then

      # This is the first feature release of a major version, i.e. 1.0.0 or 2.0.0.
      #
      # By usual semver practices, a change in major version indicates a release
      # that is not backward compatible with any previous one.  So there is no
      # predecessor release to be replaced by this one from an OLM perspective.
      #
      # Note: Maybe in such cases we should also change the OLM package name, eg.
      # namking it advanced-cluster-management-v3, to enforce the notion that it
      # is esssnetially the start of a new product stream?

      replaces_rel_nr=""
      skip_range=""
      specify_default_channel=1

      echo "Release $this_rel_nr is the initial feature release of new major version v$rel_x."
      echo "The bundle will not have a replaces property specified."
      echo "The bundle will not have a skipRange annotation specified."

   elif [[ "$rel_z" == "0" ]]; then

      # This is the second or subsequent feature release of a major version, i.e.
      # 2.1.0, 2.2.0, etc.
      #
      # It has no single immediate predecessor but should be an upgrade from any
      # release (iniitial or patch) of the prior feature release.
      #
      # Hence, it has no replaces property but does have a skip range.

      prev_rel_y=$((rel_y-1))
      replaces_rel_nr=""
      skip_range=">=$rel_x.$prev_rel_y.0 <$rel_x.$rel_y.0"
      specify_default_channel=1

      echo "Release $this_rel_nr is a follow-on in-maj-version feature release following $rel_x.$prev_rel_y."
      echo "The bundle will not have a replaces property specified."
      echo "The bundle will have a skip-range annotation specifying: $skip_range"

   elif [[ "$rel_y" == "0" ]]; then

      # This is a z-stream/patch release of the first feature release of a major
      # version, i.e. 2.0.1, 2.0.2.
      #
      # Its predecessor is simply the z-1 release of the same x.y feature release.
      # Since this is in the z-stream of the first feature release, there is no need
      # for a skipRange to handle upgrade from a prior feature release.

      prev_rel_z=$((rel_z-1))
      replaces_rel_nr="$rel_x.$rel_y.$prev_rel_z"
      skip_range=""
      specify_default_channel=0

      echo "Release $this_rel_nr is a patch release of the first feature release of major version v$rel_x."
      echo "The bundle will have a replaces property specifying: $replaces_rel_nr."
      echo "The bundle will not have a skipRange annotation specified."

   else

      # This is a z-stream/patch release of a second or subsequente feature release,
      # i.e. 2.1.1 or 2.2.1.
      #
      # Its predecessor is simply the z-1 release of the same x.y feature release.
      # But to make OLM upgrade works, it also needs to be an upgrade from any release
      # (initial or patch) of the prior feature release.

      prev_rel_y=$((rel_y-1))
      prev_rel_z=$((rel_z-1))
      replaces_rel_nr="$rel_x.$rel_y.$prev_rel_z"
      skip_range=">=$rel_x.$prev_rel_y.0 <$rel_x.$rel_y.0"
      specify_default_channel=0

      echo "Release $this_rel_nr is a patch release of follow-on in-maj-version feature release $rel_x.$rel_y."
      echo "The bundle will have a replaces property specifying: $replaces_rel_nr."
      echo "The bundle will have a skip-range annotation specifying: $skip_range"

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
# - The feature-release channel "release-x.y" (eg. release-2.0):
#
#   Purpose:
#
#   This channel provides a mechanism for a customer to "follow" only the official
#   initial and fix-pack releeases for a given x.y feature release.
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
# - The feature-release candidates channel "candidate-x.y" (eg. candidate-1.0):
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

feature_release_channel="$feature_release_channel_prefix-$rel_x.$rel_y"
feature_release_rc_channel="$feature_release_rc_channel_prefix-$rel_x.$rel_y"

if [[ is_candidate_build -eq 1 ]]; then
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
   dash_lower_d_option="-d $default_channel"
fi

# Form the previous-bundle arg or skip-range arg if appropraite.

if [[ -n "$replaces_rel_nr" ]]; then
   dash_lower_p_opt="-p $replaces_rel_nr"
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

# Form the list of -i image-key-mapping arguments.

dash_lower_i_opts=()
for m in "${image_key_mappings[@]}"; do
   dash_lower_i_opts+=("-i" "$m")
done

# Enough setup.  Lets to this...

echo "Generating bound bundle manifests for package: $pkg_name"
echo "  From uUnbound bundle manifests in: $unbound_pkg_dir"
echo "  Writing bound bundle manifests to: $bound_pkg_dir"
echo "  For CSV/bundle version: $bundle_vers"
if [[ -n "$replaces_rel_nr" ]]; then
   echo "  Replacing previous CSV/bundle version: $replaces_rel_nr"
fi
if [[ -n "$skip_range" ]]; then
   echo "  Skipping previous CSV/bundle range: $skip_range"
fi
echo "  To be published on channel: $publish_to_channel"
if [[ -n "$default_channel" ]]; then
   echo "  With default channel: $default_channel"
else
   echo "  With no default channel specified"
fi
echo "  Using image manifests file: $manifest_file"

$my_dir/gen-bound-bundle.sh \
   -n "$pkg_name" \
   -v "$bundle_vers" $dash_lower_p_opt \
   ${dash_lower_k_opt:+"${dash_lower_k_opt[@]}"}  \
   -m "$manifest_file" \
   -I "$unbound_pkg_dir" -O "$bound_pkg_dir" \
   $dash_lower_d_option -c "$publish_to_channel" \
   ${dash_lower_i_opts:+"${dash_lower_i_opts[@]}"}

