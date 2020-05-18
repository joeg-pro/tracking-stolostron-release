#!/bin/bash

# Generates bound ACM bundle.
#
# Args:
#
# $1 = Bundle version number in x.y.z[-suffix] form.  Presence of a suffix
#      starting with a dash indicates an RC/SNAPSHOT build.
#
# $2 = FUTURE: Version of previous bundle to be replaced by this one.
#
# Source pkg:  this_repo/operator-bundles/unbound/advanced-cluster-management
# Output pkg:  this_repo/operator-bundles/bound/advanced-cluster-management
#
#
# Also needs:  release image manifest fle in this_repo/image-manifests.

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))
top_of_repo=$(readlink  -f $my_dir/../..)

pkg_name="advanced-cluster-management"

bundle_vers="${1:-1.0.0}"

# Determine if this is a RC or release build.  This is used to determine
# the channel on which this bundle is to be published.

if [[ $bundle_vers == *"-"* ]]; then
   release_nr=${bundle_vers%-*}
   is_candidate_build=1
else
   release_nr=$bundle_vers
   is_candidate_build=0
fi

manifest_file="$top_of_repo/image-manifests/$release_nr.json"
unbound_pkg_dir="$top_of_repo/operator-bundles/unbound/$pkg_name"
bound_pkg_dir="$top_of_repo/operator-bundles/bound/$pkg_name"


# NOTE:
# If we're going to build and publish a sequence of release candidates and want then
# to be upgradeable from one to the next, we'll need to:
#
# - Create a unique bundle version for each, perhaps by decoaring the $release_nr
#   with some suffix to create bundle version (eg. bundle_vers="$release_nr-$seq_nr".
#
# - Manage teh previous-version (aka replaces) property of each bundle (-p) so
#   that the bundle for release candidate N+1 is marked to replace the bundle for
#   release candidate N.  That implies either some saved state or assumption about
#   seq_nr generation.

# Generate channel names assuming release_vers is in x.y.z format:

old_IFS=$IFS
IFS=. rel_xyz=(${release_nr%-*})
rel_x=${rel_xyz[0]}
rel_y=${rel_xyz[1]}
rel_z=${rel_xyz[2]}
IFS=$old_IFS

# Channel stragegy:
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
#   THIS IS THE DEFAULT CHANNEL for the package.  That is, its the channel subscription
#   will use if that subscription does not identify a particular channel.
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
#   are published  on this channel.
#
#   Version numbers for CSVs published on this channel would be of the form "x.y.z-suffix"
#   where "-suffix" indicates eg. an RC number, or RC date, etc.
#
#   Except for the first RC for the initial release of a feature release (the x.y.0 release),
#   all CSVs published on this channel must indicate that they superced (replace) the
#   immediately preceeding CSV published on this channel.

feature_release_channel="release-$rel_x.$rel_y"
feature_release_rc_channel="candidate-$rel_x.$rel_y"

if [[ is_candidate_build -eq 1 ]]; then
   publish_to_channel="$feature_release_rc_channel"
else
   publish_to_channel="$feature_release_channel"
fi
default_channel="$feature_release_channel"

# Enough setup.  Lets to this...

echo "Generating bound bundle manifests for package: $pkg_name"
echo "  From uUnbound bundle manifests in: $unbound_pkg_dir"
echo "  Writing bound bundle manifests to: $bound_pkg_dir"
echo "  For CSV/bundle version: $bundle_vers"
echo "  To be published on channel: $publish_to_channel"
echo "  With default channel: $default_channel"
echo "  Using image manifests file: $manifest_file"

$my_dir/gen-bound-bundle.sh \
   -n "$pkg_name" \
   -v "$bundle_vers" \
   -m "$manifest_file" \
   -I "$unbound_pkg_dir" -O "$bound_pkg_dir" \
   -d "$default_channel" -c "$publish_to_channel" \
   -i "multiclusterhub-operator:multiclusterhub_operator" \
   -i "multicluster-operators-placementrule:multicluster_operators_placementrule" \
   -i "multicluster-operators-subscription:multicluster_operators_subscription" \
   -i "multicluster-operators-deployable:multicluster_operators_deployable" \
   -i "multicluster-operators-channel:multicluster_operators_channel" \
   -i "multicluster-operators-application:multicluster_operators_application" \
   -i "hive:openshift_hive"

