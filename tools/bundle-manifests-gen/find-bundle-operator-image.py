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

   args = parser.parse_args()

   selected_channel = args.channel_name[0]
   pkg_pathn        = args.package_dir[0]

   the_bundle_dir, the_csv = find_current_bundle_for_package(pkg_pathn, selected_channel)

   # We could add ags for deployment name and container name to be able to pick out
   # the right container even if mulitples, but present use case doesn't require that.
   # So we fail if there is more than one deployment/container.

   deployments = the_csv["spec"]["install"]["spec"]["deployments"]
   if len(deployments) == 0:
      die("No operator deployments found in CSV?!?")
   if len(deployments) > 1:
      die("More than one operator deployment found in CSV.")

   containers = deployments[0]["spec"]["template"]["spec"]["containers"]
   if len(containers) == 0:
      die("No containers used in operator deployment?!?")
   if len(containers) > 1:
      die("More than one container used in operator deployment.")

   image_ref = containers[0]["image"]

   print(image_ref)
   exit(0)

if __name__ == "__main__":
   main()

#-30-

