
# Some common functions for ACM/OCM bundle building scripts.

# Assumes: Python 3.6+

import json
import os
import shutil
import sys
import yaml

yaml_loader = yaml.SafeLoader


errors_have_occurred = False

def eprint(*args, **kwargs):
   print(*args, file=sys.stderr, **kwargs)

def emsg(msg, *args):
   global errors_have_occurred
   eprint("Error: " + msg, *args)
   errors_have_occurred = True

def die(msg, *args):
   eprint("Error: " + msg, *args)
   eprint("Aborting.")
   exit(2)

def die_if_errors_have_occurred(*args, **kwargs):
   if errors_have_occurred:
      if len(args) == 0:
         eprint("Aborting due to previous errors.")
      else:
         eprint(*args, **kwargs)
      exit(2)

def wmsg(msg, *args):
   eprint("WARN: " + msg, *args)

# Accumulate a set of scalars
def accumulate_set(thing_kind, thing_kind_pl, thing_list, thing_set):

   # Capitalize just first char of first word.
   capitalized_thing_kind = thing_kind[0:1].upper() + thing_kind[1:]

   if not thing_list:
      print("   Info: Source CSV has no %s." % thing_kind_pl)
   else:
      for t in thing_list:
         tt = t.strip()
         if tt not in thing_set:
            print("   %s: %s" % (capitalized_thing_kind, tt))
            thing_set.add(tt)


# Accumulates a collection of keyed things, optionally aborting on dup keys.
def accumulate_keyed(thing_kind, thing_list, thing_map, key_getter, dups_ok=False, another_thing_map=None):

   # Capitalize just first char of first word.
   capitalized_thing_kind = thing_kind[0:1].upper() + thing_kind[1:]

   for thing in thing_list:
      key = key_getter(thing)
      if key not in thing_map:
         print("   %s: %s" % (capitalized_thing_kind, key))
         thing_map[key] = thing
      else:
         if not dups_ok:
            emsg("Duplicate %s: %s." % (thing_kind, key))

      # Also accomulate into a second map in passed, eg. a per-source-bundle map rather
      # than one that is accumulating over all source bundles.
      if another_thing_map is not None:
         another_thing_map[key] = thing
   #
   return


# Plugs a list of things into into a base stanza, deleting anchoring property if list is empty.
def plug_in_things_quietly(base_map, prop_name, things_map):

   if things_map:
      base_map[prop_name] = list(things_map.values())
   else:
      try:
         del base_map[prop_name]
      except KeyError:
         pass
   return


# Plugs a list of things into into a base stanza, deleting anchoring property if list is empty.
def plug_in_things(thing_kind, base_map, prop_name, things_map, warn_on_none=False):

   plug_in_things_quietly(base_map, prop_name, things_map)
   if not things_map:
      thing_kind_pl = "%ss" % thing_kind
      msg_sev = "WARN" if warn_on_none else "Note"
      print("   %s: Merged CSV has no no %s." % (msg_sev,thing_kind_pl))
   return


# Reconsiles a set of required vs. owned keyed thigns and plugs resulting sets into a stanza.
def reconcile_and_plug_in_things(thing_kind, things, owned_things, required_things):

   thing_kind_pl = "%ss" % thing_kind
   owned_thing_pl    = "owned %s" % thing_kind_pl
   required_thing_pl = "required %s" % thing_kind_pl

   print("Reconsiling required vs. owned %s." % thing_kind_pl)

   # Plug the merged list of owned things(eg. CRDs, API Services) into the output CSV
   plug_in_things(owned_thing_pl, things, "owned", owned_things)

   # Reconsile required things against owned things: We don't want to express a reqruiement
   #  for a needed thing if the merged CSV will be prodiving it.  Plug resulting list into
   #  output CSV.

   req_things_to_remove = list()
   for req_thing_gvk in required_things.keys():
      if req_thing_gvk in owned_things:
         req_things_to_remove.append(req_thing_gvk)
   if req_things_to_remove:
      for req_thing_gvk in req_things_to_remove:
         print("   %s requirement internally satisfied: %s" % (thing_kind, req_thing_gvk))
         del required_things[req_thing_gvk]
      #
   else:
      print("   No %s requirements are internally satisfied." % thing_kind)

   # Plug in the resulting required-things list.
   plug_in_things(required_thing_pl, things, "required", required_things, True)

   return

# Forms a group/version/kind string from a map containg group, kind, name, version properties.
def get_gvk(a_map):

   kind  = a_map["kind"]
   vers  = a_map["version"]

   # Some CRD references might not have a group property, but hopefully they have
   # a name property from which group can be deduced.

   group = None
   try:
      group = a_map["group"]
   except KeyError:
      # No group property, deduce group frmo name property which we assume is
      #  in the form <kinds>.group.
      # TODO: Consult OLM doc on how it handles this case.
      try:
         name = a_map["name"]
         group = name[name.index(".")+1:]
         # Let this blow up with ValueError if name is not in dotted form.
      except KeyError:
         die("Can't determine API group for CRD of kind %s." % kind)
   gvk = "%s/%s/%s" % (group, vers, kind)
   return gvk

