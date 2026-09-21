# Delivery

Delivery turns source into one immutable release, records it in Git, and moves that same artifact through environments.

<div align="center">
<pre>
source
  │
  ▼
validate ──► build once ──► scan
                              │
                              ▼
                       publish + sign
                              │
                              ▼
                        state/dev.yaml
                              │
                              ▼
                         deploy + test
                              │
                              ▼
                     dev → stage → prod
</pre>
</div>

The two rules that shape the design:

```text
build once, promote the same artifact
Git state is the CI → CD handoff
```

## Release state

`environments.yaml` defines the environment order, namespaces, Jenkins-owned releases, chart registry, canary policy and this cluster's `clusterEnvironment`.

```text
dev ──► stage ──► prod
```

Each environment records only release identity:

```yaml
sample-java-app:
  version: 1.2.14
  image: sha256:2758e8...
```

`version` is the application/chart version.  
`image` is the immutable OCI digest.

Promotion copies the same `{version,image}` forward. A digest can enter an environment only after it has appeared in the previous environment's Git history.

One cluster deploys one configured environment.

## CI

Every service is a thin call into the shared delivery library:

```groovy
@Library('lab-delivery') _
servicePipeline(chart: 'app/chart', context: 'app', path: 'app/')
```

<div align="center">
<pre>
PR
└── validate → build → scan

main
└── validate → build → scan
                     │
                     ▼
                 publish
                     │
             verify digest
                     │
                     ▼
                   sign
                     │
              publish chart
                     │
                     ▼
              state/dev.yaml
</pre>
</div>

For released services, validation covers the Dockerfile, version change, Helm rendering and a real server-side dry-run through Kubernetes admission.

BuildKit produces a single OCI layout:

```text
BuildKit ──► app-image/
               ├── Trivy scans it
               └── registry receives it
```

The registry digest must match the scanned digest before Cosign signs it.

Published versions are immutable. If a tag already exists, it is reused only when its source revision matches the service revision being built.

The resource-request webhook uses the same build/scan/publish path, but the operator installs it because it is not listed under `releases`.

## Deploy and promotion

A state change drives CD.

<div align="center">
<pre>
state/<env>.yaml
       │
       ▼
promotion + signature checks
       │
       ▼
Helm render + server dry-run
       │
       ▼
deploy exact digest
       │
       ▼
helm test
       │
       ▼
healthy environment tag
       │
       ▼
next promotion PR
</pre>
</div>

If the running chart version and image digest already match state, deployment is skipped.

Healthy environment state is tagged:

```text
dev-2026.09.21.5
stage-...
prod-...
```

Promotion stays visible in Git:

```text
state/dev.yaml
     │
     ▼
PR → state/stage.yaml
     │
     ▼
PR → state/prod.yaml
```

`.github/CODEOWNERS` owns stage/prod state and `environments.yaml`. The approval boundary depends on branch protection requiring code-owner review.

### Production canary

Prod currently uses:

```yaml
weight: 10
minutes: 5
maxErrorRate: 0.01
```

```text
new release
    │
    ▼
1 replica · 10% traffic
    │
    ▼
Prometheus ingress 5xx
    │
    ├── fail ──► remove canary; stable stays
    └── pass ──► update stable; remove canary
```

The first prod install skips canary because no stable release exists yet. If no measurable traffic reaches the canary, the current implementation warns and continues.

## Delivery performance

The pipeline is optimized around **not doing work twice**.

| Cost | What avoids it |
|---|---|
| Kubernetes agent startup | one warm Pod per CI/light/CD execution class |
| repeated image compilation | persistent BuildKit state on the heavy CI runner |
| repeated vulnerability DB work | persistent Trivy cache |
| light checks waiting behind builds | separate `lab-ci-light` runner |
| unrelated service builds | service-path change filtering |
| rebuilding for publish/promotion | the scanned OCI artifact is published once and promoted by digest |
| republishing existing artifacts | source-aware image reuse + idempotent chart publication |
| redeploying unchanged releases | running version + digest comparison |
| unnecessary CD runs | deployment reacts to `state/**` / `environments.yaml` changes |

<div align="center">
<pre>
                expensive work
                     │
                     ▼
              lab-ci-runner
          BuildKit + Trivy caches
                     │
          ┌──────────┴──────────┐
          ▼                     ▼
 lab-ci-light          lab-cd-runner
 lint / verification        deployment
</pre>
</div>

Failed work is deliberately retried: service and deploy pipelines run again after an unsuccessful previous build even when the triggering change itself has not changed.

This keeps path filtering and idempotency from turning a failed release into a silently skipped one.

## Trust and failure boundary

```text
CI  jenkins-ci
    └── Kubernetes validation, dry-run only

CD  jenkins-deploy-<environment>
    └── own environment namespace only
```

No deployment kubeconfig is stored in Jenkins, and the CD identity cannot read application Secrets.

```text
validation / scan / signature / promotion failure
    └── stop before runtime change

Helm readiness or test failure
    └── restore previous runtime release

bad canary
    └── remove canary; stable stays
```

A runtime rollback does not rewrite Git. The desired release remains in state until it is fixed or reverted.

## Source of truth

| Concern | Source |
|---|---|
| environment model | `environments.yaml` |
| desired releases | `state/*.yaml` |
| service CI | `delivery/pipeline/vars/servicePipeline.groovy` |
| deployment / promotion | `delivery/pipeline/vars/deployPipeline.groovy` |
| delivery helpers | `delivery/pipeline/vars/delivery.groovy` |
| build / scan / publish / deploy | `delivery/pipeline/resources/lab/delivery/` |
| Jenkins execution | `platform/jenkins/jcasc/jenkins.yaml` |

Implementation details: [`delivery/`](delivery/README.md)  
Jenkins model: [`platform/jenkins/`](platform/jenkins/README.md)
