#!/bin/bash
#
# Installs an operator at a specified version.
#
# The approach shown here is general, but this script currently includes
# some ACM specific stuff, at least as defaults:
#
# - Operator package name
# - Operator update channel
# - Catalog source name
# - CSV naming convention
#
# Requires:
# - oc
# - jq
#
# Assumes:
#
# - Custom catalog Source (default: "acm-custom=-registry") is already defined.
#
# Blame: joeg-pro (for the original versions, anyway)
#
# Notes:
#
# - Tested in RHEL 8, not on other Linux or Mac.

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))

source $my_dir/common-functions

# --- Arg Parsing ---

# -n target Namespace (default: current project/namespace).
# -p Package name (default: advanced-cluster-management).
# -c Channel name (default: release channel for specified operator release).
# -s Subscription name (default: acm-operator-subscription).
# -S catalog Source name (default: acm-custom-registry).
# -N catalog source Namespace (default: same as target (-n) namespace).

opt_flags="n:p:c:s:S:N:"

while getopts "$opt_flags" OPTION; do
   case "$OPTION" in
      n) target_ns="$OPTARG"
         ;;
      p) operator_package="$OPTARG"
         ;;
      c) subscribe_to_channel="$OPTARG"
         ;;
      s) subscription_name="$OPTARG"
         ;;
      S) catalog_source="$OPTARG"
         ;;
      N) catalog_source_ns="$OPTARG"
         ;;
      ?) exit 1
         ;;
   esac
done
shift "$(($OPTIND -1))"

operator_release="$1"
if [[ -z $operator_release ]]; then
   >&2 echo "Operator release id is required."
   exit 1
fi

# --- Arg Defaulting ---

if [[ -z "$garget_ns" ]]; then
   target_ns=$(oc_get_default_namespace)
   echo "Using default project namespace: $target_ns"
fi

operator_package="${operator_package:-advanced-cluster-management}"
subscription_name="${subscription_name:-acm-operator-subscription}"
catalog_source="${catalog_source:-acm-custom-registry}"
catalog_source_ns="${catalog_source_ns:-$target_ns}"

# No option to override yet, but prepare for one:
csv_name_prefix="${csv_name_prefix:-$operator_package}"

# If not specified, use a default channel based on release number.
if [[ -z "$subscribe_to_channel" ]]; then
   oldIFS=$IFS
   IFS=. rel_xyz=(${operator_release%-*})
   rel_x=${rel_xyz[0]}
   rel_y=${rel_xyz[1]}
   rel_z=${rel_xyz[2]}
   IFS=$oldIFS
   subscribe_to_channel="release-$rel_x.$rel_y"
fi

# --- End Args ---

# Our normal dev/test procedure is to use a custom registry, which we typically put in
# the same namespace in which the operator will be installed (and our defaulting of
# optoinal args is in line with this practice). So the target naemspace will usually
# already exsits. But to allow other use cases, we'll create the target namespace
# here if it isn't around already.

oc_apply << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $target_ns
EOF
wait_for_resource namespace/$target_ns
set_use_ns "$target_ns"
wait_for_resource serviceaccount/default

# OLM only tolerates one OperatorGroup per namespace.  So create on if we don't
# find any.  Otherwise, assume/home its right for us.

ogs=$(oc_cmd get OperatorGroups -o name)
if [[ -z "$ogs" ]]; then
   oc_apply << EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: operator-group
  namespace: $target_ns
spec:
  targetNamespaces:
  - $target_ns
EOF
   wait_for_resource operatorgroup/operator-group
fi

# Create the subscription, with manual approval and a starting-CSV.
#
# Note:
# Its unfortunate that this subscription has a dependency on the way OCM/ACM CSVs are named
# (i.e. the name is advanced-cluster-management.v.x.y.z) because it seems this naming is
# a matter of convetion rather than requirement.  It would be better if we could ask
# for the CSV simply by its x.y.z version.  But I can't find a way to do that woudlnt
# doing explicit queires of the operator registry, which might not be exposed outsde of
# the cluster.

echo "Applying subscription acm-operator-subscription for operator version $operator_release."
oc_apply << EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $subscription_name
  namespace: $target_ns
spec:
  installPlanApproval: Manual
  name: $operator_package
  channel: $subscribe_to_channel
  startingCSV: $csv_name_prefix.v$operator_release
  source: $catalog_source
  sourceNamespace: $catalog_source_ns
EOF

