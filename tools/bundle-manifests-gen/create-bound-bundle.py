#!/usr/bin/env python3
# Assumes: Python 3.6+

# Takes an "unbound" CSV bundle abd configures it for a release by:
#
# - Updating CSV version and CSV name (to match version)
# - Removing references to pull secrets in operator deployments
# - Setting the createdAt timestamp
# - Setting publish-to channel specifications
# - Optionally:
#   - Setting the default-channel specification.
#   - Setting the "replaces" property
#   - Setting its skip-range annotation
#   - Customizing image references in several ways, including "binding" (also referred
#     to as "pinning") those references to a particular tag or image digest.
#   - Adding image-reference env vars to specified containers
#   - Adding a related-images list
#
# Note:
#
# - We declare our Pyton requirement as 3.6+ to gain use of the inseration-oder-preserving
#   implementation of dict() to have a generated CSV ordering that matches that of the
#   template CSV.  (Python 3.7+ makes this order preserving a part of the language spec, btw.)

import argparse
import datetime
import math
import os

# Implementation Notes:
#
# This script uses a two-level mapping in order to find and change image references
# based on an input image manifest file and mapping/overrides specifeid as args:
#
# 1. repo name in input image ref -> image key, via image-key dict.
# 2. image-key -> output image ref, via image manifest dict.

from bundle_common import *

# Loads a JSON image manifest into a manifest map that we use.
def load_image_manifest(image_manifest_pathn, rgy_ns_override_specs,
                        use_tags=False, tag_override=None, tag_suffix=None):

   image_manifest = dict()
   image_manifest_list = load_json("image manifest", image_manifest_pathn)

   image_ref_to_use = "image-ref-by-tag" if use_tags else "image-ref-by-digest"

   # Load registry-and-namespace override specs, if provided.
   #
   # An override is of the form: <from>:<to>, Where <from> and <to> are of
   # the form <registry>[/<namespace>].
   #
   # That is, if <from> has no slash, its considered to specify a registry-level
   # replacement in which case <to> should be just a reistry also.

   rgy_ns_overrides = dict()
   if rgy_ns_override_specs:
      for override_spec in rgy_ns_override_specs:
         from_rgy_ns, to_rgy_ns = split_at(override_spec, ":")
         if not from_rgy_ns:
            die("Invalid rgy-ns override, not <from>:<to>: %s" % override_spec)
         from_rgy, from_ns = split_at(from_rgy_ns, "/", favor_right=False)
         to_rgy, to_ns = split_at(to_rgy_ns, "/", favor_right=False)
         if (from_ns is None) != (to_ns is None):
            die("Invalid rgy-ns override, <from> and <to> not same kind: %s" % override_spec)

         rgy_ns_overrides[from_rgy_ns] = to_rgy_ns
   #

   # Check for ambiguity

   for from_rgy_ns in rgy_ns_overrides.keys():
      from_rgy, from_ns = split_at(from_rgy_ns, "/", favor_right=False)
      if from_ns:
         if from_rgy in rgy_ns_overrides:
            die("Oveerides for %s and %s overlap." % (from_rgy, from_rgy_ns))

   # Consume image manifest data and turn inito our manifest map

   for entry in image_manifest_list:
      key = entry["image-key"]

      image_info = dict()
      image_info["image-key"] = key
      image_info["used-in-csv-deployment"] = False

      rgy_ns = entry["image-remote"]

      # Override registry and namespace if there is a matching override

      rgy, ns = split_at(rgy_ns, "/")
      if not rgy:
         rgy = "localhost"

      rgy_ns_override = rgy_ns_overrides[rgy_ns] if rgy_ns in rgy_ns_overrides else None
      if rgy_ns_override is None:
         rgy_ns_override = rgy_ns_overrides[rgy] if rgy in rgy_ns_overrides else None
      if rgy_ns_override:
         rgy_ns = rgy_ns_override
      # Form and add image manifest entry

      rgy_ns_and_name = "%s/%s" % (rgy_ns, entry["image-name"])

      if tag_override:
         tag = tag_override
      else:
         tag = entry["image-version"]
      if tag_suffix:
         tag, dont_care = split_at(tag, "-")  # Drop existing suffix.
         tag = "%s-%s" % (tag, tag_suffix)
      digest = entry["image-digest"]

      if not digest.startswith("sha"):
         die("Invalid image digest value for image %s: %s" % (key, digest))

      image_info["image-ref-by-digest"] = "%s@%s" % (rgy_ns_and_name, digest)
      image_info["image-ref-by-tag"]    = "%s:%s" % (rgy_ns_and_name, tag)
      image_info["image-ref-to-use"] = image_info[image_ref_to_use]

      image_manifest[key] = image_info

   return image_manifest


