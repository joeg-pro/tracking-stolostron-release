#!/usr/bin/env python3
# Assumes: Python 3.6+

# Takes an "unbound" CSV bundle abd configures it for a release by:
#
# - Updating CSV version and CSV name (to match version)
# - Setting the "replaces" property
# - Setting its skip-range annotation
# - Overriding image refernces
# - Removing references to pull secrets in operator deployments
# - Setting the createdAt timestamp
#
# Note:
# - We declare our Pyton requirement as 3.6+ to gain use of the inseration-oder preserving
#   implementation of dict() to have a generated CSV ordering that matches that of the
#   template CSV.  (Python 3.7+ makes this order preserving a part of the language spec, btw).

from bundle_common import *

import argparse
import datetime
import math
import os


# Loads a JSON image manifest into a manifest map that we use.
def load_image_manifest(image_manifest_pathn, rgy_ns_override_specs, image_tag_suffix=""):

   image_manifest = dict()
   image_manifest_list = load_json("image manifest", image_manifest_pathn)

   # Load registry-and-namespace override specs, if provide.
   #
   # An override is of the form: <from>:<to>.
   #
   # If <from> has no slash, its considered to specify a registry-level replacement
   # in which case <to> should be just a reistry too.

   rgy_ns_overrides = dict()
   if rgy_ns_override_specs:
      for override_spec in rgy_ns_override_specs:
         from_rgy_ns, to_rgy_ns = split_at(override_spec, ":")
         if not from_rgy_ns:
            die("Invalid rgy-ns override, not <from>:<to>: %s" % override_spec)
         from_rgy, from_ns = split_at(from_rgy_ns, "/", False)
         to_rgy, to_ns = split_at(to_rgy_ns, "/", False)
         if (from_ns is None) != (to_ns is None):
            die("Invalid rgy-ns override, <from> and <to> not same kind: %s" % override_spec)

         rgy_ns_overrides[from_rgy_ns] = to_rgy_ns
   #

   # Check for ambiguity

   for from_rgy_ns in rgy_ns_overrides.keys():
      from_rgy, from_ns = split_at(from_rgy_ns, "/", False)
      if from_ns:
         if from_rgy in rgy_ns_overrides:
            die("Oveerides for %s and %s overlap." % (from_rgy, from_rgy_ns))

   # Consume image manifest data and turn inito our manifest map

   for entry in image_manifest_list:
      key = entry["image-key"]

      image_info = dict()
      image_info["image-key"] = key
      image_info["used"] = False

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

      tag = entry["image-version"]
      if image_tag_suffix:
         tag = "%s-%" % (tag, image_tag_suffix)
      digest = entry["image-digest"]

      if not digest.startswith("sha"):
         die("Invalid image digest value for image %s: %s" % (key, digest))

      image_info["image_ref_by_digest"] = "%s@%s" % (rgy_ns_and_name, digest)
      image_info["image_ref_by_tag"]    = "%s:%s" % (rgy_ns_and_name, tag)

      image_manifest[key] = image_info

   return image_manifest


# Creates an image repo to key map from a list of mappings (from aargs).
def load_image_key_maping(image_key_mapping_specs, image_manifest):

   image_key_mapping = dict()

   # An image-key mapping spec (as from args) is in the form:
   # <repo_to_look_for>:<image_key_in_manifes>
   #
   # We turn the list  into a map from <repo_to_look_for> to <image_key_in manifest>

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


# Update image references in CSV deployments, remove latent pull secrets.
def update_image_refs_in_deployment(deployment, image_key_mapping, image_manifest, use_tags=False):

   deployment_name = deployment["name"]
   print("Updating image references for deployment: %s" % deployment_name)

   manifest_image_ref_to_use = "image_ref_by_tag" if use_tags else "image_ref_by_digest"

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
      new_image_ref = manifest_entry[manifest_image_ref_to_use]
      container["image"] = new_image_ref
      manifest_entry["used"] = True
      print("   Image override:  %s" % new_image_ref)

   # Remove any pull secrets left over from dev env practices:

   image_pull_secrets = get_seq(pod_spec, "imagePullSecrets")
   if image_pull_secrets:
      del pod_spec["imagePullSecrets"]
      for entry in image_pull_secrets:
         print("   NOTE: Removed reference to pull secret: %s" % entry["name"] )


# --- Main ---

