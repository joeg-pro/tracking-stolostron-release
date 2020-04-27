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
#   In addition, consisent with the older APP Repository format, it puts that bundle
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
# - jq (for parsing the image manifest file)

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))

tmp_root="/tmp/gen-acm-bundle"

#--- Args (Ugh) ---

# -I Pathname of source (Input) package (or bundle).
# -O Pathname of (Output) package directory into which generated bundle is written.
# -n Package Name.
# -v Version (x.y.z) of generated bundle.
# -p version of Previous bundle/CSV replaced by the generated on (optional).
# -m pathname of image Manifest file.
# -d Default channel name.
# -c Additional Channel name (can be repeated).
# -i Image override spec (can be repeated).

opt_flags="I:O:n:v:p:m:d:c:i:"

while getopts "$opt_flags" OPTION; do
   case "$OPTION" in
      I) unbound_pkg_dir="$OPTARG"
         echo "I: $unbound_pkg_dir"
         ;;
      O) bound_pkg_dir="$OPTARG"
         echo "O: $bound_pkg_dir"
         ;;
      n) pkg_name="$OPTARG"
         echo "n: $pkg_name"
         ;;
      v) new_csv_vers="$OPTARG"
         echo "v: $new_csv_vers"
         ;;
      p) prev_csv_vers="$OPTARG"
         echo "p: $prev_csv_vers"
         ;;
      m) image_manifest="$OPTARG"
         echo "m: $image_manifest"
         ;;
      d) default_channel="$OPTARG"
         echo "d: $default_channel"
         ;;
      c) additional_channels="$additional_channels $OPTARG"
         echo "c: $additional_channels"
         ;;
      i) image_keys_and_repos="$image_keys_and_repos $OPTARG"
         echo "i: $image_keys_and_repos"
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
if [[ -z "$default_channel" ]]; then
   >&2 echo "Error: Default package channel name not specified (-d)."
   exit 1
fi
if [[ -z "$additional_channels" ]]; then
   >&2 echo "Error: At least one to-be-added-to package channel name not specified (-c)."
   exit 1
fi
if [[ -z "$image_keys_and_repos" ]]; then
   >&2 echo "Error: At least one image-replacement-spec not specified (-i)."
   exit 1
fi
if [[ -z "$prev_csv_ver" ]]; then
   >&2 echo "Note: No previous/replaced bundle/CSV version specified (-p)."
fi

#--- Doe with Args (Thank goodness) ---


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

if [[ -f $unbound_pkg_dir/package.yaml ]]; then
   unbound_bundle=$($my_dir/find-bundle-dir.py "latest" $unbound_pkg_dir)
   if [[ $? -ne 0 ]]; then
      >&2 echo "Error: Could not find source bundle directory for unbound ACM bundle."
      >&2 echo "Aborting."
      exit 2
   fi
else
   # Lets guess we were given a bundle directory rather than a package directory.
   unbound_bundle=$unbound_pkg_dir
fi

# Form image-override specificatoins for each image we expect in the CSV based on
# the list of expected overrides defined by $image_keys_and_repos and stuff in the
# image manifest file.
#
# Each whitespace-separated entry in $image_keys_and_repos is a spec of the form:
#
#    <image_key_In_manifest>:<image_name_expected_in_csv>
#
# Where <image_key_in_manifest> is a value we expect to see as the "image-key" property
# in the image manifest, and <image_name_in_csv> is the expected "placeholder" we expect
# to have been used for the image (more correctly, repository) name in image references
# in the install/deployment info in the CSV.
#
# We use <image_key_in_manifest> to find the image's entry in the manfest, and then use
# the various fileds in that entry to form the image-override option we pass to the
# create-unbound-bundle script.

override_options=""
for ikr in $image_keys_and_repos; do

   img_name_in_csv=${ikr#*:}
   img_key=${ikr%:*}

   entry=$(jq -c ".[] | select(.\"image-key\"==\"$img_key\")" "$image_manifest")
   if [[ -z $entry ]]; then
      >&2 echo "Error: Could not find entry for image key \"$img_key\" in image manifest."
      >&2 echo "Aborting."
      exit 2
   fi

   # Some more advanced JQ wizardry could maybe make this happen in a single JQ transform,
   # but having somethign that works beats not having anything at all by a mile. And for
   # sure efficiency is not an important consideration here. So...

   ir_remote=$(echo "$entry" | jq -r ".\"image-remote\"")
   ir_name=$(echo "$entry" | jq -r ".\"image-name\"")
   ir_digest=$(echo "$entry" | jq -r ".\"image-digest\"")
   ir_tag_or_digest="@$ir_digest"

   replacement_img_ref="$ir_remote/$ir_name$ir_tag_or_digest"

   # The image-override option specifies a replacement in the form:
   #
   #    <image_name_expected_in_csv>:<full_replacement_image_ref>

   override_opt="--image-override $img_name_in_csv:$replacement_img_ref"
   override_options="$override_options $override_opt"
done

# If a previous CSV versioin has been specified, pass it on.
if [[ -n "$prev_csv_vers" ]]; then
   prev_vers_option="--prev-ver $prev_csv_vers"
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
   --use-bundle-image-format \
   --pkg-name "$pkg_name" --pkg-dir "$bound_pkg_dir" \
   --source-bundle-dir "$unbound_bundle" \
   --csv-vers "$new_csv_vers" \
   $prev_vers_option \
   --default-channel $default_channel \
   $addl_channel_options \
   $override_options