# Creates an image repo to key map from a list of mappings (from aargs).
def load_image_key_maping(image_key_mapping_specs, image_manifest):

   image_key_mapping = dict()

   # An image-key mapping spec (as from args) is in the form:
   # <repo_to_look_for>:<image_key_in_manifes>
   #
   # We turn the list  into a map from <repo_to_look_for> to <image_key_in manifest>

   # Note:
   # It may be that having this image name to image key mapping is overkill as in
   # all cases currently the mappingg we use is rote: changing the image name to a
   # key by converting dashes to underscore.  This could certainly be done without
   # a dict to control the mapping, and in fact this rote mapping could be done in
   # cases where there was no map entry if we wanted.  But having the explicit
   # mapping provides flexibility and having no defaults causes us to specify everything
   # explicitly which might be good.

   for mapping in image_key_mapping_specs:
      repo, image_key = split_at(mapping, ":")
      if not repo:
         die("Invalid image-key mapping: %s" % mapping)

      # While we're here, we might as well check that the key is in the
      # manifest to catch missing entries earlier rather than later.
      if not image_key in image_manifest:
         die("Image key not found in manifest: %s" % image_key)

      image_key_mapping[repo] = image_key
   #

   return image_key_mapping


# Update image references in CSV deployment, remove latent pull secrets.
def update_image_refs_in_deployment(deployment, image_key_mapping, image_manifest):

   deployment_name = deployment["name"]
   print("Updating image references in %s deployment" % deployment_name)

   pod_spec = deployment["spec"]["template"]["spec"]

   containers = pod_spec["containers"]
   for container in containers:
      image_ref = container["image"]
      parsed_ref = parse_image_ref(image_ref)

      repository = parsed_ref["repository"]
      try:
         image_key = image_key_mapping[repository]
      except KeyError:
         die("No image key mapping for: %s" % image_ref)

      manifest_entry = image_manifest[image_key]
      new_image_ref = manifest_entry["image-ref-to-use"]
      container["image"] = new_image_ref
      manifest_entry["used-in-csv-deployment"] = True
      print("   Image override:  %s" % new_image_ref)

      # Remove any imagePullPolicy so it defaults to IfNotPresent:

      try:
         del container["imagePullPolicy"]
         print("   NOTE: Removed imagePullPolicy from %s deployment" % deployment_name)
      except KeyError:
         pass # No imagePullPolicy specified.

   # Remove any pull secrets left over from dev env practices:

   image_pull_secrets = get_seq(pod_spec, "imagePullSecrets")
   if image_pull_secrets:
      del pod_spec["imagePullSecrets"]
      for entry in image_pull_secrets:
         print("   NOTE: Removed reference to pull secret: %s" % entry["name"] )


# Load dict definining containers to which image ref env vars will be added.
def load_target_containers(target_container_specs):

   target_deployment_containers = dict()

   if not target_container_specs:
      return target_deployment_containers

   # A target-container spec (as from args) identifies a named container within
   # a named deployment via a string of the form:
   #
   # <deployment_name>/<container_name>
   #
   # We turn the list of such thingsinto a map of the form:
   #
   # <deployment_name> -> map of (<container_name> - > map of (<container_attribute> -> <value>)
   #
   # where currenlty we care about boolean <container_attribute" "added" that indicates that
   # we found specified deployment/container and added image-ref env vars to it.

   for target_container_spec in target_container_specs:
      deployment_name, container_name = split_at(target_container_spec, "/")
      if not deployment_name:
         die("Invalid target-container spec: %s" % target_container_spec)

      try:
         containers_of_deployment = target_deployment_containers[deployment_name]
      except KeyError:
         containers_of_deployment = dict()
         target_deployment_containers[deployment_name] = containers_of_deployment
      containers_of_deployment[container_name] = {"added": False}
   #
   return target_deployment_containers