def main():

   # Handle args:

   parser = argparse.ArgumentParser()

   parser.add_argument("--source-bundle-dir", dest="source_bundle_pathn", required=True)

   parser.add_argument("--pkg-dir",  dest="pkg_dir_pathn", required=True)
   parser.add_argument("--pkg-name", dest="pkg_name", required=True)

   parser.add_argument("--use-bundle-image-format", dest="use_bundle_image_format", action="store_true")
   parser.add_argument("--add-related-images",      dest="add_related_images", action="store_true")

   parser.add_argument("--default-channel",    dest="default_channel", required=True)
   parser.add_argument("--replaces-channel",   dest="replaces_channel")
   parser.add_argument("--additional-channel", dest="other_channels", action="append")

   parser.add_argument("--csv-vers",   dest="csv_vers", required=True)
   parser.add_argument("--prev-vers",  dest="prev_vers")
   parser.add_argument("--skip-range", dest="skip_range")

   parser.add_argument("--image-manifest", dest="image_manifest_pathn", required=True)
   parser.add_argument("--image-name-to-key", dest="image_name_to_key_specs", action="append", required=True)
   parser.add_argument("--rgy-ns-override", dest="rgy_ns_override_specs", action="append")

   args = parser.parse_args()

   source_bundle_pathn = args.source_bundle_pathn

   operator_name  = args.pkg_name
   pkg_name       = args.pkg_name
   pkg_dir_pathn  = args.pkg_dir_pathn

   use_bundle_image_format = args.use_bundle_image_format

   replaces_channel = args.replaces_channel
   other_channels   = args.other_channels
   default_channel  = args.default_channel

   csv_vers   = args.csv_vers
   prev_vers  = args.prev_vers
   skip_range = args.skip_range

   image_manifest_pathn = args.image_manifest_pathn
   image_name_to_key_specs = args.image_name_to_key_specs
   rgy_ns_override_specs = args.rgy_ns_override_specs

   add_related_images = args.add_related_images

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

   image_manifest = load_image_manifest(image_manifest_pathn, rgy_ns_override_specs)
   image_key_mapping = load_image_key_maping(image_name_to_key_specs, image_manifest)

   # There seem to be several formats for a bundle directore, depending on how they
   # are being published: being placed in an operator bundle image, or made available
   # some other way (eg. via a Quay.io Application Repo).
   #
   # When the bundle is in bundle-image format, the bundle directory has a manifests
   # subdirectory containing all CSV, CRD manifests, and a metadata directory containing
   # an annotations manifest. When other formats these subdirectories do not exist and
   # all manifests are in the bundle directory itself.  (The bits of metadata are instead
   # in a package.yamml in the package directory containing the bundle.)

   if use_bundle_image_format:
      bundle_pathn = os.path.join(pkg_dir_pathn, csv_vers, "manifests")
   else:
      bundle_pathn = os.path.join(pkg_dir_pathn, csv_vers)
   create_or_empty_directory("outout bundle manifests", bundle_pathn)


   # Load or create the (output) package manifest.

   pkg_manifest_pathn = os.path.join(pkg_dir_pathn, "package.yaml")
   pkg_manifest = load_pkg_manifest(pkg_manifest_pathn, pkg_name)
   if default_channel:
      pkg_manifest["defaultChannel"] = default_channel
   else:
      # TODO/Idea: Use default channel already in package manifest if any?
      if use_bundle_image_format:
         emsg("A default channel is required when using bundle-image format.")

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

   install_spec = spec["install"]["spec"]
   deployments = install_spec["deployments"]

   for deployment in deployments:
      update_image_refs_in_deployment(deployment, image_key_mapping, image_manifest)

   # If we're adding in related-image info, then add in entrys for all of the
   # entries in the image_manifest that haven't been mentioned in an operator
   # deployment we've processed.

   if add_related_images:
      print("Adding related images to CSV.")

      related_images = list()
      for image_info in image_manifest.values():
         if not image_info["used"]:
            related_image_name = image_info["image-key"]
            related_image_ref = image_info["image_ref_by_digest"]

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

   if use_bundle_image_format:
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
      annot["operators.operatorframework.io.bundle.channel.default.v1"] = default_channel

      print("Writing bundle metadata.")
      bundle_annotations_pathn = os.path.join(metadata_pathn, "annotations.yaml")
      dump_manifest("bundle metadata", bundle_annotations_pathn, annotations_manifest)

   # Update the package manifest to point to the new CSV

   print("Updating package manifest.")
   update_pkg_manifest(pkg_manifest, channels_to_update, csv_name)
   dump_manifest("package manifest", pkg_manifest_pathn, pkg_manifest)

   exit(0)

if __name__ == "__main__":
   main()

#-30-

