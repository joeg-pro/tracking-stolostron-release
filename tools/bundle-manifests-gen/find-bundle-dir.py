#!/usr/bin/env python3

# Given a package directory (eg. as exists in App-Registry-format bundles),
# find the bundle directory for the current CSV in a specified channel of a package.


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
   print(the_bundle_dir)
   exit(0)

if __name__ == "__main__":
   main()

#-30-