# Add image reference environment variables to secifeid containers of a deployment.
def add_image_ref_env_vars_to_deployment(deployment, target_containers,
                                         image_manifest, image_ref_env_var_prefix):

   deployment_name = deployment["name"]
   pod_spec = deployment["spec"]["template"]["spec"]
   containers = pod_spec["containers"]

   for container_spec in containers:
      container_name = container_spec["name"]
      if container_name not in target_containers:
         continue

      print("Adding image-ref env vars to %s container"
            " of %s deployment." % (container_name, deployment_name))

      try:
         container_env_vars = container_spec["env"]
      except KeyError:
         container_env_vars = list()

      for image_info in image_manifest.values():
         # Notes:  In a first pass of this, we explicitly excluded adding image-ref
         # env vars for images that were use din the CSV itself, as it didn't seem
         # the "operand stuff" needed to know about operator images.  That's not the
         # case (at least for registration-operator) so now we add image refs for
         # everything we know about.

         # TODO: Maybe check the env var isn't already defined?
         entry = dict()
         entry["name"]  = "%s_%s" % (image_ref_env_var_prefix, image_info["image-key"].upper())
         entry["value"] = image_info["image-ref-to-use"]
         container_env_vars.append(entry)

      if not container_env_vars:
         container_spec["env"] = container_env_vars
      target_containers[container_name]["added"] = True
   #


# --- Main ---

