# release

 Release tooling for buiilding the OCM Hub/RH ACM operator bundle manifests (CSV and such) and bundle image
that package up an OCM Hub/RH ACM release for install using the Operator Lifecycle Manager (OLM).
Also contains tools for building a custom OLM catalog (aka registry, aka index) that can serve as 
an OLM catalog source for testing bundles.

For an upstream build, the tools here are driven by build automation to handle the complete bundle
building process:  generating initial (aka unbound) bundle manifests, finalizing (aka binding, aka pinninng)
those manifests to a particular build using an image-manifest file, and bulding the bundle image.

For a Red Hat downstream product build, the downstream bundle building process picks up the
appropriate set of generated unbound bundle manifests from within a `release-x.y` branch of this
repo and then fializes them using the same bundle-binding scripts found here and used upstream, 
using a donwstream-specific image manifest.  Building of the bundle image is done using
a downstream-specific Dockerfile and build process.
