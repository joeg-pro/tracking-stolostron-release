#!/usr/bin/env bash

# This script is invoked from the donwstream render_templates CPaaS "hook" point
# after cloing the upstream tools repo at a specified commit SHA (to get us,
# other tools and unbound manifests).
#
# It starts execution with the working directory set to be the same directory
# that was CWD when the downstream render_templates started.  We expect to find
# render_vars and package_config vars in that directory to define script vars
# that configure the behavior.
#
# We expect the following environment variables to have been set:
#
# - SCRIPT_CLONE_URL, SCRIPT_CLONE_SHA
# - CPAAS_PRODUCT_VERSION
#
# And we expect there to be a script fragment packge_config_vars that we
# can source to have other needed script variables set:
#
# - script_target_dir
# - package
# - manifest_gen_config_file
# - gen_bound_bundle_script

if [[ ! -f package_config_vars ]]; then
  echo "ERROR: Required package_config_vars config file not found."
  exit 3
fi
source package_config_vars

if [[ -z "$CPAAS_PRODUCT_VERSION" ]]; then
   echo "ERROR: Environment variable CPAAS_PRODUCT_VERSION not defined."
   exit 2
fi

this_rel_nr="$CPAAS_PRODUCT_VERSION"  # Eg. 2.0.0

set -x

# The bundle's openshift.versions label lets us target the per-OCP-release catalogs
# the bundle should be destinated for.  Grab this info from the ocp-versions file.
#
# Note: The versioning scheme available in the openshift versions label accepts:
#
#     Min version (v4.5)
#     Range (v4.5-v4.7)
#     A specific version (=v4.6)

ocp_versions_file="./ocp-versions"
if [[ ! -f "$ocp_versions_file" ]]; then
   echo "ERROR: OCP versions file is not found."
   exit 2
fi
ocp_versions=$(cat "$ocp_versions_file")

# Make sure there are no remnants from previous runs.  This also gets rid of any
# dummy/placehoders in the repo needed to make change-set verificaton pass.

rm -rf manifests metadata extras

# The image manifest script depnends on lots of env vars passed in by CPaSS.
# Catpure what we got as input for use in problem determination and testing.
# (This will get committed into dist-git where it can then be referenced.)

env    > render-templates-input-env-vars
ls -al > render-templates-files

# Currently, operator bundles are delivered in a snapshot tarball, but we might
# change upstream to commit them "in place".  So unpack the snapshot tarball
# if its present.

if [[ -f  CURRENT-SNAPSHOT.tgz ]]; then
   # All we need out of CURRENT_SNAPSHOT is the operator-bundles subtree but
   # it may contain more.  So unack on the side and grab only what we want.
   mkdir tmp.unpack
   tar -C tmp.unpack -xzf CURRENT-SNAPSHOT.tgz
   rm -rf ./operator-bundles
   mv tmp.unpack/operator-bundles .
   rm -rf tmp.unpack
fi

