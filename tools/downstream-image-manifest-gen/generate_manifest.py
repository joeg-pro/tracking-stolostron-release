#!/usr/bin/env python3

# Generates a downstream image manifest, using build info for product images
# provided by CPASS, and agumented with external image information retrieved
# via Brew CLI.
#
# Driven by config in manifest-gen-config.json.
#
# Args:
#
# $1 = Release number (in x.y.z format)
#
# $2 = ACM component name of the component for which the image manifest
#      is being generated (endpoint_operator, multiclsterhub_operator, etc.).
#      (See valid_component_names variable.)

import json
import os
import sys
from subprocess import check_output


valid_component_names = ["endpoint_operator", "multiclusterhub_operator", "acm_operator_bundle"]


# For consuming the config json:

CONFIG_JSON = "manifest-gen-config.json"

CFG_PRODUCT_IMAGES_KEY = "product-images"
CFG_EXTERNAL_IMAGES_KEY = "external-images"
CFG_IMAGE_LIST_KEY = "image-list"
CFG_IMAGE_REGISTRY_KEY = "image-registry"
CFG_IMAGE_NAMESPACE_KEY = "image-namespace"

ACM_COMP_NAME_KEY = "acm-component-name"
BUILD_INFO_ENV_VAR_PREFIX_KEY = "build-info-env-var"
SKIP_FOR_COMPONENTS_KEY = "skip_for_components"
IMAGE_REMOTE_KEY = "image-remote"
PFX_TO_REMOVE_KEY="prefix-to-remove"
EXTERNAL_COMP_BUILD_NAME_KEY = "build-name"
EXTERNAL_COMP_BUILD_TAG_KEY = "build-tag"


def brew_build_info(nvr):
    return check_output(['brew', 'call', 'getBuild', nvr, '--json-output'], encoding="UTF-8")

def brew_latest_build(name, tag):
    cmd_output = check_output(['brew', 'latest-build', '--quiet', tag, name], universal_newlines=True)
    # print("Brew Latest-Build for %s %s: %s" % (tag, name, cmd_output))
    return cmd_output.split()[0]

def get_build_info(name, tag):
    nvr = brew_latest_build(name, tag)
    print("Latest build (NVR) for external image %s/%s: %s" % (name, tag, nvr))
    build_info = brew_build_info(nvr)
    # print('build info for %s: %s' % (nvr,build_info))
    return build_info

def get_image_manifest(component_name,build_info, image_name_prefix_to_remove, image_remote):
    obj = json.loads(build_info)

    image_ref = obj["extra"]["image"]["index"]["pull"][0]
    image_name = image_ref.split("@")[0].split('/')[-1]
    image_digest= image_ref.split("@")[1]
    updated_image_name = image_name.replace(image_name_prefix_to_remove, "")

    entry = {
        "image-key":      component_name,
        "image-name":     updated_image_name,
        "image-version":  obj["extra"]["image"]["index"]["floating_tags"][1],
        "image-tag":      obj["extra"]["image"]["index"]["tags"][0],
        "image-remote":   image_remote,
        "image-digest":   image_digest
    }

    return entry


def main():

    manifest = []

    if len(sys.argv) != 3:
        print("Syntax: %s <release_nr> <this_component_name>" % sys.argv[0])
        exit(1)

    release_nr = sys.argv[1]
    my_component_name = sys.argv[2]
    if not my_component_name in valid_component_names:
        print("ERROR: Component name \"%s\" not recognized." % my_component_name)
        exit(1)

    # Find the directory we are in, as we expect our config.json in the same dir.

    my_dir = os.path.dirname(os.path.realpath(sys.argv[0]))
    config_json = "%s/%s" % (my_dir, CONFIG_JSON)

    with open(config_json, "r", encoding="UTF-8") as file:
        config = json.load(file)

    product_image_registry  = config[CFG_PRODUCT_IMAGES_KEY][CFG_IMAGE_REGISTRY_KEY]
    product_image_namespace = config[CFG_PRODUCT_IMAGES_KEY][CFG_IMAGE_NAMESPACE_KEY]

    product_image_remote="%s/%s" % (product_image_registry, product_image_namespace)

    # Notes:
    # When OSBS builds, it places all images (across all products) into a single OSBS-owned
    # nameapce (called "rh-osbs"). It preserves the image's final/production namespace by
    # applying it as a prefix on the repository name instead.  Eg. an image to be released
    # as registry.redhat.io/rhacm1-tech-preview/a-b-c ends up in the delivery libraries as
    # quay.io/rh-osbs/rhacm1-tech-preview-a-b-c.  And this is the way the image name appears
    # in the CPAAS provided build info.
    #
    # We need to undo this mapping to produce a correct image manfest.  And to do so we
    # need to know the released-as registry and namespace so we can determine the
    # prefix to remove.

    product_osbs_prefix_to_remove = product_image_namespace + "-"

    for image in config[CFG_PRODUCT_IMAGES_KEY][CFG_IMAGE_LIST_KEY]:

        # The image manifest entries for some images may not be available at the time
        # this image manifest is being built for the current component because those
        # components/images are built after the current one (identified by the
        # my_component_name value).  Omit such entries based on skip info in the
        # configuration.

        try:
            skip_this_one = (my_component_name in image[SKIP_FOR_COMPONENTS_KEY])
        except KeyError:
            skip_this_one = False

        if skip_this_one:
            print("Note: Skipping product image: %s (as component %s)" % (component_name, my_component_name))
        else:
           component_name = image[ACM_COMP_NAME_KEY]
           print("processing product image: %s" % component_name)

           env_var = "%s_BUILD_INFO_JSON" % image[BUILD_INFO_ENV_VAR_PREFIX_KEY]
           build_info = os.getenv(env_var)
           if build_info is None:
               print("ERROR: Build info env var %s is not defined." % env_var)
               exit(2)

           entry = get_image_manifest(component_name, build_info,
                                      product_osbs_prefix_to_remove,
                                      product_image_remote)
           manifest.append(entry)

    for image in config[CFG_EXTERNAL_IMAGES_KEY][CFG_IMAGE_LIST_KEY]:

        try:
            skip_this_one = (my_component_name in image[SKIP_FOR_COMPONENTS_KEY])
        except KeyError:
            skip_this_one = False

        if skip_this_one:
            print("Note: Skipping external image: %s (as component %s)" % (component_name, my_component_name))
        else:
            component_name = image[ACM_COMP_NAME_KEY]
            print("Processing external image: %s" % component_name)

            build_name = image[EXTERNAL_COMP_BUILD_NAME_KEY]
            build_tag  = image[EXTERNAL_COMP_BUILD_TAG_KEY]
            build_info = get_build_info(build_name, build_tag)
            if build_info is None:
                print("ERROR: Build info for external image %s/%s is not available." % (build_name, build_tag))
                exit(2)

            entry = get_image_manifest(component_name, build_info,
                                       image[PFX_TO_REMOVE_KEY], image[IMAGE_REMOTE_KEY])
            manifest.append(entry)

    with open("./%s.json" % release_nr, "w", encoding="UTF-8") as file:
        formatted_manifest = json.dumps(manifest, indent=2)
        file.write(formatted_manifest)

if __name__ == '__main__':
    main()
