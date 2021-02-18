#!/bin/bash

# Cover script that redirects to release-specific version of script assumed
# to be  named like this one (with  a release-qualifier suffix) and that lives
# in the same directory as this one.
#
# Assumes:
# - The script name(s) ends with a ".sh" suffix.
#
# Note: This simple-minded redirect works because the underlying scripts don't
# have any getopt options to worry about.

me=${0##*/}
me_pfx=${0%$me}

new_csv_vers="$1"
if [[ -z "$new_csv_vers" ]]; then
   >&2 echo "Error: Bundle version is required."
   exit 1
fi

old_IFS=$IFS
IFS=. rel_xyz=(${new_csv_vers%-*})
rel_x=${rel_xyz[0]}
rel_y=${rel_xyz[1]}
rel_z=${rel_xyz[2]}
IFS=$old_IFS

rel_xy="$rel_x.$rel_y"

if [[ "$rel_x" -ge 2 ]]; then
   # echo "Info: Using release 2.x+ version of bundle generation script."
   rel_qualifier="2.x"
else
   # Catch an unexpected 1.y release
   >&2 echo "Error: Bundle version $new_csv_vers is not expected/understood."
   exit 1
fi

target_script="$me_pfx${me%.sh}-$rel_qualifier.sh"
exec $target_script "$@"