# Make sure we don't pick up an upstream image manfest by accident.
rm -f $script_target_dir/image-manifests/*.json

# Generate image manifest for images built in this downstream build.
#
# This leaves the resulting manifest in the current directory.

python3 -m pip install pyyaml

generate_manifests="./$script_target_dir/tools/downstream-image-manifest-gen/generate_manifest.py"
if [[ ! -f "$generate_manifests" ]]; then
   echo "ERROR: Upstream release repo doesn't have generate_manifests.py"
   echo "Maybe the upstream_sources git SHA is wrong?"
   pwd
   exit 2
fi
$generate_manifests $this_rel_nr "." $manifest_gen_config_file
if [[ $? -ne 0 ]]; then
   echo "ERROR: Could not generate downstream image manifest."
   exit 2
fi

#  Move the image manifest to the image-manifests dir were  the "pinning" script
# (run next) expects it to be.
mv -f $this_rel_nr.json ./$script_target_dir/image-manifests
if [[ $? -ne 0 ]]; then
   echo "ERROR: Could not move downstream image manifest to image-manifests directory."
   exit 2
fi

# Run our "pinning" script that takes the unbound operator bundle we build upstream
# and pins image references using the just-built image manifest.  It create a directory
# of operator bundle material at release/operator-bundles/bound/advanced-cluster-management.
# The stuff here is in an inteional mix of app-registry and bundle-image format studd.

$script_target_dir/tools/bundle-manifests-gen/$gen_bound_bundle_script $this_rel_nr "auto"
if [[ $? -ne 0 ]]; then
   echo "ERROR: Generating bound operator manifests failed."
   exit 2
fi

# Transform our hybrid bundle format into proper image-manifest format.

df="./Dockerfile"
if [[ ! -f "$df" ]]; then
   echo "ERROR: Dockerfile is not yet created by CPAAS so channel labels in it can't be updated."

   # If CPAAS runs render_templates before creating Dockerfile from Dockerfile.in, then
   # we will have to change Dockerfile.in to have the bundle-image-format related labels.
   # One downside is that we will have to maintain the channel-related LABELs by hand
   # since there will be no way to auto-generate them based on upstream-provided
   # annotations.yaml.  Unless we could perform the same surgery on Dockerfile.in?

   exit 2
fi

# Stash away a copy of the Dockerfile as inidially rendered by CPAAS and always start our
# alterations based on that.  This will keep us idempotent in case we're re-run  multiple times
# w/o rendering a fresh Dockerfile first as I guess can be the case if we rerun the build
# pipeline wih no intervening midstream changes.  This does doepend on having the stashed
# copy get deleted out of distget when CPAAS does re-render/reset disgit.

stashed_df="Dockerfile.originally-rendered"
if [[ ! -f $stashed_df  ]]; then
   cp $df $stashed_df
fi
cp $stashed_df $df

rm -rf ./manifests ./metadata
mv $script_target_dir/operator-bundles/bound/$package/$this_rel_nr/manifests .
mv $script_target_dir/operator-bundles/bound/$package/$this_rel_nr/metadata  .

# Start with a set of RH release pipeline labels for bundle-image format:

label_lines="./tmp.label-lines"
rm -f "$label_lines"

echo "LABEL com.redhat.delivery.operator.bundle=true"          >  "$label_lines"
echo "LABEL com.redhat.openshift.versions=\"$ocp_versions\""   > "$label_lines"
echo "" >> "$label_lines"
# Note: When we're no longer trying to be bi-modal, the operator.bundle
# label can probably be in Dockerfile.in, but we might still want to
# insert the openshift.versions label esp if we could figure that out from
# some upstream-provided config?

# Bundle-image format requires some image labels which mirror those we've already
# generated (upstream) as metadata/annotations.yaml, including stuff that relates
# to publication channels. To avoid manual maintenance of stuff downstream, convert
# metadata/annotations.yaml into LABELS. So we:
#
# - Filter out the "annotations:" line
# - Convert all others to LABEL statement

tail -n +2 "./metadata/annotations.yaml" | \
   sed "s/: */=/" | sed "s/^ */LABEL /" >> "$label_lines"

# Use the operator.bundle label line as the anchor for inserting the LABEL lines
# created above since we know there will be such a label.

cat "$df" |\
   sed "/com.redhat.delivery.operator.bundle/r $label_lines" > "./df.upd.tmp"
mv -f "./df.upd.tmp" "$df"
rm -f "$label_lines"

# Grab the image manifest we generaed/used so it can be saved in the image
rm -rf ./extras
mkdir ./extras
mv $script_target_dir/image-manifests/*.json extras

# Done with the release repo, remove so it doesn't get committed into dist-git.
rm -rf $script_target_dir

# As we exit, we've left behind:
#
# ./manifests directory containng this release and previous release bundle material
# ./extras directory containing the downstream-generated image manifest .json for future reference
#
# This container's Dockerfile will pick up those two directories for the image.
#
# Also (for pd):
#
# - render-templates-input-env-vars
# - render-templates-files

