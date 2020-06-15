#!/bin/bash
#
# Upgrades an operator to the next-pending CSV.
#
# Currently hardcodes some ACM specific stuff, eg. subscription name.
#
# Requires:
# - oc
# - jq
#
# Assumes:
#
# - An OLM subscription called acm-operator-subscription already exists
#   from a "baseline" install.
#
# Blame: joeg-pro (for the original versions, anyway)
#
# Notes:
#
# - Tested in RHEL 8, not on other Linux or Mac.
#
# - Currently coded as specific to assorted OCM/ACM engineering team practices and
#   targetting the ACM operator package, but the approach demonstrated here is general.

me=$(basename $0)
my_dir=$(dirname $(readlink -f $0))

temp_file="./tmp.file"

target_ns="ocm"
operator_subscription="acm-operator-subscription"

source $my_dir/common-functions

the_subscription="subscriptions.operators.coreos.com/$operator_subscription"

# Find the existing operator subscription and see if it has an upgrade pending.
# Complain (and abort) and die if it doesn't.  Approve it if found.
find_and_approve_install_plan $the_subscription
# Sets "the_install_plan"

# OLM should be off and running now (or soon).
# Wait for OLM to get done with the install plan (Complete status).
wait_for_install_plan_complete $the_install_plan
echo "Install plan is now Complete."

# So just to be sure, we wait for the CSV to finishing installing.
wait_for_csv_to_succeed $the_subscription

# We're done wiht this next-step upgrade, but lets report on any next-pending updates.
report_on_subscritpion_ending_status $the_subscription

rm -f $temp_file

