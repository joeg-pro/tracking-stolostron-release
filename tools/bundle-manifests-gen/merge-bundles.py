#!/usr/bin/env python3
# Assumes: Python 3.6+

# Creates the composite ACM bundle by merging CSVs and other manifests from one or more
# ssource bundles into an output bundle.  Boilerplate info for the output CSV is obtained
# from a template.
#
# Note:
#
# - The main inputs to this script are already-formed OLM/operator bundles, so there is no
#   depedency on eg. repo structures, whether operator-sdk is being used or not, etc.
#
# - Except for a few arg defaults, hopefully this script is not really ACM specific.
#
# - We declare our Pyton requirement as 3.6+ to gain use of the inseration-oder preserving
#   implementation of dict() to have a generated CSV ordering that matches that of the
#   template CSV.  (Python 3.7+ makes this order preserving a part of the language spec, btw).

from bundle_common import *

import argparse
import datetime
import json
import os
import sys
import traceback
import yaml


def add_supported_labels(labels, label_pattern, entries):

   if not entries:
      return
   new_labels = {label_pattern % e: "supported" for e in entries}
   labels.update(new_labels)


# --- Main ---

def main():

   default_pkg_name  = "advanced-cluster-management"
   default_csv_template_pathn ="./acm-csv-template.yaml"

   # Handle args:

   parser = argparse.ArgumentParser()

   parser.add_argument("--pkg-dir",  dest="pkg_dir_pathn", required=True)
   parser.add_argument("--pkg-name", dest="pkg_name",      default=default_pkg_name)
   parser.add_argument("--channel",  dest="for_channels",  required=True, action="append")

   parser.add_argument("--csv-vers",  dest="csv_vers", default="x.y.z")
   parser.add_argument("--prev-vers", dest="prev_vers")

   parser.add_argument("--source-bundle-dir", dest="source_bundle_pathns", required=True, action="append")

   parser.add_argument("--csv-template", dest="csv_template_pathn", default=default_csv_template_pathn)

   parser.add_argument("--supported-arch", dest="supported_archs", action="append")
   parser.add_argument("--supported-os  ", dest="supported_op_syss", action="append")

   args = parser.parse_args()

   csv_template_pathn = args.csv_template_pathn

   operator_name = args.pkg_name
   pkg_name      = args.pkg_name
   pkg_dir_pathn = args.pkg_dir_pathn
   for_channels  = args.for_channels

   supported_archs   = args.supported_archs
   supported_op_syss = args.supported_op_syss

   csv_vers  = args.csv_vers
   prev_vers = args.prev_vers

   source_bundle_pathns = args.source_bundle_pathns

   merge_categories = False


   vers_parts = csv_vers.split(".")
   if len(vers_parts) != 3:
      die("CSV version not in x.y.z format.")
   csv_vers_xy = vers_parts[0] + "." + vers_parts[1]


   # And now on to the show...

   csv_name  = "%s.v%s" % (operator_name, csv_vers)
   csv_fn    = "%s.clusterserviceversion.yaml" % (csv_name)

   # The package directory is the directory in which we place a version-named
   # sub-directory for the new bundle.  Make sure the package directory exists,
   # and then create (or empty out) a bundle directory under it.

   if not os.path.exists(pkg_dir_pathn):
      die("Output package directory doesn't exist: %s" % pkg_dir_pathn)
   elif not os.path.isdir(pkg_dir_pathn):
      die("Output package path exists but isn't a directory: %s" % pkg_dir_pathn)

   bundle_pathn = os.path.join(pkg_dir_pathn, csv_vers)
   create_or_empty_directory("output bundle", bundle_pathn)

   csv_pathn = "%s/%s" % (bundle_pathn, csv_fn)


   # Load or create the package manifest.

   pkg_manifest_pathn = os.path.join(pkg_dir_pathn, "package.yaml")
   pkg_manifest = load_pkg_manifest(pkg_manifest_pathn, pkg_name)


   # Load/parse the base template for the CSV we're generating.  This template provides various
   # boilerplate we're going to use as-is in the output CSV we're generating.

   o_csv = load_manifest("CSV template", csv_template_pathn)

   # Check that the specified bundle directories exist.
   for s_bundle_pathn in source_bundle_pathns:
      if not os.path.isdir(s_bundle_pathn):
         die("Source bundle directory doesn't exist or isn't a directory: %s" % s_bundle_pathn)
   #

   o_spec = o_csv["spec"]

   # Holds info that is accumulated over the set of source bundles:
   m_categories        = set()
   m_keywords          = set()
   m_alm_examples      = dict()
   m_internal_objects  = set()
   m_owned_crds        = dict()
   m_required_crds     = dict()
   m_owned_api_svcs    = dict()
   m_required_api_svcs = dict()
   m_deployments       = dict()
   m_cluster_perms     = dict()
   m_ns_perms          = dict()

   bundle_fns = set() # Used to ensure no dups/overlays iin file names added to buundle

   # Process each of the source bundles:

   first_bundle = True
   for s_bundle_pathn in source_bundle_pathns:

      if not first_bundle:
         print("\n------------\n")
      first_bundle = False

      print("Processing bundle: %s...\n" % s_bundle_pathn)

      s_owned_crds_map = dict()

      # Load all bundle manifests

      s_csv_fn = None
      s_csv    = None
      s_other_manifests = dict()

      manifests = load_all_manifests(s_bundle_pathn)
      for fn, manifest in manifests.items():
         kind = manifest["kind"]
         if kind == "ClusterServiceVersion":
            if s_csv is None:
               s_csv = manifest
               s_csv_fn = fn
            else:
               die("Too many CSV manifests found in %s." % s_bundle_pathn)
         else:
            s_other_manifests[fn] = manifest

      #--- Consume the bundle's CSV ---

      # Make sure we have only one CSV.

      if s_csv is None:
         die("No CSV manifest found in %s." % s_bundle_pathn)

      print("Found source CSV manifest: %s" % s_csv_fn)

      # Right now, we understand only v1alpha1 CSVs:
      s_csv_vers = s_csv["apiVersion"]
      if s_csv_vers != "operators.coreos.com/v1alpha1":
         die("Unsupported CSV API version: %s" % s_csv_vers)

      s_spec = get_map(s_csv, "spec")
      if not s_spec:
         die("CSV doesn't have a (non-empty) spec.")

      s_metadata = get_map(s_csv, "metadata")
      if not s_metadata:
         emsg("CSV has no metadata.")

      s_annotations = get_map(s_metadata, "annotations")
      if not s_annotations:
         wmsg("CSV has no annotations.")

      # Accumulate categories into the output set.
      if merge_categories:
         s_cats = None
         s_cat_str = get_scalar(s_annotations, "categories")
         if s_cat_str:
            # Categories are specified as a common-separated string.  Spint and accumulate.
            s_cats = s_cat_str.split(",")
         if s_cats:
            accumulate_set("category", "categories", s_cats, m_categories)
         else:
            print("   WARN: CSV has no categories.")

      # Accumulate CR examples (ALM-Examples) into the output set.
      s_alm_examples = None
      s_alm_examples_str = get_scalar(s_annotations, "alm-examples")
      if s_alm_examples_str:
         # ALM examples contains a string representation of a YAML sequence of mappings.

         # Bug?: OLM doc isn't clear on format, but treating them as YAMML nght not be right,
         # esp. since when we plug them into the merged CSV we do so as JSON.  But its been
         # working up until now, so we'll leave well enough alone for now.

         try:
            s_alm_examples = yaml.load(s_alm_examples_str, Loader=yaml_loader)
         except json.decoder.JSONDecodeError:
            emsg("Value of alm-examples annotation is not a valid JSON string.")
            raise
      if s_alm_examples:
         accumulate_keyed("ALM example", s_alm_examples, m_alm_examples, get_avk)
      else:
         wmsg("CSV has no ALM examples.")

      # Accuulate internal-objects annotations.
      internal_objects_annotation_name = "operators.operatorframework.io/internal-objects"
      s_internal_objects = None
      s_internal_objects_str = get_scalar(s_annotations, internal_objects_annotation_name)
      if s_internal_objects_str:
         # interal-objects contains a string representation of a JSON sequence of strings.
         try:
            s_internal_objects = json.loads(s_internal_objects_str)
         except json.decoder.JSONDecodeError:
            emsg("Value of internal-objects annotation is not a valid JSON string.")
            raise
      if s_internal_objects:
         accumulate_set("Internal object", "Internal objects", s_internal_objects, m_internal_objects)
      else:
         print("   Note: CSV has no internal objects listed.")

      # Accumulate keywords into the output set.
      s_keywords = get_seq(s_spec, "keywords")
      accumulate_set("keyword", "keywords", s_keywords, m_keywords)

      # Add owned CRds from this CSV into the list we're accumulating.  Keep track
      # of them by GVK so we can reconcile against required CRDs later.

      s_crds = get_map(s_spec,"customresourcedefinitions")
      s_owned_crds = get_seq(s_crds, "owned")
      if s_owned_crds:
         accumulate_keyed("owned CRD", s_owned_crds, m_owned_crds, get_gvk, another_thing_map=s_owned_crds_map)
      else:
         print("   WARN: CSV has no owned CRDs listed. (???)")

      # Nowc collect up the required CRDs.
      s_required_crds = get_seq(s_crds, "required")
      # No warn msg as its perfectly fine for a CSV to not defined any required CRDs.
      accumulate_keyed("required CRD", s_required_crds, m_required_crds, get_gvk, dups_ok=True)

      # Collect up spec.install stanzas...

      s_install = s_spec["install"]
      s_install_strategy = s_install["strategy"]
      if s_install_strategy != "deployment":
         die("CSV uses an unsupported install stragegy \"%s\"." % s_install_strategy)

      s_install_spec = s_install["spec"]

      # Cluster and namespace Permissions (Service Accounts):
      s_cluster_perms = get_seq(s_install_spec, "clusterPermissions")
      accumulate_keyed("cluster permission", s_cluster_perms, m_cluster_perms, lambda e: e["serviceAccountName"])

      s_ns_perms = get_seq(s_install_spec, "permissions")
      accumulate_keyed("namespace permission", s_ns_perms, m_ns_perms, lambda e: e["serviceAccountName"])

      if not (s_cluster_perms or s_ns_perms):
         wmsg("CSV has neither cluster nor namespace permissions/service accounts.")

      if "default" in m_cluster_perms or "default" in m_ns_perms:
         emsg("CSV is defining permissions for the default service account")

      # Deployments:

      s_deployments = get_seq(s_install_spec, "deployments")

      # Check that the deployments aren't using the default service account.

      for chk_deployment in s_deployments:
         chk_deployment_name = chk_deployment["name"]
         try:
            chk_pod_spec = chk_deployment["spec"]["template"]["spec"]
            chk_svc_acct = chk_pod_spec["serviceAccountName"]
         except KeyError:
            chk_svc_acct = "default"
         if chk_svc_acct == "default":
            emsg("CSV deployment %s is using the default service account." % chk_deployment_name)

      if s_deployments:
         accumulate_keyed("install deployment", s_deployments, m_deployments, lambda e: e["name"])
      else:
         wmsg("CSV has no install deployments. (???)")

      #--- Copy the source budnle's non-CSV manifests to the output bundle ---

      print("\nHandling non-CSV manifests in the budnle.")

      ok_for_bundle = ["ConfigMap", "Service"]
      questionable_for_bundle = ["ServiceAccount"]
      must_be_in_csv = ["ClusterRole", "ClusterRoleBinding"]

      expected_crds = set(s_owned_crds_map.keys())

      die_due_to_unlisted_crds = False
      for fn, manifest in s_other_manifests.items():

         kind = manifest["kind"]
         if kind == "CustomResourceDefinition":
            try:
               crd_gvks = get_gvks_for_crd(manifest)
            except Exception as exc:
               traceback.print_exc()
               die("Error reading/parsing CRD manifest file: %s" % fn)

            # Check that the CRD GVKs defined by this CRD manifest are expected (listed
            #  as owned in CSV) and if so, take them out of the list of expected ones
            #  not seen yet.

            all_gvks_are_expected = True
            for this_gvk in crd_gvks:
               if this_gvk in expected_crds:
                  expected_crds.remove(this_gvk)
               else:
                  if all_gvks_are_expected:
                     # First error.  Mention the manifest file.
                     print("   ERROR: CRD manifest file contains unlisted CRD GVKs: %s" % fn)
                     print("          CRD GVK is not listed as owned in CSV: %s" % this_gvk)
                     all_gvks_are_expected = False
            #
            if all_gvks_are_expected:
               print("   Copying Owned-CRD manifest file: %s" % fn)
            else:
               # Havig unlisted CRDs in the budnle will cause the bundle to fail the
               # opm bundle validate "linting" done in downstream builds.  So if we find
               # unlisted CRDs we should really die.  But Hive prior to its version 1.0.6
               # bundle (used by ACM 2.0.z) has such extraneous CRDs that we will tolerate
               # and filter out here for ACM 2.0.z builds until the Hive team has gotten
               # the upstream bundle cleaned up.

               if csv_vers_xy == "2.0":
                  wmsg("Tolerating/skipping CRD manifest file with unlisted CRDs rather than aborting.")
                  continue
               elif csv_vers_xy == "2.4":
                  wmsg("Tolerating/copying CRD manifest file with unlisted CRDs rather than aborting.")
               else:
                  die_due_to_unlisted_crds = True
         elif kind in must_be_in_csv:
            emsg("%s must be defined via permissions in CSV, not in bundle file %s" % (kind, fn))

         elif kind in questionable_for_bundle:
            w_name = manifest["metadata"]["name"]
            wmsg("%s %s is being defined in bundle file %s rather than in CSV" %
                 (kind, manifest["metadata"]["name"], fn))

         elif kind in ok_for_bundle:
            pass
         else:
            # We have a manifest file for something we don't expect
            wmsg("Unrecognized kind %s in %s" % (kind, fn))

         if fn not in bundle_fns:
            copy_file(fn, s_bundle_pathn, bundle_pathn)
            bundle_fns.add(fn)
         else:
            emsg("Duplicate mainfest filename: %s." % t_manifest_fn)
      #

      # Check that we found manifests for all CRDs owned by this source bundle
      if expected_crds:
         for crd_gvk in expected_crds:
            emsg("No manifest found for expected CRD: %s" % crd_gvk)
      else:
         print("   Note: Manifests were copied for all expected CRDs.")

      #
   # End for each source-bundle

   # WE're done gathering input, abort if errors occurred while doing so.

   die_if_errors_have_occurred()

   print("\n============\n")
   print("Creating merged CSV...")


   # --- Reconsile and generate output CSV properties ---

   # Plug in simple metadata

   o_metadata    = o_csv["metadata"]
   o_annotations = o_metadata["annotations"]

   created_at = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%SZ")

   o_metadata["name"] = csv_name
   o_annotations["createdAt"] = created_at

   # Convert categories into a common-separated string and plug into annotations
   if merge_categories:
      o_annotations["categories"] = ','.join(sorted(list(m_categories)))

   # TODO:
   # Filtier the accumulated ALM examples down so we only "publish" the onces in our
   # whitelist, indicated by API GVK.
   o_alm_examples = list(m_alm_examples.values())

   # Convert ALM examples into a sting representation and plug into annotations.
   o_alm_examples_str = json.dumps(o_alm_examples, sort_keys=False)
   o_annotations["alm-examples"] = o_alm_examples_str

   # Convert accumulated internal objects into a string representation and plug into annotations.
   o_internal_objects_str = json.dumps(list(m_internal_objects), sort_keys=False)
   o_annotations[internal_objects_annotation_name] = o_internal_objects_str

   # Insert supported-archiecture and OS labels if any architectures were specified.

   o_labels = dict()  # Don't inherit any from the template.

   add_supported_labels(o_labels, "operatorframework.io/arch.%s", supported_archs)
   add_supported_labels(o_labels, "operatorframework.io/os.%s",   supported_op_syss)

   if o_labels:
      o_metadata["labels"] = o_labels

   o_spec["version"]  = csv_vers

   if prev_vers:
      prev_csv_name = "%s.v%s" % (pkg_name, prev_vers)
      o_spec["replaces"] = prev_csv_name
   else:
      try:
         del o_spec["replaces"]
      except KeyError:
         pass

   # Plug in the merged keyword list (no dups)
   o_spec["keywords"] = list(sorted(m_keywords))

   # Plug in reconciled/merged CRD info...

   o_crds = o_spec["customresourcedefinitions"]
   reconcile_and_plug_in_things("CRD", o_crds, m_owned_crds, m_required_crds)

   # Tidy up: If no CRD info at all, remove the spec stanza.
   if not o_crds:
      del o_spec["customresourcedefinitions"]

   #-Plug in reconciled/merged API service info...
   o_api_svcs = o_spec["apiservicedefinitions"]
   reconcile_and_plug_in_things("API service", o_api_svcs, m_owned_api_svcs, m_required_api_svcs)

   # Tidy up: If no API service definitions info at all, remove the spec stanza.
   if not o_api_svcs:
      del o_spec["apiservicedefinitions"]

   # Now plug in merged/editedspec.install contents...

   o_install = o_spec["install"]
   o_install["strategy"] = "deployment"  # The only strategy we currently support.
   o_install_spec  = o_install["spec"]

   print("Plugging in install permissions...")
   plug_in_things("cluster permission",   o_install_spec, "clusterPermissions", m_cluster_perms)
   plug_in_things("naemspace permission", o_install_spec, "permissions",        m_ns_perms)

   print("Plugging in install deployments...")
   plug_in_things("deployment",           o_install_spec, "deployments",        m_deployments, True)

   # --- Write out the resutling merged CSV ---

   if csv_fn not in bundle_fns:
      print("\nWriting merged CSV mainfest: %s" % csv_fn)
      dump_manifest("merged CSV", csv_pathn, o_csv)
      bundle_fns.add(csv_fn)
   else:
      die("Duplicate manifest filename (for the CSV): %s." % csv_fn)

   # -- Check that the manifest directory is under the OLM 1Mb limit ---

   check_bundle_size(pkg_name, csv_vers, bundle_pathn)

   # --- Update the package manifest to point to the new CSV ---

   print("Updating package manifest.")
   update_pkg_manifest(pkg_manifest, for_channels, csv_name)
   dump_manifest("package manifest", pkg_manifest_pathn, pkg_manifest)

   return

if __name__ == "__main__":
   try:
      main()
   except Exception:
      traceback.print_exc()
      die("Unhandled exception!")

#-30-