# Forms a group/version/kind string from a map containg apiVersion and kind properties.
def get_avk(a_map):

   group_version = a_map["apiVersion"]
   kind = a_map["kind"]
   gvk = "%s/%s" % (group_version, kind)
   return gvk

# Forms a group/version/kind string from a CRD resource:
def get_gvks_for_crd(crd_map):

   crd_api_gv = crd_map["apiVersion"]
   crd_api_vers = crd_api_gv.split("/")[1]

   spec = crd_map["spec"]
   group = spec["group"]
   kind  = spec["names"]["kind"]

   gvks = []
   if crd_api_vers == "v1beta1":
      # A v1beta1 CRD defines only a single CR version
      vers  = spec["version"]
      this_gvk = "%s/%s/%s" % (group, vers, kind)
      gvks.append(this_gvk)

   # NB: This function is now enabled to allow V1 CRDs in the bundle. This should be in
   # effect for ACM 2.3 and beyond.  If changes to this part need to be back ported into
   # the branches for ACM 2.2 or earlier, be sure to re-disable V1 CRDs.

   # elif crd_api_vers == "--v1-disabled-for-now--":
   elif crd_api_vers == "v1":
      # A v1 CRD can define a list of versions.
      version_entries = spec["versions"]
      for ve in version_entries:
         vers = ve["name"]
         this_gvk = "%s/%s/%s" % (group, vers, kind)
         gvks.append(this_gvk)

   else:
      m = "Bundle-merge tooling does not support CustomResourceDefinition/%s manifests." % crd_api_vers
      raise NotImplementedError(m)

   return gvks

# Get a sequence property, defaulting to an empty one.
def get_seq(from_map, prop_name):
   try:
      s = from_map[prop_name]
   except KeyError:
      s = list()
   return s

# Get a map property, defaulting to an empty one.
def get_map(from_map, prop_name):
   try:
      m = from_map[prop_name]
   except KeyError:
      m = dict()
   return m

# GEt a scalar property, defaulting to None.
def get_scalar(from_map, prop_name):
   try:
      s = from_map[prop_name]
   except KeyError:
      s = None
   return s


# Load a manifest (YAML) file.
def load_manifest(manifest_type, pathn):

   if not pathn.endswith(".yaml"):
      return None
   try:
      with open(pathn, "r") as f:
         return yaml.load(f, yaml_loader)
   except FileNotFoundError:
      cap_manifest_type= manifest_type[0:1].upper() + manifest_type[1:]
      die("%s not found: %s" % (cap_manifest_type, pathn))


# Loads all YAML manifests found in a directory.
def load_all_manifests(dir_pathn):

   manifests = dict()

   all_fns = os.listdir(dir_pathn)
   for fn in all_fns:
      if not fn.endswith(".yaml"):
         continue
      manifest = load_manifest("file", os.path.join(dir_pathn, fn))
      manifests[fn] = manifest
   #
   return manifests

# Write out a YAML manifest
def dump_manifest(manifest_type, pathn, manifest):

   with open(pathn, "w") as f:
      yaml.dump(manifest, f, width=100, default_flow_style=False, sort_keys=False)
   return

# Copy a file from a source directory to a destination directory.
def copy_file(fn, from_dir_pathn, to_dir_pathn):

   src_pathn  = os.path.join(from_dir_pathn, fn)
   dest_pathn = os.path.join(to_dir_pathn,   fn)
   shutil.copy(src_pathn, dest_pathn)

   return

# Load a json file.
def load_json(file_type, pathn):

   try:
      with open(pathn, "r") as f:
         return json.load(f)
   except FileNotFoundError:
      cap_file_type= file_type[0:1].upper() + file_type[1:]
      die("%s not found: %s" % (cap_file_type, pathn))


# Creates a directory, or empties out contents if directory exists.
def create_or_empty_directory(dir_type, pathn):

   try:
      os.makedirs(pathn)
   except FileExistsError:
      if os.path.isdir(pathn):
         for fn in os.listdir(pathn):
            fpathn = os.path.join(pathn, fn)
            os.unlink(fpathn)
      else:
         cap_dir_type= dir_type[0:1].upper() + dir_type[1:]
         die("%s directory path exists but isn't a directory: %s" % (cap_dir_type, bundle_dir_pathn))

   return


# Loads or creates a package manifest.
def load_pkg_manifest(pathn, pkg_name):

   if os.path.exists(pathn):
      pkg_manifest = load_manifest("package manifest", pathn)
   else:
      pkg_manifest = dict()
      pkg_manifest["packageName"] = pkg_name
      pkg_manifest["channels"] = list()
   return pkg_manifest


# Finds the entry for a channel within a package.
def find_channel_entry(manifest, channel):

   pkg_channels = manifest["channels"]
   for pc in pkg_channels:
      if pc["name"] == channel:
         return pc
   return None

