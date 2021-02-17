#!/bin/bash
#
# This script takes an unbound operator bundle as input, and produces a bound operator
# bundle as output. The "binding" action consists of editing the bundle's CSV to replace
# placeholder image references with actual image refernces (based an image manifest file),
# and establishing establising the bundle's/CSV final version and replaced bundle/CSV
# attributes.
#
# Its expect this script would be used as one of the last steps in:
#
# - Generating a bundle image for community/dev use in the upsteam
# - Generating a bundle image for release in the downstream
#
# Conceptually, its key inputs are:
#
# - The unbound bundle directory, containing the CSV and all related CRD or other
#   manifests to be published together as part of the final operator bundle.
#
# - A image-manifest JSON file that containes properties for all of the images of the
#   product (key, registry server and namespace, repo name, image digest).  This file
#   is used to override the placeholder image references in the CSV to bind the CSV to
#   particular image instances.
#
# - Version info for the operator bundle release being generated.
#
# - Version number of the previous operator bundle release within the same package that
#   is to be considered replaced by this release, if any.
#
# Notes:
#
# - This script (actually the underlying Python it calls) generates the bound boundle
#   in bundle-image format with manifests and metadata subdirectories per that format.
#
#   In addition, consisent with the older App Repository format, it puts that bundle
#   under a package directory with a package.yaml, and maintains chennel entries in
#   that package.yaml.  We do that as a possible way of trakcing some needed state
#   (eg. the name of the previously published CSV version). Maybe doing it this way
#   would also be useful down the road when we publish a community version of the
#   operator, which seems (as of this writing anyway) to want this format.
#
# Cautions:
#
# - Tested only on RHEL 8, not on other Linux nor Mac.
#
# Requires:
#
# - readlink
# - Python 3.6 (for underlying scripts that do the real work)

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))

#--- Args ---

# -I Pathname of source (Input) package (or bundle).
# -O Pathname of (Output) package directory into which generated bundle is written.
# -n Package Name.
# -v Version (x.y.z) of generated bundle.
# -p version of Previous bundle/CSV to be replaced by this one (optional).
# -k Skip-range specification for this bundle (optional)
# -K Specific previous bundle/CSV versions to skip (Optionial, can be repeated)
# -m pathname of image Manifest file.
# -d Default channel name.
# -c Additional Channel name (can be repeated).
# -i Image key mapping spec (can be repeated).
# -r rgy-and-ns override spec (can be repeated).

opt_flags="I:O:n:v:p:k:K:m:d:c:i:r:"

while getopts "$opt_flags" OPTION; do

   if [[ $OPTARG == "-"* ]]; then
      # We don't expect any option args that start with a dash, so getopt is likely
      # consuming the next option as if it were this options argument because the
      # argument is missing in the invocation.

      >&2 echo "Error: Argument for -$OPTION option is missing."
      exit 1
   fi

   case "$OPTION" in
      I) unbound_pkg_dir="$OPTARG"
         ;;
      O) bound_pkg_dir="$OPTARG"
         ;;
      n) pkg_name="$OPTARG"
         ;;
      v) new_csv_vers="$OPTARG"
         ;;
      p) prev_csv_vers="$OPTARG"
         ;;
      k) skip_range="$OPTARG"
         ;;
      K) skip_list="$skip_list $OPTARG"
         ;;
      m) image_manifest="$OPTARG"
         ;;
      d) default_channel="$OPTARG"
         ;;
      c) additional_channels="$additional_channels $OPTARG"
         ;;
      i) image_name_to_keys="$image_name_to_keys $OPTARG"
         ;;
      r) rgy_ns_overrides="$rgy_ns_overrides $OPTARG"
         ;;
      ?) exit 1
         ;;
   esac
done
shift "$(($OPTIND -1))"

if [[ -z "$unbound_pkg_dir" ]]; then
   >&2 echo "Error: Source/input package directory pathname not specified (-I)."
   exit 1
fi
if [[ -z "$bound_pkg_dir" ]]; then
   >&2 echo "Error: Output package directory pathname not specified (-O)."
   exit 1
fi
if [[ -z "$pkg_name" ]]; then
   >&2 echo "Error: Bundle package name not specified (-n)."
   exit 1
