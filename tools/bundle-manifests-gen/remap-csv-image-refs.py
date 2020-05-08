#!/usr/bin/env python3
# Assumes: Python 3.6+


from bundle_common import *

import argparse
import datetime
import math
import os


def load_rgy_ns_overrides(rgy_ns_override_specs):

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

   # Check for ambiguity

   for from_rgy_ns in rgy_ns_overrides.keys():
      from_rgy, from_ns = split_at(from_rgy_ns, "/", False)
      if from_ns:
         if from_rgy in rgy_ns_overrides:
            die("Oveerides for %s and %s overlap." % (from_rgy, from_rgy_ns))

   return rgy_ns_overrides

def remap_image_ref(image_ref, rgy_ns_overrides):

   parsed_ref = parse_image_ref(image_ref)
   repo_and_suffix = parsed_ref["repository_and_suffix"]
   rgy_and_ns = parsed_ref["registry_and_namespace"]
   rgy = parsed_ref["registry"]

   # Override registry and namespace if there is a matching override

   rgy_ns_override = rgy_ns_overrides[rgy_and_ns] if rgy_and_ns in rgy_ns_overrides else None
   if rgy_ns_override is None:
      rgy_ns_override = rgy_ns_overrides[rgy] if rgy in rgy_ns_overrides else None
   if rgy_ns_override:
      rgy_and_ns = rgy_ns_override

   return "%s/%s" % (rgy_and_ns, repo_and_suffix)

# Update image references in CSV deployments, remove latent pull secrets.
def remap_image_refs_in_deployment(deployment, rgy_ns_overrides):

   deployment_name = deployment["name"]
   print("Remapping image references for deployment: %s" % deployment_name)

   pod_spec = deployment["spec"]["template"]["spec"]

   containers = pod_spec["containers"]
   for container in containers:
      image_ref = container["image"]
      new_image_ref = remap_image_ref(image_ref, rgy_ns_overrides)
      if new_image_ref != image_ref:
         container["image"] = new_image_ref
         print("   Updated image ref: %s" % new_image_ref)
      else:
         print("WARM: Image ref unchanged: %s" % image_ref)

   return


# --- Main ---

def main():

   # Handle args:

   parser = argparse.ArgumentParser()

   parser.add_argument("--csv-pathn", dest="csv_pathn", required=True)
   parser.add_argument("--rgy-ns-override", dest="rgy_ns_override_specs", action="append")

   args = parser.parse_args()

   csv_pathn = args.csv_pathn
   rgy_ns_override_specs = args.rgy_ns_override_specs

   rgy_ns_overrides = load_rgy_ns_overrides(rgy_ns_override_specs)

   csv = load_manifest("CSV", csv_pathn)
   spec = csv["spec"]

   install_spec = spec["install"]["spec"]
   deployments = install_spec["deployments"]

   for deployment in deployments:
      remap_image_refs_in_deployment(deployment, rgy_ns_overrides)

   if "relatedImages" in spec:
      related_images = spec["relatedImages"]
      print("Remapping image references in related images.")

      for entry in related_images:
         image_ref = entry["image"]
         new_image_ref = remap_image_ref(image_ref, rgy_ns_overrides)

         if new_image_ref != image_ref:
            entry["image"] = new_image_ref
            print("   Updated image ref: %s" % new_image_ref)
         else:
            print("WARN: Image ref unchanged: %s" % image_ref)
   #

   # Write out the updated CSV

   print("Writing updated CSV mainfest: %s" % csv_pathn)
   dump_manifest("updated CSV", csv_pathn, csv)

   exit(0)

if __name__ == "__main__":
   main()

#-30-

