#!/bin/bash
#
# Finds the installation of the ACM/OCM Hub on this cluster if installed,
# or the namespace running the operator if there is no Hub instance yet.
#
# Depends on:
# - The GVK of the Hub CRD (for finding it if is defined)
# - The olm.providedAPIs annotation  in OperatorGroups (for finding the operator namespace)
#
# Reporting results:
#
# Exit code 0:
# - A hub is installed. Stdout identifies the Hub CR as <namespace>/<name>.
#
# Exit code 1:
# - A hub is not instaleld, but the operator is.  Stdout identifies the
#   operator namespace as <namespace>.
#
# Exit code 2:
# - Operator is not installed.
#
# Exit code 3:
# - Unexpcted situation detected:
#   + Multiple instances of Hub CRD
#   + Multiple instance of Hub resource
#
# Requires:
# - jq

mch="multiclusterhubs"
ocm="open-cluster-management.io"

temp_file="./temp.file"

# Get the ACM/OCM Hub CRD that is defined, indicating the ACM operator is installed.

oc get CustomResourceDefinitions -o name | grep $mch | grep $ocm > $temp_file
cnt=$(wc -l $temp_file | cut -d' ' -f1)

if [[ $cnt -eq 0 ]]; then
   >&2 echo "ACM/OCM Hub operator is not installed (CRD not found)."
   rm -f $temp_file
   exit 2
elif [[ $cnt -gt 1 ]]; then
   >&2 echo "Error: Multiple instances of ACM/OCM Hub CRD were found."
   exit 3
fi
crd=$(cat $temp_file)

# See if we find an instance of the MCH kind.  IF so, ACM/OCM Hub is installed.

oc get $crd -o json > $temp_file
kind=$(cat $temp_file | jq -r ".spec.names.kind")
group=$(cat $temp_file | jq -r ".spec.group")
versions=$(cat $temp_file | jq -r ".spec.versions[].name")
mch_kg="$kind.$group"

oc get $mch_kg -A -o json > $temp_file
cnt=$(cat $temp_file | jq '.items|length')

if [[ $cnt -eq 1 ]]; then
   cat $temp_file | jq -r '.items[] | .metadata.namespace + "/" + .metadata.name'
   rm -f $temp_file
   exit 0
elif [[ $cnt -gt 1 ]]; then
   >&2 echo "Error: Multiple instances of ACM/OCM Hub resource were found."
   exit 3
fi

# No Hub instances.  Find the operator namespace instead.

# First, determine all of the Kind-Version-Groups to look (from the CRD) as that
# is the way OLM keeps track of provided APIs in Operator Groups.

look_for=""
for vers in $versions; do
   kvg="$kind.$vers.$group"
   look_for="$look_for $kvg"
done
# echo "Look for: $look_for"


# Given the CRDs to look for, we find the namespace the operator is in by looking through
# all of the (OLM-maintained) OperatorGroups, looking for one that indicates it provides
# the Hub CRD (by matching Kind-Version-Group).

# Start by finding all the OperatorGroups.

ogs=$(oc get og -A -o json | jq -r '.items[] | .metadata.namespace + "/" + .metadata.name')
for og in $ogs; do
   og_ns=${og%%/*}
   og_name=${og#*/}
   # echo "Checking: $og_ns/$og_name:"

   oc -n $og_ns get OperatorGroup/$og_name -o json > $temp_file
   provided_apis_str=$(cat $temp_file | jq -r '.metadata.annotations["olm.providedAPIs"]')
   if [[ "$provided_apis_str" != "null" ]]; then
      oldIFS=$IFS
      IFS=","
      provided_apis=($provided_apis_str)
      IFS=$oldIFS

      for api in "${provided_apis[@]}"; do
         # echo "   API: $api"
         for check_api in $look_for; do
            if [[ "$api" == "$check_api" ]]; then
               operator_ns="$og_ns"
               break
            fi
         done
         [[ -n "$operator_ns" ]] && break
      done
      [[ -n "$operator_ns" ]] && break
   fi
done

rm -f "$temp_file"

if [[ -n "$operator_ns" ]]; then
   echo "$operator_ns"
   exit 1
fi

# We found the Hub CRD, but not any Operator Group porividng its API. This could be
# because the operator was installed and then its subscription/CSV deleted, as OLM
# "leaks" the CRDs in this case.  We'll assume that.

>&2 echo "ACM/OCM Hub operator is not installed (CRD found, but no Operator Group providing it)."
exit 2