# NOTE:
# Usually the simple kind name "subscription" or abbreviation "sub" will refer to an
# OLM Subscription resource. But after installing the OCM App Sub CRD, it takes over that
# simple kind-name/abbrev, thus breaking stuff that expects those to be OLM resources.

the_subscription="subscriptions.operators.coreos.com/$subscription_name"
wait_for_resource $the_subscription

# Since the Subscription has a Manual install-plan approval policy, we're
# should find it in Upgrade-Pending waiting for action on the related
# install plan.  Wait until we see the Subscription in that state.

wait_for_resource_status $the_subscription subscription_is_upgrade_pending "Upgrade-Pending"
echo "Subscription created/exists and is now Upgrade-Pending."

# Find and approve the install plan so the operator installs.
find_and_approve_install_plan $the_subscription

# Wait for OLM to get done with the install plan (Complete status).
wait_for_install_plan_complete $the_install_plan
wait_for_resource_status $the_install_plan install_plan_is_complete "Complete" 60
echo "Install plan is now Complete."

# Notes:
#
# At this point in the action, the install plan probably looks like:
#
# kind: InstallPlan
# spec:
#   approval: Manual
#   approved: true
#   clusterServiceVersionNames:
#   - etcdoperator.v0.9.4
#   - advanced-cluster-management.v1.0.0
#   generation: 1
# status:
#   catalogSources:
#   - community-operators
#   - acm-custom-registry
#   conditions:
#   - lastTransitionTime: "2020-06-10T22:53:25Z"
#     lastUpdateTime: "2020-06-10T22:53:25Z"
#     status: "True"
#     type: Installed
#  phase: Complete
#
# While the Subscription might be indicating there are pending upgrades:
#
# kind: Subscription
# status:
#   currentCSV: advanced-cluster-management.v1.0.1
#  installPlanGeneration: 2
#  installPlanRef:
#    apiVersion: operators.coreos.com/v1alpha1
#    kind: InstallPlan
#    name: install-ps882
#    namespace: ocm
#    resourceVersion: "164884"
#    uid: 58ae05f6-d291-4cc1-a038-77b05c7e273d
#  installedCSV: advanced-cluster-management.v1.0.0
#  installplan:
#    apiVersion: operators.coreos.com/v1alpha1
#    kind: InstallPlan
#    name: install-ps882
#    uuid: 58ae05f6-d291-4cc1-a038-77b05c7e273d
#  lastUpdated: "2020-06-10T22:53:08Z"
#  state: UpgradePending
#
# With the install plan marked complete, you'd think that might mean that
# the CSV is also installed now too.  But typically, its not and at this
# point might be:
#
# kind: ClusterServiceVersion
# status:
#   conditions:
#   - lastTransitionTime: "2020-06-11T19:24:38Z"
#     lastUpdateTime: "2020-06-11T19:24:38Z"
#     message: requirements not yet checked
#     phase: Pending
#     reason: RequirementsUnknown
#   - lastTransitionTime: "2020-06-11T19:24:38Z"
#     lastUpdateTime: "2020-06-11T19:24:38Z"
#     message: one or more requirements couldn't be found
#     phase: Pending
#     reason: RequirementsNotMet
#   - lastTransitionTime: "2020-06-11T19:24:46Z"
#     lastUpdateTime: "2020-06-11T19:24:46Z"
#     message: all requirements found, attempting install
#     phase: InstallReady
#     reason: AllRequirementsMet
#   - lastTransitionTime: "2020-06-11T19:24:49Z"
#     lastUpdateTime: "2020-06-11T19:24:49Z"
#     message: waiting for install components to report healthy
#     phase: Installing
#     reason: InstallSucceeded
#   - lastTransitionTime: "2020-06-11T19:24:49Z"
#     lastUpdateTime: "2020-06-11T19:24:51Z"
#     message: |
#       installing: waiting for deployment multiclusterhub-operator to become ready: Waiting for rollout to finish: 0 of 1 updated replicas are available...
#     phase: Installing
#     reason: InstallWaiting
#   lastTransitionTime: "2020-06-11T19:24:49Z"
#   lastUpdateTime: "2020-06-11T19:24:51Z"
#   message: |
#     installing: waiting for deployment hive-operator to become ready: Waiting for rollout to finish: 0 of 1 updated replicas are available...
#   phase: Installing
#   reason: InstallWaiting

# So just to be sure, we wait for the CSV to finishing installing.
wait_for_csv_to_succeed $the_subscription

# We're done wiht the install, but lets report on any pending updates.
report_on_subscritpion_ending_status $the_subscription

rm -f $temp_file

