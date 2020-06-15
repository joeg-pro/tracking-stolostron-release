
# Orchestrating an Upgrade Sequence: A Manual Approach

This writeup is a possible approach for orchestrating a release _N_ to _N+1_
update sequence based on downstream builds mirrored to our downstream testing
image registry/namespace (`quay.io/acm-d`).

This material is written as showing a z-stream upgrade from release
`1.0.0` as the starting _N_ release and `1.0.1` as the upgraded-to
_N+1_ release.  But the same steps, or a variation of them, should work
for any release pair _N_ and _N+1_ for which upgrade is supported
(z-stream upgrade with an _x.y_ feature release, or feature-release
_x.y_ to the next feature release _x.y+1_).

## Some Background

- The Red Hat downstream builds machinery pushes the images it produces into a
image registry that is only accessible when on the Red Hat VPN
(`registry-proxy.engineering.redhat.com`). Because we do most of our dev and test work
using public clouds (AWS in particular), our CICD processes around downstream
testing result in the mirroring of downstream-built images to a Internet-accessible
(but appropriately access controled) namespace hosted on `quay.io`.

As of this writing, this namespace is `quay.io/acm-d`, sometimes referred to as j
use `acm-d` for short.

- Since RH ACM installs as an OLM operator, besides making the various images
available from an Internet-accessible place, we have the additional requirement of
having the RH ACM operator metadata (operator bundles) for the pre-release builds exposed
from an OLM catalog/registry source so that we can perform OLM-based installs of the code.

For both purely upstream builds, and for the testing of downstream builds, we accomplish
this by having CICD processes that build a custom operator registry/catalog image
that serves the operator bundle for our pre-release code.  We create such a
custom registry image for each upstream snapshot, and also for each downstream
build we are going to test.  Then, as a engineering-only set up step
(does not need to be done by customers using the released product), we add a custom
OLM Catalog Source to the OCP cluster on which ACM will be installed, using the
custom registry image appropriate for the snapshot/RC being tested.  This makes
the operator metadata material for our pre-release code available to OLM
on that cluster.

As of this writing, the name of the custom registry image (and usually also the name of the
resulting custom `CatalogSource` on the cluster) used when testing downstream builds
is `acm-custom-registry`. (Registries with different names also exist for use with
upstream builds.)

## Approach

### 1. Create Fresh OCP Cluster with Downstream-Testing Mods (BAU)

As for all downstream testing, install an OCP cluster that has our usual"mods"
to enable downstream testing:

- Defining an `ImageContentSourcePolicy` to indicate that image references specifying
that references to an image registry and namespace of `registry.redhat.io/rhacm1-tech-preview`
should be redirected to use corresponding images in `quay.io:443/acm-d` instead.
- Updating the OCP global pull secret to include an entry  for `quay.io:443`
that includes your credentials to quay.io.

These "mods" can be applied after a vanilla OCP cluster install is done, but because
both require a rolling restart of all cluster nodes this can take quite some time.
So its preferable to apply these changes as part of the initial OCP cluster installation
using settings in `install-config.yaml` and an updated install-time pull secret.
(Details described elsewhere.)

### 2. Add Custom Catalog Source to OCP Cluster (BAU)

Per our usual dev-test procedures, add the `acm-custom-registry` catalog source to the
cluster on which the Hub will be installed.

Use the `acm-custom-registry` image from `acm-d` appropriate for the downstream RC you
are testing, eg. `acm-custom-registry:v1.0.1-RC2`.

(Details described elsewhere.)

You can verify that the custom Catalog Source is defined by:
```
$ oc -n ocm get catalogsource
NAME                  DISPLAY   TYPE   PUBLISHER   AGE
acm-custom-registry             grpc               6h5m
```

You can verify that the RH ACM package is available in the custom Catalog Source by:
```
$ oc get packagemanifests|grep advanced-cluster-management
NAME                                         CATALOG               AGE
advanced-cluster-management                                        6h7m
advanced-cluster-management                  Red Hat Operators     6h44m
```

The `Red Hat Operators` entry is present because this package is being served by the
production Red Hat Operators catalog since we've already release a version.
This doesn't create a problem for us, since we will be explicitly directing OLM to
use our custom Catalog Source in what follows.

### 3. Create namespace for RH ACM (BAU)

We'll use `ocm` as the RH ACM namespace in this writeup.  So to create the
namespace, and make it the default, ass usual do:

```
oc create namespace ocm
oc project ocm
```

Note: The remainder of the examples in this writeup assume `ocm` is the default namespace.

### 4. Create OperatorGroup in RH ACM namespace (BAU)

As usual:
```
$ cat  operator-group.yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: default
  namespace: ocm
spec:
  targetNamespaces:
  - ocm

$ oc apply -f operator-group.yaml
```

### 5. Create Manual-Approval Subscription with Specified Starting CSV of Release N