fi
if [[ -z "$new_csv_vers" ]]; then
   >&2 echo "Error: New bundle/CSV version not specified (-v)."
   exit 1
fi
if [[ -z "$image_manifest" ]]; then
   >&2 echo "Error: Image manifest file pathanem not specified (-m)."
   exit 1
fi
if [[ -z "$additional_channels" ]]; then
   >&2 echo "Error: At least one to-be-added-to package channel name is required (-c)."
   exit 1
fi
if [[ -z "$image_name_to_keys" ]]; then
   >&2 echo "Error: At least one image-name-to-key mapping is required (-i)."
   exit 1
fi
if [[ -z "$prev_csv_vers" ]]; then
   >&2 echo "Note: No previous/replaced bundle/CSV version specified (-p)."
fi

#--- Done with Args (Thank goodness) ---


mkdir -p "$bound_pkg_dir"

# Ensure the specified input and output directories for the budnles exist.

if [[ ! -d $unbound_pkg_dir ]]; then
   >&2 echo "Error: Input package directory $unbound_pkg_dir doesn't exist."
   >&2 echo "Aborting."
   exit 2
fi

if [[ ! -d $bound_pkg_dir ]]; then
   >&2 echo "Error: Output package directory $bound_pkg_dir doesn't exist."
   >&2 echo "Aborting."
   exit 2
fi

# The following use of package.yaml is related to an old thought of using that
# package-level file to hold the state as to the current (last-released) version
# in each channel.  This idea was never really fleshed out and put into production
# use.  This vertigal stuff slows things done and causes wrong results in dev testing
# use cases, so we're disabling it.

# if [[ -f $unbound_pkg_dir/package.yaml ]]; then
#    unbound_bundle=$($my_dir/find-bundle-dir.py "latest" $unbound_pkg_dir)
#    if [[ $? -ne 0 ]]; then
#       >&2 echo "Error: Could not find source bundle directory for unbound ACM bundle."
#       >&2 echo "Aborting."
#       exit 2
#    fi
# else
#    # Lets guess we were given a bundle directory rather than a package directory.
#    unbound_bundle=$unbound_pkg_dir
# fi
unbound_bundle="$unbound_pkg_dir/$new_csv_vers"

name_to_key_options=""
for ink in $image_name_to_keys; do
   name_to_key_options="$name_to_key_options --image-name-to-key $ink"
done

rgy_ns_override_options=""
for rno in $rgy_ns_overrides; do
   rgy_ns_override_options="$rgy_ns_override_options --rgy-ns-override $rno"
done

# If a previous CSV versioin has been specified, pass it on.
if [[ -n "$prev_csv_vers" ]]; then
   prev_vers_option="--prev-ver $prev_csv_vers"
fi

# If a skip-range has been specified, pass it on.

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

   skip_range_option=("--skip-range" "$skip_range")
fi

skip_options=""
for skip in $skip_list; do
   skip_options="$skip_options --skip $skip"
done

# If default channel is specified, pass it on.
if [[ -n "$default_channel" ]]; then
   default_channel_option="--default-channel $default_channel"
fi

# Form additional-channel options from the additiona_channels list:
addl_channel_optons=""
for c in $additional_channels; do
   addl_channel_options="$additional_channel_options --additional-channel $c"
done

# Channel stuff:
#
# We build the output bundle in (what we'll call) bundle-image format.
#
# This format asks for metadata regarding the channels on which this bundle release
# is to be posted as the current version.
#
#
# As mentioned in prolog comments, the create-bound-bundle script maintains channel
# info in a package.yaml manifest as it appears to be used in App Repository type
# bundles.

$my_dir/create-bound-bundle.py \
   --image-manifest "$image_manifest" \
   --pkg-name "$pkg_name" --pkg-dir "$bound_pkg_dir" \
   --source-bundle-dir "$unbound_bundle" \
   --csv-vers "$new_csv_vers" $prev_vers_option \
   $skip_options \
   ${skip_range_option:+"${skip_range_option[@]}"}  \
   --use-bundle-image-format \
   --add-related-images \
   $default_channel_option $addl_channel_options \
   $name_to_key_options $rgy_ns_override_options