def main():

   # Handle args:

   parser = argparse.ArgumentParser()

   parser.add_argument("--source-bundle-dir", dest="source_bundle_pathn", required=True)

   parser.add_argument("--pkg-dir",  dest="pkg_dir_pathn", required=True)
   parser.add_argument("--pkg-name", dest="pkg_name", required=True)

   parser.add_argument("--default-channel",    dest="default_channel")
   parser.add_argument("--replaces-channel",   dest="replaces_channel")
   parser.add_argument("--additional-channel", dest="other_channels", action="append")

   parser.add_argument("--csv-vers",   dest="csv_vers", required=True)
   parser.add_argument("--prev-vers",  dest="prev_vers")
   parser.add_argument("--skip-range", dest="skip_range")
   parser.add_argument("--skip",       dest="skip_versions", action="append")

   parser.add_argument("--image-manifest", dest="image_manifest_pathn", required=True)
   parser.add_argument("--image-name-to-key", dest="image_name_to_key_specs", action="append", required=True)
   parser.add_argument("--rgy-ns-override", dest="rgy_ns_override_specs", action="append")

   parser.add_argument("--add-related-images",        dest="add_related_images", action="store_true")
   parser.add_argument("--add-image-ref-env-vars-to", dest="add_image_ref_env_Vars_specs", action="append")

   parser.add_argument("--use-tags",     dest="use_tags", action="store_true")
   parser.add_argument("--tag-override", dest="tag_override")
   parser.add_argument("--tag-suffix",   dest="tag_suffix")

   args = parser.parse_args()

   source_bundle_pathn = args.source_bundle_pathn

   operator_name  = args.pkg_name
   pkg_name       = args.pkg_name
   pkg_dir_pathn  = args.pkg_dir_pathn

   replaces_channel = args.replaces_channel
   other_channels   = args.other_channels
   default_channel  = args.default_channel

   csv_vers      = args.csv_vers
   prev_vers     = args.prev_vers
   skip_range    = args.skip_range
   skip_versions = args.skip_versions

   image_manifest_pathn = args.image_manifest_pathn
   image_name_to_key_specs = args.image_name_to_key_specs
   rgy_ns_override_specs = args.rgy_ns_override_specs

   add_related_images = args.add_related_images
   add_image_ref_env_Vars_specs = args.add_image_ref_env_Vars_specs

   use_tags     = args.use_tags
   tag_override = args.tag_override
   tag_suffix   = args.tag_suffix

   # Have tag_override or tag_suffix imply use-tags:
   use_tags = use_tags or tag_override or tag_suffix

   csv_name = "%s.v%s" % (pkg_name, csv_vers)
   csv_fn   = "%s.clusterserviceversion.yaml" % (csv_name)

   # The package directory is the directory in which we place a version-named
   # sub-directory for the new bundle.  Make sure the package directory exists,
   # and then create (or empty out) a bundle directory under it.

   if not os.path.exists(pkg_dir_pathn):
      die("Output package directory doesn't exist: %s" % pkg_dir_pathn)
   elif not os.path.isdir(pkg_dir_pathn):
      die("Output package path exists but isn't a directory: %s" % pkg_dir_pathn)

   # Load image key mappins and manifest we will use to update the image references
   # in operator deployments.

   image_manifest = load_image_manifest(image_manifest_pathn, rgy_ns_override_specs,
                       use_tags=use_tags, tag_override=tag_override, tag_suffix=tag_suffix)
   image_key_mapping = load_image_key_maping(image_name_to_key_specs, image_manifest)

   # Load the specifications of the containers to which we will add image-ref
   # env vars, if enabled. If not, this function will return a no-op map.

   image_ref_containers = load_target_containers(add_image_ref_env_Vars_specs)

   bundle_pathn = os.path.join(pkg_dir_pathn, csv_vers, "manifests")
   create_or_empty_directory("outout bundle manifests", bundle_pathn)

   # Load or create the (output) package manifest.

   pkg_manifest_pathn = os.path.join(pkg_dir_pathn, "package.yaml")
   pkg_manifest = load_pkg_manifest(pkg_manifest_pathn, pkg_name)
   if default_channel:
      pkg_manifest["defaultChannel"] = default_channel
   else:
      try:
         del pkg_manifest["defaultChannel"]
      except KeyError:
         pass

   # See if this CSV is to replace an existing one as determeined by:
   #
   # - Previous version speicified by invocation arg, or if none
   # - Current CSV listed on the replaces channel for the package.

   prev_csv_name = None
   if prev_vers:
      prev_csv_name = "%s.v%s" % (pkg_name, prev_vers)
   else:
      if replaces_channel:
         chan = find_channel_entry(pkg_manifest, replaces_channel)
         if chan is not None:
            prev_csv_name = chan["currentCSV"]

   print("New CSV name: %s" % csv_name)
   if prev_csv_name:
      print("Replaces previous CSV: %s" % prev_csv_name)
   else:
      print("NOTE: New CSV does not replace a previous one.")

   if skip_range:
      print("Skips previous CSVs in range: %s" % skip_range)
   else:
      print("NOTE: New CSV does not skip a range of previous ones.")

   # Turn to-be-skipped versions into skipped CSV names and echo.
   skips_list = []
   if skip_versions:
      for skip_vers in skip_versions:
         skip_csv_name = "%s.v%s" % (pkg_name, skip_vers)
         print("Skips specific previous CSVs: %s" % skip_csv_name)
         skips_list.append(skip_csv_name)

   channels_to_update = list()
   if replaces_channel:
      channels_to_update.append(replaces_channel)
   if other_channels:
      channels_to_update.extend(other_channels)

   # Load all manifests in the source bundle directory.  For non-CSV manifests,
   # just copy over to output bundle.  Hold onto the CSV for later manipulation.

   csv = None

   manifests = load_all_manifests(source_bundle_pathn)
   for manifest_fn, manifest in manifests.items():
      kind = manifest["kind"]
      if kind == "ClusterServiceVersion":
         if csv is None:
            csv = manifest
         else:
            die("More than one CSV manifest found in bundle directory.")
      else:
         print("Copying manifest file unchanged: %s" % manifest_fn)
         copy_file(manifest_fn, source_bundle_pathn, bundle_pathn)
   #

   if csv is None:
      die("CSV manifest not found in bundle directory.")

   # Adjust CSV name and creation timestamp in metadata

   metadata = csv["metadata"]
   metadata["name"] = csv_name

   created_at = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%SZ")

   annotations = metadata["annotations"]
   annotations["createdAt"] = created_at

   if skip_range:
      annotations["olm.skipRange"] = skip_range

   # Plug in version and previous CSV ("replaces") if any.

   spec = csv["spec"]
   spec["version"]  = csv_vers
   if prev_csv_name is not None:
      spec["replaces"] = prev_csv_name
   else:
      try:
         del spec["replaces"]
      except KeyError:
         pass

   # Plug in specific CSV skips if any.

   if skips_list:
      spec["skips"] = skips_list
   else:
      try:
         del spec["skips"]
      except KeyError:
         pass

   install_spec = spec["install"]["spec"]
   deployments = install_spec["deployments"]


   # Update the image refs in the deployments.  As a side effect, we also identify
   # the images that are used within CSV deployments since we don't want to treat
   # those as related images.

   image_ref_env_var_prefix = "OPERAND_IMAGE"
   for deployment in deployments:
      deployment_name = deployment["name"]
      update_image_refs_in_deployment(deployment, image_key_mapping, image_manifest)
      if deployment_name in image_ref_containers:
         conatiners_of_deployment = image_ref_containers[deployment_name]
         add_image_ref_env_vars_to_deployment(deployment, conatiners_of_deployment,
                                              image_manifest, image_ref_env_var_prefix)
   #
   image_ref_containers_not_found = False
   for dn in image_ref_containers:
      for cn in image_ref_containers[dn]:
         if not image_ref_containers[dn][cn]["added"]:
            if not image_ref_containers_not_found:
               emsg("One or more containers specified for additoin of image-ref env vars not found.")
               image_ref_containers_not_found = True
            print("   Deployment/container not found: %s/%s" % (dn, cn))
   if image_ref_containers_not_found:
      die("Aborting due to missing deployment/containers.")

   # If we're adding in related-image info, then add in entrys for all of the
   # entries in the image_manifest that haven't been mentioned in an operator
   # deployment we've processed.

   if add_related_images:
      print("Adding related images list to CSV.")

      related_images = list()
      for image_info in image_manifest.values():
         if not image_info["used-in-csv-deployment"]:
            related_image_name = image_info["image-key"]
            related_image_ref = image_info["image-ref-to-use"]

            entry = dict()
            entry["name"] = related_image_name
            entry["image"] = related_image_ref
            # entry["required"] = True
            related_images.append(entry)
      #
      spec["relatedImages"] = related_images
   #

   # Write out the updated CSV

   csv_pathn = os.path.join(bundle_pathn, csv_fn)

   print("Writing CSV mainfest: %s" % csv_fn)
   dump_manifest("bound CSV", csv_pathn, csv)

   # Generate metadata/annotatoins

   metadata_pathn = os.path.join(pkg_dir_pathn, csv_vers, "metadata")
   create_or_empty_directory("outout bundle metadata", metadata_pathn)

   annotations_manifest = dict()
   annotations_manifest["annotations"] = dict()
   annot = annotations_manifest["annotations"]

   annot["operators.operatorframework.io.bundle.mediatype.v1"] = "registry+v1"
   annot["operators.operatorframework.io.bundle.manifests.v1"] = "manifests/"
   annot["operators.operatorframework.io.bundle.metadata.v1"]  = "metadata/"

   annot["operators.operatorframework.io.bundle.package.v1"] = pkg_name

   channels_list = ','.join(sorted(list(channels_to_update)))
   annot["operators.operatorframework.io.bundle.channels.v1"] = channels_list

   # Observation: Having a default channel annotation be a property of a bundle
   # (representing a specific version of a CSV) seems odd, as this is really a
   # property of the package, not a paritcular CSV.  I wonder what the result is if
   # multiple CSVs decleare different defaults??
   #
   # Update:  It seems its a last-one-(into the index image)-wins situation applies here.
   # And also, there are cases where we don't want to specify a default channel and OPM/OLM
   # now allows this).

   if default_channel:
      annot["operators.operatorframework.io.bundle.channel.default.v1"] = default_channel

   print("Writing bundle metadata.")
   bundle_annotations_pathn = os.path.join(metadata_pathn, "annotations.yaml")
   dump_manifest("bundle metadata", bundle_annotations_pathn, annotations_manifest)

   # Check that the manifest directory is under the OLM 1Mb limit ---

   check_bundle_size(pkg_name, csv_vers, bundle_pathn)

   # Update the package manifest to point to the new CSV

   print("Updating package manifest.")
   update_pkg_manifest(pkg_manifest, channels_to_update, csv_name)
   dump_manifest("package manifest", pkg_manifest_pathn, pkg_manifest)

   exit(0)

if __name__ == "__main__":
   main()

#-30-