Here's where things start to get different than the not-upgrade-focused procedures we have
been using to date.  And they get way more different down the line.

In our not-upgraded-focused procedures, at this point in the flow we would create an
OLM subscription to the RH ACM operator's package from our feature-release channel
(using our custom catalog as source) that specifies (a) automatic install-plan approval
and (b) no specific starting CSV (release) identifier.
When we do that, the result is that OLM will install the most recent CSV (release) available on
that feature-release channel in the custom catalog source we've added to the cluster.

But to orchestrate an upgrade for testing, we need to first get the base release _N_
code (in this case `1.0.0`) installed and then stop there, so we can maybe first do
some smoke tests to check that the install was successful.  Then, when ready, we want to
trigger an upgrade to release _N+1_.

To achieve this, instead of our usual form of subscription, we want to instead create
a subscription that (a) specifies manual install-plan approval, so we can orchestrate
OLM's actions, and (b) specifies the CSV for release _N_ as what to start with, so
we end up getting that release installed instead of the more recent _N+1_ release.

The following gets this job done for our current _N_ is `1.0.0`  case:

```
$ cat operator-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: acm-operator-subscription
  namespace: ocm
spec:
  channel: release-1.0
  installPlanApproval: Manual
  name: advanced-cluster-management
  source: acm-custom-registry
  sourceNamespace: ocm
  startingCSV: advanced-cluster-management.v1.0.0

$ oc apply -f operator-subscription.yaml
subscription.operators.coreos.com/acm-operator-subscription unchanged
```

### 6. Approve the Pending Install Plan to get Release N installed

In our not-upgrade-focused procedures, creating the automatic-approval subscription
would have kicked off OLM actions to install the RH ACM operator.

But we've explicitly asked to drive this in Manual mode. So instead, we should now
see that OLM has created an `InstallPlan` for getting release _N_ installed, but
this plan is awaiting for approval before being acted upon:

```
$ oc get installplans
NAME            CSV                   APPROVAL   APPROVED
install-5k6pv   etcdoperator.v0.9.4   Manual     false
```

Do not fret if the CSV mentioned in this pending Install Plan lists an `etcdoperator` CSV
rather than an `advanced-cluster-management` one as in the above example.
This sometimes happens on an initial operator install.  As you might know, RH ACM v1
has a pre-req on the Community `etcdoperator`.  If you look inside of this pending Install Plan,
you would see it proposes to install both `etcdoperator` and `advanced-cluster-management` CSVs
but ends up being identified against `etcdoperator` since that is sometimes the first-listed
CSV in the plan.  (My guess.)

In case you aren't convinced the install plan with also install the RH ACM operator,
you can reassure yourself with:
```
 oc get ip/install-5k6pv -o jsonpath="{.spec.clusterServiceVersionNames}";echo
[etcdoperator.v0.9.4 advanced-cluster-management.v1.0.0]
```

Or further double check that this is the right install plan related to the subscription
(at the moment) with something like:
```
$ oc get subscription/acm-operator-subscription
NAME                        PACKAGE                       SOURCE                CHANNEL
acm-operator-subscription   advanced-cluster-management   acm-custom-registry   release-1.0

 $ oc get subscription/acm-operator-subscription -o jsonpath="{.status.installPlanRef.name}"
install-5k6pv

```

Approve the pending Install Plan to kick OLM into action like this:
```
$ oc patch installplan/install-5k6pv --type merge --patch '{"spec": {"approved": true}}'
installplan.operators.coreos.com/install-5k6pv patched
```

Which makes some usual-looking operator-install things happen.
After a few seconds, we have:
```
$ oc get pods
NAME                                                             READY   STATUS    RESTARTS   AGE
acm-custom-registry-ddd75d65f-vmxpd                              1/1     Running   0          6h39m
etcd-operator-54fdbb97f4-2sj7t                                   3/3     Running   0          34s
hive-operator-6b546797f6-k4v5n                                   1/1     Running   0          31s
multicluster-operators-application-878f4b487-zzwbv               2/4     Running   0          30s
multicluster-operators-hub-subscription-7c7dcbd6c8-fwsnl         1/1     Running   0          30s
multicluster-operators-standalone-subscription-8d9d8896f-s5x2w   1/1     Running   0          30s
multiclusterhub-operator-865bd9df79-ffwm4                        1/1     Running   0          31s
```

### 7. Finish up Installing Release N and Verify Its a Good Baseline

At this point, the installation of the release _N_ RH ACM operator is proceeding
as it would in a non-upgrade-focused install.

Once the RH ACM operator is installed, continue with creating an instance of its
`MultiClusterHub` operand as usual to get the rest of RH ACM installed.

Test it as required to ascertain that its installed and functioning correctly.

(Details left to the reader/tester to fill out.)

### 8. Trigger Upgrade to Release N+1

