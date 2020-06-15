#!/bin/bash
#
# Installs an operator at a specified version.  Currently ACM specific.
#
# Requires:
# - oc
# - jq
#
# Assumes:
#
# - A Catalog Source called "acm-custom=-registry" is already defined.
#
# Blame: joeg-pro (for the original versions, anyway)
#
# Notes:
#
# - Tested in RHEL 8, not on other Linux or Mac.
#
# - Currently specific to assorted OCM/ACM engineering team practices and
#   targetting the ACM operator package, but the approach demonstrated here
#   is general.

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))

temp_file="./tmp.file"

operator_release="$1"

if [[ -z $operator_release ]]; then
   >&2 echo "Operator release id is required."
   exit 1
fi

target_ns="ocm"
operator_package="advanced-cluster-management"
subscribe_to_channel="release-1.0"
source_catalog="acm-custom-registry"

source $my_dir/common-functions


# Create namespace(s)...

oc_apply << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $target_ns
EOF
wait_for_resource namespace/$target_ns
set_use_ns "$target_ns"
wait_for_resource serviceaccount/default

# Create Operator Group...

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
  name: acm-operator-subscription
  namespace: $target_ns
spec:
  name: $operator_package
  source: $source_catalog
  installPlanApproval: Manual
  channel: $subscribe_to_channel
  sourceNamespace: $target_ns
  startingCSV: advanced-cluster-management.v$operator_release
EOF

# NOTE:
# Usually the simple kind name "subscription" or abbreviation "sub" will refer to an
# OLM Subscription resource. But after installing the OCM App Sub CRD, it takes over that
# simple kind-name/abbrev, thus breaking stuff that expects those to be OLM resources.

the_subscription="subscriptions.operators.coreos.com/acm-operator-subscription"
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

