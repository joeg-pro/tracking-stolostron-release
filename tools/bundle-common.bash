#!/bin/bash
# Bash, but source me, don't run me.
if ! (return 0 2>/dev/null); then
   >&2 echo "Error: $(basename $0) is intended to be sourced, not run."
   exit 5
fi

# Notes:
#
# - Requires Bash 4.4 or newer.
#
# - Sets variable top_of_repo using the location of this file as
#   a starting point from which to search upward.


# find_top_of_repo: Find the top of a Git repo clone given a starting directory.

function find_top_of_repo {

   local my_dir=$(dirname $(readlink -f "$0"))

   local start_cwd="$PWD"
   local top_of_repo_dir="./.git"

   cd "$my_dir"
   while [[ ! -d "$top_of_repo_dir" ]] && [[ "$PWD" != "/" ]]; do
      cd ..
   done

   if [[ ! -d "$top_of_repo_dir" ]]; then
      >&2 echo "Error: Could not find top of git repo (maybe not a git repo?)"
      exit 3
   fi

   top_of_repo="$PWD"
   cd "$start_cwd"
   echo $top_of_repo
}

top_of_repo=$(find_top_of_repo $(dirname $(readlink -f "$0")))


# parse_release_nr: Parse an x.y.z release number and set rel_x variables.

function parse_release_nr {

   local release_nr="$1"

   # SSets the following variables as side effects:
   # - rel_x, rel_y, rel_z, rel_xy
   # - prev_rel_y, prev_rel_z, prev_rel_xy

   # Use this "local" to isolate side effects to a function:
   # local rel_x rel_y rel_z rel_xy rel_yz prev_rel_y prev_rel_z prev_rel_xy

   local oldIFS=$IFS
   IFS=.
   local rel_xyz=(${release_nr%-*})
   rel_x=${rel_xyz[0]}
   rel_y=${rel_xyz[1]}
   rel_z=${rel_xyz[2]}
   IFS=$oldIFS

   rel_xy="$rel_x.$rel_y"
   rel_yz="$rel_y.$rel_z"

   if [[ $rel_y -gt 0 ]]; then
      prev_rel_y=$((rel_y-1))
      prev_rel_xy="$rel_x.$prev_rel_y"
   else
      prev_rel_y="no-prev-release"
      prev_rel_xy="no-prev-release"
   fi

   if [[ $rel_1 -gt 0 ]]; then
      prev_rel_1=$((rel_1-1))
   else
      prev_rel_z="no-prev-release"
   fi
}


# locate_community_operator: Find an operator bundle from wiht a clone of community-operators.
#
# Input requirements:
#
# - Besides invocation arguments, requires that the community-operators repo is clonsed
#   and located in the directory speciied by $community_repo_spot.