Once you are happy with the installed release _N_, its time to trigger the upgrade
to release _N+1_.

Since the custom catalog source contained a CSV for a replacement release beyond
the initial-CSV release _N_ defined in it, you should see that there is already another
Install Plan pending approval, this one for an upgrade to the next-most-recent
RH ACM CSV (release):
```
$ oc get installplan
NAME            CSV                                  APPROVAL   APPROVED
install-5k6pv   etcdoperator.v0.9.4                  Manual     true
install-ps882   advanced-cluster-management.v1.0.1   Manual     false
```

Pro Tip: We didn't mention it above (so as to not distract from the flow of expected testing),
but this next-most-recent upgrade install plan was probably pending almost immediately after
Step 6 was done to approve the one for the release _N_ baseline installation.

Observation:  The summary info for this new install plan always seems to mentions an
RH ACM CSV where the baseline install plan sometimes doesn't.  I'd guess this is because
the newer ACM CSV doesn't define any different pre-req on ETCD than the initial one did,
so this install plan only has to install once CSV, hence its the one highlighted in the
install plan summary.

Approve this RH ACM upgrade Install Plan in the same way as before, this time pointing
at the new Install Plan:
```
$ oc patch installplan/install-ps882 --type merge --patch '{"spec": {"approved": true}}'

```

Install-plan approval should kick the upgrade off.  Soon, you'll see operator replica sets
and pods rolling over from old to new  as OLM applies the updated operator manifests.

For example, here we see new operator pods coming up before the old ones are taken down:
```
$ oc get pods
NAME                                                              READY   STATUS              RESTARTS   AGE
acm-custom-registry-ddd75d65f-vmxpd                               1/1     Running             0          5d2h
etcd-operator-86ddc7b8ff-2l8lc                                    3/3     Running             0          8m42s
hive-operator-69df69bcf9-xrjs4                                    0/1     ContainerCreating   0          1s
hive-operator-fcdffd6f9-f6qkm                                     1/1     Running             0          8m40s
multicluster-operators-application-6b5d4fcc8d-k25f6               4/4     Running             0          8m40s
multicluster-operators-application-749bdf5465-g2r2d               0/4     ContainerCreating   0          1s
multicluster-operators-hub-subscription-65d4677954-8cs5q          0/1     ContainerCreating   0          1s
multicluster-operators-hub-subscription-6cc5c4dfb7-h52sc          1/1     Running             0          8m40s
multicluster-operators-standalone-subscription-56f5f9458-jkjzm    1/1     Running             0          8m40s
multicluster-operators-standalone-subscription-6cf9f8f58f-kpnkg   0/1     ContainerCreating   0          1s
multiclusterhub-operator-7c766c9dfb-8qp89                         1/1     Running             0          8m40s
multiclusterhub-operator-86c844989d-wxwkh                         0/1     ContainerCreating   0          1s
```

And you'll see new replica sets have been created:
```
$ oc get rs
NAME                                                        DESIRED   CURRENT   READY   AGE
acm-custom-registry-ddd75d65f                               1         1         1       5d2h
etcd-operator-86ddc7b8ff                                    1         1         1       8m50s
hive-operator-69df69bcf9                                    1         1         0       9s
hive-operator-fcdffd6f9                                     1         1         1       8m48s
multicluster-operators-application-6b5d4fcc8d               1         1         1       8m48s
multicluster-operators-application-749bdf5465               1         1         0       9s
multicluster-operators-hub-subscription-65d4677954          1         1         0       9s
multicluster-operators-hub-subscription-6cc5c4dfb7          1         1         1       8m48s
multicluster-operators-standalone-subscription-56f5f9458    1         1         1       8m48s
multicluster-operators-standalone-subscription-6cf9f8f58f   1         1         0       9s
multiclusterhub-operator-7c766c9dfb                         0         0         0       8m48s
multiclusterhub-operator-86c844989d                         1         1         1       9s
```

Eventually it all settles down to only the new operator pods running:
```
$ oc get pods
NAME                                                              READY   STATUS    RESTARTS   AGE
acm-custom-registry-ddd75d65f-vmxpd                               1/1     Running   0          5d2h
etcd-operator-86ddc7b8ff-2l8lc                                    3/3     Running   0          16m
hive-operator-69df69bcf9-xrjs4                                    1/1     Running   0          49s
multicluster-operators-application-749bdf5465-g2r2d               4/4     Running   0          49s
multicluster-operators-hub-subscription-65d4677954-8cs5q          1/1     Running   0          49s
multicluster-operators-standalone-subscription-6cf9f8f58f-kpnkg   1/1     Running   0          49s
multiclusterhub-operator-86c844989d-wxwkh                         1/1     Running   0          49s
```

### 9. Test, Test, Test the Upgraded Release

Please test the daylights out of the upgraded RH ACM deployment to make sure it actually
works and that no customer configuration or data has been lost in the process.

