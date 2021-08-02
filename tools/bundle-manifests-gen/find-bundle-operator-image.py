#!/usr/bin/env python3

# Given a bundle manifests directory, find the operator image
# referenced by the bundle's CSV.
#
# If the CSV has only a single deployment/container, then the names of these
# need not be specified.  But if it has multiples, then the --container argument
# must be used to specify the desired deployment/container(s).

from bundle_common import *

import argparse
import os
import sys

# --- Main ---

def main():

   parser = argparse.ArgumentParser()
   parser.add_argument("bundle_dir", nargs=1)

   parser.add_argument("--container", dest="container_specs", action="append")

   args = parser.parse_args()

   bundle_pathn    = args.bundle_dir[0]
   container_specs = args.container_specs

   if container_specs:
      for container_spec in container_specs:
         deployment_name, container_name = split_at(container_spec, ":")
         if not deployment_name:
            die("Invalid container spec, not <deployment>:<container>: %s" % container_spec)
   #

   csv_name, the_csv = find_csv_for_bundle(bundle_pathn)

   # Collect up all deployment/container image info in the CSV:

   container_specs_needed = False

   deployments = the_csv["spec"]["install"]["spec"]["deployments"]
   if len(deployments) == 0:
      die("No operator deployments found in CSV?!?")

   if len(deployments) > 1:
      container_specs_needed = True

   operator_images = dict()
   for deployment in deployments:
      deployment_name = deployment["name"]

      containers = deployment["spec"]["template"]["spec"]["containers"]
      if len(containers) == 0:
         die("No containers used in operator deployment?!?")

      if len(containers) > 1:
         container_specs_needed = True

      images_for_deployment = dict()
      for container in containers:
         container_name = container["name"]
         container_image = container["image"]
         images_for_deployment[container_name] = container_image
         # print("Image for %s:%s: %s" % (deployment_name, container_name, container_image))
      #
      operator_images[deployment_name] = images_for_deployment
   #

   if container_specs_needed and (not container_specs):
      die("Multiple deployments/containers exist in CSV. Container specs (--container) are required.")

   if container_specs_needed or container_specs:

      for container_spec in container_specs:
         deployment_name, container_name = split_at(container_spec, ":")
         try:
            image_ref = operator_images[deployment_name][container_name]
            print(image_ref)
         except KeyError:
            die("Deployment/container %s not found in CSV." % container_spec)
   else:
      # Must be the easy single-deployment, single-container case.  Our map-of-maps
      # contains only one entry at each level.

      deployment = next(iter(operator_images.values()))
      image_ref  = next(iter(deployment.values()))
      print(image_ref)

   exit(0)

if __name__ == "__main__":
   main()

#-30-