# Updates the current CSV pointers in a package manifest map.
def update_pkg_manifest(manifest, for_channels, current_csv_name):

   pkg_channels = manifest["channels"]
   for chan_name in for_channels:
      chan = find_channel_entry(manifest, chan_name)
      if chan is None:
         chan = dict()
         chan["name"] = chan_name
         pkg_channels.append(chan)
      chan["currentCSV"] = current_csv_name
   return
#

# Finds the bundle directory and CSV for the current CSV of a given channel
def find_current_bundle_for_package(pkg_pathn, selected_channel):

   # The package directory should have a single yaml file

   pkg_yamls = []
   bundle_dirs = []
   try:
      pkg_fns = os.listdir(pkg_pathn)
   except FileNotFoundError:
      die("Package directory not found: %s." % pkg_pathn)
   except NotADirectoryError:
      die("Not a directory: %s." % pkg_pathn)

   top_of_pkg_manifests = load_all_manifests(pkg_pathn)
   top_of_pkg_yamls = list(top_of_pkg_manifests.values())

   if len(top_of_pkg_yamls) == 0:
      die("Package manifest (.yaml file) not found in %s." % pkg_pathn)

   # We have one or more yamls. Look through the list of them to find the one
   # that defines the channels list as that's the one we want to use.

   pkg = None
   for yaml in top_of_pkg_yamls:
      if "channels" in yaml:
         pkg = yaml
         break
   if not pkg:
      die("Package manifest not found among .yaml files in %s." % pkg_pathn)

   # Determine the current CSV for the selected channel.

   pkg_channels = pkg["channels"]
   cur_csv = None
   for c in pkg_channels:
      if c["name"] == selected_channel:
         cur_csv = c["currentCSV"]
         break
   #
   if cur_csv is None:
      die("Channel %s not found in package." % selected_channel)

   for fn in pkg_fns:
      pathn = os.path.join(pkg_pathn, fn)
      if os.path.isdir(pathn):
         bundle_dirs.append(pathn)
   #

   # Look through all of the bundle directories to find the one containing the CSV.
   # We do so by looking at the contents of the manifests so we avoid any depnedency
   # on directory/manifest file naming patterns.  (This makes it much slower, though.)

   the_bundle_dir = None
   the_csv = None
   for bundle_pathn in bundle_dirs:
      manifests = load_all_manifests(bundle_pathn)

      found_csv = False
      for manifest_fn, manifest in manifests.items():
         kind = manifest["kind"]
         if kind == "ClusterServiceVersion":
            found_csv = True
            break
      if not found_csv:
         emsg("CSV manifest not found in bundle %s." % bundle_pathn)
         exit(1)

      csv_name = manifest["metadata"]["name"]
      if csv_name == cur_csv:
         the_bundle_dir = bundle_pathn
         the_csv = manifest
         break
   # end-for

   if the_bundle_dir is None:
      die("Bundle containing CSV %s not found." % cur_csv)

   return the_bundle_dir, the_csv
#


# Split a string into left and right parts based on the first occurrence of a
# delimiter encountered when scanning left to right. If the delimiter isn't
# found, the favor_right argument determines if the string is considered to
# be all right of the delimiter or all left of it.

def split_at(the_str, the_delim, favor_right=True):

   split_pos = the_str.find(the_delim)
   if split_pos > 0:
      left_part  = the_str[0:split_pos]
      right_part = the_str[split_pos+1:]
   else:
      if favor_right:
         left_part  = None
         right_part = the_str
      else:
         left_part  = the_str
         right_part = None

   return (left_part, right_part)


# Parse an image reference.
def parse_image_ref(image_ref):

   # Image ref:  [registry-and-ns/]repository-name[:tag][@digest]

   parsed_ref = dict()

   remaining_ref = image_ref
   at_pos = remaining_ref.rfind("@")
   if at_pos > 0:
      parsed_ref["digest"] = remaining_ref[at_pos+1:]
      remaining_ref = remaining_ref[0:at_pos]
   else:
      parsed_ref["digest"] = None
   colon_pos = remaining_ref.rfind(":")
   if colon_pos > 0:
      parsed_ref["tag"] = remaining_ref[colon_pos+1:]
      remaining_ref = remaining_ref[0:colon_pos]
   else:
      parsed_ref["tag"] = None
   slash_pos = remaining_ref.rfind("/")
   if slash_pos > 0:
      parsed_ref["repository"] = remaining_ref[slash_pos+1:]
      rgy_and_ns = remaining_ref[0:slash_pos]
   else:
      parsed_ref["repository"] = remaining_ref
      rgy_and_ns = "localhost"
   parsed_ref["registry_and_namespace"] = rgy_and_ns

   rgy, ns = split_at(rgy_and_ns, "/", favor_right=False)
   if not ns:
      ns = ""

   parsed_ref["registry"] = rgy
   parsed_ref["namespace"] = ns

   slash_pos = image_ref.rfind("/")
   if slash_pos > 0:
      repo_and_suffix = image_ref[slash_pos+1:]
   else:
      repo_and_suffix = image_ref
   parsed_ref["repository_and_suffix"]  = repo_and_suffix

   return parsed_ref