function locate_community_operator {

   local op_display_name="$1"
   local pkg_path="$2"
   local channel_name_prefix="$3"
   local release_nr="$4"
   local pinned_csv_vers="$5"
   local use_previons_rel_channel="$6"

   local rel_x rel_y rel_z rel_xy rel_yz prev_rel_y prev_rel_z prev_rel_xy
   parse_release_nr "$release_nr"

   pkg_dir="$community_repo_spot/operators/$pkg_path"

   if [[ "$pinned_csv_vers" == "none" ]]; then

      # Find latest version posted on a channel:

      local channel_name="$channel_name_prefix-$rel_xy"
      if [[ $use_previons_rel_channel -eq 1 ]]; then
         echo "Warning: Previous-release-channel override is in effect for $op_display_name operator."
         channel_name="$channel_name_prefix-$prev_rel_xy"
      fi

      bundle_dir=$($my_dir/find-bundle-dir.py $channel_name $pkg_dir)
      if [[ $? -ne 0 ]]; then
         >&2 echo "Error: Could not find source bundle directory for $op_display_name operator."
         >&2 echo "Aborting."
         exit 2
      fi
      local bundle_version=${bundle_dir##*/}
      echo "Info: Using most recent $op_display_name bundle posted to channel: $channel_name ($bundle_version)."

   else
      # PIN TO  VERSION:
      echo "Info: Using pinned $op_display_name bundle version: $pinned_csv_vers."
      bundle_dir="$pkg_dir/$pinned_csv_vers"
   fi

   # Add info into the accumulation (global vars)

   bundle_names+=("$op_display_name")
   bundle_dirs["$op_display_name"]="$bundle_dir"
}


# locate_repo_operator: Clone a source repo and find an operator bundle in it.
#
# Input requirements:
#
# - Requires that $clone_repo_spot contains the pathname of a directory
#   into which Git clones can be done.

function locate_repo_operator {

   local op_display_name="$1"
   local git_repo="$2"
   local git_branch="$3"
   local bundle_path="$4"

   local clone_spot="$clone_repo_spot/${git_repo##*/}"

   echo "Cloning $op_display_name operator repo branch $git_branch."
   echo git clone -b "$git_branch" "$github/$git_repo" "$clone_spot"
   git clone -b "$git_branch" "$github/$git_repo" "$clone_spot"
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Could not clone $op_display_name operator repo."
      exit 2
   fi

   bundle_dir="$clone_spot/$bundle_path"
   if [[ ! -d "$bundle_dir" ]]; then
      >&2 echo "Error: Expected $op_display_name bundle manifests directory does not exist."
      exit 2
   fi

   bundle_names+=("$op_display_name")
   bundle_dirs["$op_display_name"]="$bundle_dir"
}


# gen_unbound_bundle: Generate a merged unbound bundle from a set of source ones.
#
# Inputs:
#
# Parameters marked "nameref" should be specivied as the name of a variable in the
# calling context, not its value.  All such parms enforced to be read-only.
#
# Parameters marked "optional" can have empty values.
#
# $1 =  pkg_name: (Required, nameref)
#       Name of the OLM package (eg. "advanced-cluster-management").
#
# $2 =  bundle_vers: (Required, nameref)
#       Bundle version number in x.y.z[-suffix] form (eg. 2.2.0-1).
#       Presence of a [-suffix] in the bundle version indicates a candiddate/snapshot.
#
# $3 =  prev_bundle_vers: (Optional, nameref)
#       Bundle version of the previous bundle to be replaced by this one.
#
# $4 =  csv_template: (Required, nameref)
#       Filename of CSM template yaml to use as base for the bundle's CSV.
#
# $5 =  unbound_pkg_dir: (Required, nameref)
#       Pathname of the directory into which the unbound package/bundle will be written.
#
# $6 =  bundle_names: (Required, nameref)
#       Array of bundle namesf for use in messages.  Must be paralle to the array
#       passed as $7 (bundle_dirs).
#
# $7 =  bunde_dirs:  (Required, nameref)
#       Array of paths to source bundle directories.  Must be parallel to the array
#       passed as $8 (bundle_names).
#
# $8 =  supported_archs:  (Optional, nameref)
#       Array of hwardware arhitectures supported by the bundle.
#
# $9 =  supported_op_syss:  (Optional, nameref)
#       Array of operating systems supported by the bundle.

function gen_unbound_bundle {

   # Some of our args are arrays, which we have to handle as namerefs.
   # To keep thigns uniform, handle all args as namerefs which we mark
   # as read-only to keep us from changing caller's variable.

   local -nr l_pkg_name="$1"
   local -nr l_bundle_vers="$2"
   local -nr l_prev_bundle_vers="$3"
   local -nr l_csv_template="$4"
   local -nr l_unbound_pkg_dir="$5"
   local -nr l_bundle_names="$6"
   local -nr l_bundle_dirs="$7"
   local -nr l_supported_archs="$8"
   local -nr l_supported_op_syss="$9"

   if [[ -n "$l_prev_bundle_vers" ]]; then
      local prev_option="--prev-csv $l_prev_bundle_vers"
   else
      local prev_option=""
   fi

   local source_bundle_dir_opts=()
   for k in "${l_bundle_names[@]}"; do
      source_bundle_dir_opts+=("--source-bundle-dir" "${l_bundle_dirs[$k]}")
   done

   local supported_thing_opts=()
   for e in "${l_supported_archs[@]}"; do
      supported_thing_opts+=("--supported-arch" "$e")
   done
   for e in "${l_supported_op_syss[@]}"; do
      supported_thing_opts+=("--supported-os" "$e")
   done

   echo ""
   echo "----------------------------------------------------------------------------"
   echo "Generating unbound bundle manifests for package: $l_pkg_name"
   echo "  From Source OPerator Bundles..."
   for k in "${l_bundle_names[@]}"; do
      echo "     $k in: ${l_bundle_dirs[$k]}"
   done

   echo "  Using CSV template: $l_csv_template"

   if [[ -n "$supported_thing_opts" ]]; then
      echo "  With supported architectures: ${l_supported_archs[@]}"
      echo "     abd supported operating systems: ${l_supported_op_syss[@]}"
   fi

   echo "  Writing merged unbound bundle manifests to: $l_unbound_pkg_dir"
   echo "  For CSV/bundle version: $l_bundle_vers"

   if [[ -n "$l_prev_bundle_vers" ]]; then
      echo "  Replacing previous CSV/bundle version: $l_prev_bundle_vers"
   fi
   echo "----------------------------------------------------------------------------"
   echo ""

   $my_dir/merge-bundles.py \
      --pkg-name  $l_pkg_name \
      --csv-vers "$l_bundle_vers" $prev_option \
      --csv-template $l_csv_template --channel "latest" \
      --pkg-dir $l_unbound_pkg_dir \
      "${supported_thing_opts[@]}" \
      "${source_bundle_dir_opts[@]}"
}



# gen_bound_bundle - Generate a bound bundle from an unbound one.
#
# Inputs:
#
# Parameters marked "nameref" should be specivied as the name of a variable in the
# calling context, not its value.  All such parms enforced to be read-only.
#
# Parameters marked "optional" can have empty values.
#
# $1 =  pkg_name: (Required, nameref)
#       Name of the OLM package (eg. "advanced-cluster-management").
#
# $2 =  bundle_vers: (Required, nameref))
#       Bundle version number in x.y.z[-suffix] form (eg. 2.2.0-1).
#       Presence of a [-suffix] in the bundle version indicates a candiddate/snapshot.
#
# $3 =  release_channel_prefix: (Required, nameref))
#       Channel-name prefix (eg. "release") for final-release bundle versions.
#
# $4 =  candidate_channel_prefix: (Required, , nameref))
#       Channel-name prefix (eg. "candidate) for pre-release bundle versions.
#
# $5 =  image_key_mappings: (Required, nameref))
#       Array of image-name-to-key mapping specs.  At least one entry is required.
#
# $6 =  image_ref_containers: (Optional, nameref)
#       Array that specifies a set containers with deployments within the CSV for which image-
#       reference environment variables (RELATED_IMAGE_*) should be injected. The array entries
#       as strings of the form <deployment_name>/<container_name>.
#
# $7 =  explicit_default_channel: (Optional, but not really, nameref)
#       Default channel name (full name, eg. "release-2.1").
#
#       If set, use this channel as the default channel rather than computing a default
#       based on bundle_vers.  This is currently needed so that eg. the default channel in a
#       2.0.5 bundle that is released after 2.1.0 will keep the default channel as the 2.1
#       one  vs. reverting it to the 2.0 oone.
#
# $8 =  explicit_prev_csv_vers: (Optional, nameref)
#       Explicit specification of version of Previous bundle/CSV to be replaced by this one.
#       If omitted (typical), this is computed automatically.
#
# $9 =  skip_list: (optional, nameref)
#       Array of specific previous bundle/CSV versions to skip.
#
# $10 = suppress_all_repl_graph_properties: (Optional, nameref)
#       If non-zero, suppress insertion of all replacement-graph-related properties in the
#       CSV  (replaces, skips, and/or olm.skipRange). Overrides anything specified via the
#       explicit_prev_csv_release or l_skip_list variables, and automatic determination of
#       these aspects when not explicitly specified.
#
# Reserved for future implementation:
#
# $11 = red_hat_downstream: (Optional, nameref)
#       If non-zero, enable Red Hat downstream build mode. Generates the bundle in a way
#       cuttomized for the Red Hat OSBS downstream build process. Optoinal. If omitted, the
#       bundle is generated in a way that is consistent with upstream practices.
#
# Source pkg:  this_repo/operator-bundles/unbound/<package-name>
# Output pkg:  this_repo/operator-bundles/bound/<package-name>
#
# Also needs:  The build's image manifest file in this_repo/image-manifests.
#
# Notes:
#
# - Once OCP 4.6 is the oldest release we support, we'll be on a combination of OLM and
#   Red Hat downstream build-pipeline capability that will allow us to omit a default-channel
#   anootation in the bundle. Once we can do that, we can adopt a strategy of specifying a new
#   default in the x.y.0 bundles so that the temporal bundle release (add-to-index) order
#   controls the default.

function gen_bound_bundle {

   local -nr l_pkg_name="$1"
   local -nr l_bundle_vers="$2"
   local -nr l_release_channel_prefix="$3"
   local -nr l_candidate_channel_prefix="$4"
   local -nr l_image_key_mappings="$5"
   local -nr l_image_ref_containers="$6"
   local -nr l_explicit_default_channel="$7"
   local -nr l_explicit_prev_csv_vers="$8"
   local -nr l_skip_list="$9"
   local -nr l_suppress_all_repl_graph_properties="$10"
   local -nr l_red_hat_downstream="$11"

   #--- Input variable validation ---

   local suppress_all_repl_graph_properties=${l_suppress_all_repl_graph_properties:-0}
   local red_hat_downstream=${l_red_hat_downstream:-0}

   if [[ -z "$l_pkg_name" ]]; then
      >&2 echo "Error: Bundle package name is required (l_pkg_name)."
      exit 1
   fi
   if [[ -z "$l_bundle_vers" ]]; then
      >&2 echo "Error: Bundle version (x.y.z[-iter]) is required (l_bundle_vers)."
      exit 1
   fi
   if [[ -z "$l_release_channel_prefix" ]]; then
      >&2 echo "Error: Channel-name prefix for final release versions is required (l_release_channel_prefix)."
      exit 1
   fi
   if [[ -z "$l_candidate_channel_prefix" ]]; then
      >&2 echo "Error: Channel-name prefix for pre-release versions is required (l_candidate_channel_prefix)."
      exit 1
   fi

   if [[ -z "$l_image_key_mappings" ]]; then
      >&2 echo "Error: At least one image-name-to-key mapping is required (l_image_key_mappings)."
      exit 1
   fi

   #--- Done with input var validation ---


   # Determine if this is a RC or release build and come up with a "clean" release number
   # that omits any iteration number.  The release vs RC determination is used to establish
   # the channel on which this bundle is to be published.

   if [[ $l_bundle_vers == *"-"* ]]; then
      local is_candidate_build=1
   else
      local is_candidate_build=0
   fi
   local this_rel_nr=${l_bundle_vers%-*}  # Remove [-iter] if present.

   local rel_x rel_y rel_z rel_xy rel_yz prev_rel_y prev_rel_z prev_rel_xy
   parse_release_nr "$l_bundle_vers"  # Sets rel_x, rel_y, etc.

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

      local replaces_rel_nr=""
      local skip_range=""
      local specify_default_channel=1

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

      local replaces_rel_nr=""
      local skip_range=">=$rel_x.$prev_rel_y.0 <$rel_x.$rel_y.0"
      local specify_default_channel=1

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

      local specify_default_channel=0
      local replaces_rel_nr="$rel_x.$rel_y.$prev_rel_z"

      if [[ "$rel_x" -le 2 ]] && [[ "$rel_y" -lt 2 ]]; then
         local skip_range=""
      else
         local skip_range=">=$rel_x.rel_y.0 <$rel_x.$rel_y.$rel_z"
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

      local specify_default_channel=0
      local replaces_rel_nr="$rel_x.$rel_y.$prev_rel_z"

      if [[ "$rel_x" -le 2 ]] && [[ "$rel_y" -lt 2 ]]; then
         local skip_range=">=$rel_x.$prev_rel_y.0 <$rel_x.$rel_y.0"
      else
         local skip_range=">=$rel_x.$prev_rel_y.0 <$rel_x.$rel_y.$rel_z"
      fi

      echo "Release $this_rel_nr is a patch release of follow-on in-maj-version feature release $rel_x.$rel_y."
      # echo "The bundle will have a replaces property specifying: $replaces_rel_nr."
      # echo "The bundle will have a skip-range annotation specifying: $skip_range"

   fi

   if [[ $suppress_all_repl_graph_properties -eq 0 ]]; then
      if [[ -n "$l_explicit_prev_csv_vers" ]]; then
         echo "NOTE: Explicitly-specified previous release number is being used."
         replaces_rel_nr=$l_explicit_prev_csv_vers
      fi
   fi

   # Random notes on replacement-chain approach for upstream snapshots:
   #
   # If we're going to build and publish a sequence of snapshots/release candidates and
   # want then to be upgradeable from one to the next, we'll need to:
   #
   # - Create a unique bundle version for each, perhaps by decoaring the $this_rel_nr
   #   with some suffix to create bundle version (eg. l_bundle_vers="$this_rel_nr-$seq_nr".
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

   local manifest_file="$top_of_repo/image-manifests/$this_rel_nr.json"
   local unbound_pkg_dir="$top_of_repo/operator-bundles/unbound/$l_pkg_name"
   local bound_pkg_dir="$top_of_repo/operator-bundles/bound/$l_pkg_name"


   # Generate channel names using this strategy:
   #
   # For a given feature release "x.y" (eg. 1.0, 2.0, 2.1), we maintain two channels as follows.
   #
   # - The published-release channel "<l_release_channel_prefix>-x.y" (eg. release-2.0):
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

   local feature_release_channel="$l_release_channel_prefix-$rel_xy"
   local feature_release_rc_channel="$l_candidate_channel_prefix-$rel_xy"

   if [[ $is_candidate_build -eq 1 ]]; then
      local publish_to_channel="$feature_release_rc_channel"
   else
      local publish_to_channel="$feature_release_channel"
   fi

   local default_channel=""
   if [[ -n "$l_explicit_default_channel" ]]; then
      default_channel="$l_explicit_default_channel"
   elif [[ $specify_default_channel -eq 1 ]]; then
      default_channel="$feature_release_channel"
   fi
   if [[ -n "$default_channel" ]]; then
      local dash_lower_d_opt=("-d" "$default_channel")
   fi

   # Form the previous-bundle arg and/or skip-range and/or skip args if appropraite
   # unless we're skipping all replacement-graph stuff.

   if [[ $suppress_all_repl_graph_properties -eq 0 ]]; then

      local dash_lower_p_opt=()
      if [[ -n "$replaces_rel_nr" ]]; then
         dash_lower_p_opt=("-p" "$replaces_rel_nr")
      fi
      local dash_lower_k_opt=()
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

      local dash_upper_k_opts=()
      for skip in $l_skip_list; do
         dash_upper_k_opts+=("-K" "$skip")
      done

   else
      echo "NOTE: All replacement-graph-related properties are being suppressed for the CSV/bundle."
      local dash_lower_p_opt=()
      local dash_lower_k_opt=()
      local dash_upper_k_opts=()
   fi

   # Convert list of image-key-mappings to corresponding list of -i arguments:
   local dash_lower_i_opts=()
   for m in "${l_image_key_mappings[@]}"; do
      dash_lower_i_opts+=("-i" "$m")
   done

   # Do the same kind of conversion for the list of add-image-ferfs-to container specs:
   local dash_lower_e_opts=()
   for c in "${l_image_ref_containers[@]}"; do
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

   local rgy_and_ns_override="$OCM_BUILD_IMAGE_RGY_AND_NS"
   local pin_using_tag_override="$OCM_BUILD_BUNDLE_GEN_PIN_TO_TAG"

   local dash_lower_r_opts=()
   if [[ -n "$rgy_and_ns_override" ]]; then
      # Assume the image manifest will be using quay.io/open-cluster-management
      # and map from tha tto what is mentioned in the env var.
      dash_lower_r_opts+=("-r" "quay.io/open-cluster-management:$rgy_and_ns_override")
   fi
   local dash_lower_t_opt=()
   if [[ -n "$pin_using_tag_override" ]]; then
      dash_lower_t_opt=("-t" "$pin_using_tag_override")
   fi

   # Enough setup.  Lets to this...
   echo ""
   echo "----------------------------------------------------------------------------"
   echo "Generating bound bundle manifests for package: $l_pkg_name"
   echo "  For CSV/bundle version: $l_bundle_vers"
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
      echo "  Skipping specific previous CSV/bundle versions: $l_skip_list"
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
   else
      echo "  Pinning all image references to image digests"
   fi
   echo "  From uUnbound bundle manifests in: $unbound_pkg_dir"
   echo "  Writing bound bundle manifests to: $bound_pkg_dir"
   echo "  Using image manifests file: $manifest_file"
   echo "----------------------------------------------------------------------------"
   echo ""
   $my_dir/gen-bound-bundle.sh \
      -n "$l_pkg_name" -v "$l_bundle_vers" \
      -c "$publish_to_channel" "${dash_lower_d_opt[@]}" \
      "${dash_lower_p_opt[@]}" "${dash_lower_k_opt[@]}" "${dash_upper_k_opts[@]}" \
      "${dash_lower_r_opts[@]}" "${dash_lower_t_opt[@]}"  \
      -I "$unbound_pkg_dir" -O "$bound_pkg_dir" -m "$manifest_file" \
      "${dash_lower_i_opts[@]}" "${dash_lower_e_opts[@]}"
}

