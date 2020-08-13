#!/usr/bin/env python3

# Given a package directory (eg. as exists in App-Registry-format bundles),
# find the operator image for the current CSV in a specified channel of a package.

from bundle_common import *

import argparse
import os
import sys

# --- Main ---

def main():

   parser = argparse.ArgumentParser()
   parser.add_argument("channel_name", nargs=1)
   parser.add_argument("package_dir", nargs=1)

   parser.add_argument("--container", dest="container_specs", action="append")

   args = parser.parse_args()

   selected_channel = args.channel_name[0]
   pkg_pathn        = args.package_dir[0]
   container_specs  = args.container_specs

   if container_specs:
      for container_spec in container_specs:
         deployment_name, container_name = split_at(container_spec, ":")
         if not deployment_name:
            die("Invalid container spec, not <deployment>:<container>: %s" % container_spec)
   #

   the_bundle_dir, the_csv = find_current_bundle_for_package(pkg_pathn, selected_channel)

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

