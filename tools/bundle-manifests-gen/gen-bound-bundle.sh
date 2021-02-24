#!/bin/bash
#
# This script takes an unbound operator bundle as input, and produces a bound operator
# bundle as output. The "binding" (sometimes called "pinning") action involves editing
# the CSV to make a number of changes to finalize the bundle, including:
#
# - Replacing placeholder image references with actual image refernces based
#   the image manifest file maintained by the build pipeline
# - Adding related-images information
# - Establishing the bundle's/CSV final version
# - Setting CSV properties that indicate its upgrade handling
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
# - Version numbers of the previous operator bundle release or range of releases that
#   are considered predecessors for which an upgrade to this bundle is allowed.
#
# Notes:
#
# - Requires Bash 4.4 or newer.
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
# -m pathname of image Manifest file.
#
# -n Package Name.
# -v Version (x.y.z) of generated bundle.
#
# -p version of Previous bundle/CSV to be replaced by this one (optional).
# -k Skip-range specification for this bundle (optional)
# -K Specific previous bundle/CSV versions to skip (Optionial, can be repeated)
#
# -d Default channel name (optioinal).
# -c Additional Channel name (optional, can be repeated).
#
# -i Image key mapping spec (can be repeated).
# -r rgy-and-ns override spec (optional, can be repeated).
#
# -E Omit related-images list (optional).
# -e Deployment/container to receive image-ref env vars (optional, can be repeated).
#
# -T Use image tag (as specified in image manifest) rather than digest.
# -t Tag override: Tag used for all images, overriding tag from image manifest.
# -s Tag suffix: Suffix appended to all tags, overriding any suffix from image manifest.
#
# Specifying -t or -s implies the use of tags (-T).

opt_flags="I:O:n:v:p:k:K:m:d:c:i:r:Ee:Tt:s:"

omit_related_images=0

# For collecting options that are basically pass-thru:

add_image_ref_opts=()
addl_channel_opts=()
name_to_key_opts=()
rgy_ns_override_opts=()
skip_opts=()

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
      m) image_manifest="$OPTARG"
         ;;
      p) prev_vers_opt=("--prev-ver" "$OPTARG")
         ;;
      k) skip_range_opt=("--skip-range" "$OPTARG")
         ;;
      K) skip_opts+=("--skip" "$OPTARG")
         ;;
      d) default_channel_opt=("--default-channel" "$OPTARG")
         ;;
      c) addl_channel_opts+=("--additional-channel" "$OPTARG")
         ;;
      r) rgy_ns_override_opts+=("--rgy-ns-override" "$OPTARG")
         ;;
      E) omit_related_images=1
         ;;
      e) add_image_ref_opts+=("--add-image-ref-env-vars-to" "$OPTARG")
         ;;
      i) name_to_key_opts+=("--image-name-to-key" "$OPTARG")
         ;;
      T) use_image_tags_opt="--use-image-tags"
         ;;
      t) tag_override_opt=("--tag-override" "$OPTARG")
         ;;
      s) tag_suffix_opt=("--tag-suffix" "$OPTARG")
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
   >&2 echo "Error: Image manifest file pathname not specified (-m)."
   exit 1
fi
if [[ -z "$addl_channel_opts" ]]; then
   >&2 echo "Error: At least one to-be-added-to package channel name is required (-c)."
   exit 1
fi
if [[ -z "$name_to_key_opts" ]]; then
   >&2 echo "Error: At least one image-name-to-key mapping is required (-i)."
   exit 1
fi
if [[ -z "$prev_csv_vers_opt" ]]; then
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

# Use of add-related-images used to be unconditional, now add it unless
# we've been asked to omit it.

if [[ $omit_related_images -eq 0 ]]; then
   add_related_images_opt="--add-related-images"
fi

$my_dir/create-bound-bundle.py \
   --image-manifest "$image_manifest" \
   --pkg-name "$pkg_name" --pkg-dir "$bound_pkg_dir" \
   --source-bundle-dir "$unbound_bundle" \
   --csv-vers "$new_csv_vers" "${prev_vers_opt[@]}" \
   "${skip_opts[@]}" "${skip_range_opt[@]}" \
   "${default_channel_opt[@]}" "${addl_channel_opts[@]}" \
   "${name_to_key_opts[@]}" "${rgy_ns_override_opts[@]}" \
   $add_related_images_opt "${add_image_ref_opts[@]}" \
   $use_image_tags_opt "${tag_override_opt[@]}" "${tag_suffix_opt[@]}"

