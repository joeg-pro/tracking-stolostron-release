#!/bin/bash
# Bash, but source me, don't run me.
if ! (return 0 2>/dev/null); then
   >&2 echo "Error: $(basename $0) is intended to be sourced, not run."
   exit 5
fi

function parse_version {
   # Parses a version number and Sets rel_x, rel_y. etc. variables.

   if [[ -z "$1" ]]; then
      >&2 echo "Error: Bundle version (x.y.z[-iter]) is required."
      exit 5
   fi

   old_IFS=$IFS
   IFS=. rel_xyz=(${1%-*})
   rel_x=${rel_xyz[0]}
   rel_y=${rel_xyz[1]}
   rel_z=${rel_xyz[2]}
   IFS=$old_IFS

   rel_yz="$rel_y.$rel_z"
}


