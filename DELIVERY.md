# Delivery

Delivery turns source into one immutable release, records that release
in Git, and moves the same artifact through environments.

## 1. Release model

~~~text
source
  │
  ▼
validate
  │
  ▼
build ONCE
  │
  ▼
scan exact OCI
  │
  ▼
publish same OCI
  │
  ▼
sign digest
  │
  ▼
state/dev.yaml
  │
  ▼
deploy exact digest
  │
  ▼
dev → stage → prod
~~~

Two rules define the system:

~~~text
build once
promote the same artifact

Git state
is the CI → CD handoff
~~~

## 2. Release identity

Each environment records only the release identity:

~~~yaml
sample-java-app:
  version: 1.2.14
  image: sha256:2758e8...
~~~

~~~text
version
   │
   ├── application version
   ├── image tag
   └── chart version

image
   │
   └── immutable OCI digest
~~~

The digest is the runtime identity. Promotion copies the same
`{version,image}` pair forward; it does not rebuild anything.

## 3. Environment model

~~~text
             environments.yaml

                 dev
                  │
                  ▼
                stage
                  │
                  ▼
                 prod
~~~

One cluster runs one configured environment through
`clusterEnvironment`.

This lab currently selects:

~~~yaml
clusterEnvironment: dev
~~~

The repository still keeps stage/prod state and promotion rules for
equivalent environment clusters.

## 4. Pull-request CI

~~~text
pull request
    │
    ▼
┌──────────────────────┐
│ service validation   │
├──────────────────────┤
│ Hadolint             │
│ version check        │
│ Helm render          │
│ server dry-run       │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ BuildKit             │
│ unit tests in build  │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ Trivy                │
│ CRITICAL gate        │
│ CycloneDX SBOM       │
└──────────────────────┘
~~~

The policy webhook service uses the same build/scan path. Its chart is
linted rather than server-dry-run before the operator-owned webhook is
installed.

## 5. Build-once invariant

~~~text
               BuildKit

                  │
                  ▼
          app-image/ OCI layout
                  │
        ┌─────────┴─────────┐
        │                   │
        ▼                   ▼
     Trivy               skopeo
  scans bytes         publishes bytes
        │                   │
        └─────────┬─────────┘
                  ▼
          registry digest
                  │
          exact digest check
                  ▼
               Cosign
~~~

The image sent to the registry is the same OCI artifact that Trivy
scanned.

If the registry digest does not match the scanned digest, publishing
fails before signing.

A published version can be reused only when its OCI source-revision
label matches the service source revision.

## 6. Main-branch publish

~~~text
merge to main
     │
     ▼
validate + build + scan
     │
     ▼
publish image
     │
     ▼
verify registry digest
     │
     ▼
Cosign exact digest
     │
     ▼
publish chart
     │
     ▼
record state/dev.yaml
~~~

CI commits the release identity to Git. That state change is what starts
the deployment path.

## 7. Deployment verification

~~~text
state/<env>.yaml
      │
      ▼
promotion history check
      │
      ▼
Cosign verification
      │
      ▼
Helm render
      │
      ▼
server-side dry-run
      │
      ▼
real deployment
~~~

Stage/prod accept only releases that previously appeared in the preceding
environment's Git history.

CI can exercise the real API/admission chain with dry-runs, but it cannot
perform real writes.

## 8. Runtime deployment

~~~text
verified release
      │
      ▼
helm upgrade --install
      │
      │ --wait
      │ --rollback-on-failure
      ▼
Pods become Ready
      │
      ▼
helm test
      │
  ┌───┴────┐
  │        │
 pass     fail
  │        │
  ▼        ▼
tag      rollback
env      previous
~~~

If the currently running chart version and digest already match state,
the deployment is skipped.

A failed Helm test explicitly restores the previous release.

## 9. Promotion

~~~text
healthy dev
    │
    ▼
dev-YYYY.MM.DD.N
    │
    ▼
promotion PR
    │
    ▼
state/stage.yaml
    │
    ▼
healthy stage
    │
    ▼
stage-YYYY.MM.DD.N
    │
    ▼
promotion PR
    │
    ▼
state/prod.yaml
~~~

Promotion carries the same version and digest.

`.github/CODEOWNERS` owns stage/prod state and
`environments.yaml`; that approval boundary matters when branch
protection requires code-owner review.

## 10. Production canary

Prod currently defines:

~~~yaml
weight: 10
minutes: 5
maxErrorRate: 0.01
~~~

~~~text
new prod release
      │
      ▼
1-replica canary
      │
      ▼
10% ingress traffic
      │
      ▼
Prometheus 5xx rate
      │
   ┌──┴───────────┐
   │              │
healthy          bad
   │              │
   ▼              ▼
update stable   remove canary
   │            stable untouched
   ▼
remove canary
~~~

The first prod install skips canary because no stable release exists.

If the canary receives no measurable traffic, the current implementation
warns and continues. A production system should require enough traffic
or generate synthetic traffic before promotion.

## 11. Zero-downtime mechanics

~~~text
old Pods
  │
  │ remain available
  ▼
new Pods start
  │
  ▼
startup probe
  │
  ▼
readiness probe
  │
  ▼
traffic admitted
  │
  ▼
old Pods terminate
~~~

The service chart combines:

~~~text
maxUnavailable: 0
readiness probe
startup + liveness probes
graceful Spring shutdown
30s termination grace
Helm --wait
post-deploy Helm test
~~~

Prod uses four replicas and `maxSurge: 4`.
Dev/stage use one replica and `maxSurge: 1`.

## 12. Identity boundary

~~~text
CI
jenkins-ci
   │
   ▼
server dry-run only
real write denied


CD
jenkins-deploy-<env>
   │
   ▼
apps-<env>
release objects only
no Secret read
~~~

No deployment kubeconfig is stored in Jenkins.

## 13. Failure boundary

~~~text
validation / scan / sign
promotion / dry-run
          │
          └──── fail
                 │
                 ▼
        NO runtime change


Helm readiness / test
          │
          └──── fail
                 │
                 ▼
          runtime rollback


bad prod canary
          │
          ▼
remove canary
stable untouched
~~~

Runtime rollback does not rewrite Git. Git remains desired state until
the state commit is fixed or reverted.

## 14. Delivery performance

~~~text
heavy work
   │
   ▼
lab-ci-runner
   │
   ├── persistent BuildKit cache
   └── persistent Trivy cache

light checks
   │
   ▼
lab-ci-light

deployment
   │
   ▼
lab-cd-runner
~~~

The pipeline avoids repeated work through path filtering, artifact reuse,
digest comparison, immutable version reuse checks, and skipping already
converged deployments.

Failed work is retried rather than silently skipped by those
optimizations.

## 15. Source of truth

| Concern | Source |
|---|---|
| environment model | `environments.yaml` |
| desired releases | `state/*.yaml` |
| service CI | `delivery/pipeline/vars/servicePipeline.groovy` |
| deployment | `delivery/pipeline/vars/deployPipeline.groovy` |
| shared helpers | `delivery/pipeline/vars/delivery.groovy` |
| build / scan / deploy scripts | `delivery/pipeline/resources/` |
| Jenkins agents | `platform/jenkins/pods/*.yaml` |
| Jenkins jobs | `platform/jenkins/jobs.groovy` |

Implementation detail continues in
**[delivery/README.md](delivery/README.md)**.

Jenkins execution detail continues in
**[platform/jenkins/README.md](platform/jenkins/README.md)**.
