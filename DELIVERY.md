# Delivery

A release moves through Git as an immutable `{version,image}` pair.

<div align="center">
<pre>
source
  │
  ▼
validate → build once → scan
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
             promotion PRs
                      │
              dev → stage → prod
</pre>
</div>

CI never rebuilds an artifact between environments. Git state is the handoff between CI and CD.

## State

`environments.yaml` defines:

- environment order and namespaces
- which services Jenkins releases
- chart registry
- prod canary settings
- the environment this cluster runs through `clusterEnvironment`

```text
dev ──► stage ──► prod
```

Desired release state lives under `state/`:

```yaml
sample-java-app:
  version: 1.2.14
  image: sha256:2758e8...
```

`version` is the application/chart version.  
`image` is the immutable OCI digest.

Promotion copies the same digest forward. A later environment is accepted only if that digest appeared in the previous environment's Git history.

Each cluster deploys only its configured `clusterEnvironment`.

## CI

Services use the shared Jenkins library:

```groovy
@Library('lab-delivery') _
servicePipeline(chart: 'app/chart', context: 'app', path: 'app/')
```

```text
PR
└── validate → build → scan

main
└── validate → build → scan
                     │
                     ▼
              publish exact image
                     │
              verify registry digest
                     │
                   sign
                     │
              publish chart
                     │
              update state/dev.yaml
```

BuildKit produces one OCI layout. Trivy scans that layout and the registry receives the same bytes.

For released services, validation includes:

```text
Dockerfile lint
chart/version checks
Helm render
server-side dry-run
admission
```

The webhook follows the same build/scan/publish path, but Jenkins does not release it because it is not listed under `releases`.

Published versions are immutable. If a tag already exists, the pipeline verifies that it belongs to the same service source revision; different source requires a new version.

CI also verifies that the digest reported by the registry matches the digest of the scanned artifact before signing it.

## Deploy

A state change drives the deploy job.

```text
state/<env>.yaml
       │
       ▼
state + promotion checks
       │
       ▼
Cosign verification
       │
       ▼
Helm render + server dry-run
       │
       ▼
Helm deploy by digest
       │
       ▼
helm test
       │
       ▼
healthy environment tag
       │
       ▼
next promotion PR
```

The deploy job skips a service when the running chart version and image digest already match state.

Healthy environments are tagged:

```text
dev-2026.09.21.5
stage-...
prod-...
```

Those tags represent complete known-good environment state.

Promotion is Git-driven:

```text
dev healthy
   │
   ▼
PR → state/stage.yaml
   │
   ▼
stage healthy
   │
   ▼
PR → state/prod.yaml
```

`.github/CODEOWNERS` owns stage/prod state and `environments.yaml`; that gate only matters when branch protection requires code-owner review.

## Production canary

Prod currently uses:

```yaml
canary:
  weight: 10
  minutes: 5
  maxErrorRate: 0.01
```

```text
new release
    │
    ▼
1-replica canary
    │
    ▼
10% ingress traffic
    │
    ▼
Prometheus 5xx ratio
    │
    ├── bad ──► remove canary, keep stable
    └── good ─► deploy stable, remove canary
```

The first prod install skips canary because there is no stable release yet.

## Boundaries

```text
CI  jenkins-ci
    └── server-side dry-run only

CD  jenkins-deploy-<environment>
    └── own environment namespace only
```

No deployment kubeconfig is stored in Jenkins. The deploy identity also cannot read application Secrets.

Failure behavior is intentionally simple:

```text
validation / scan / signature / promotion failure
    └── stop before runtime change

Helm readiness failure
    └── rollback previous release

Helm test failure
    └── rollback, or uninstall failed first install

bad canary
    └── remove canary; stable release stays
```

Runtime rollback does not rewrite Git. State remains the desired release until it is fixed or reverted.

## Where to look

| Concern | Source |
|---|---|
| service CI | `delivery/pipeline/vars/servicePipeline.groovy` |
| deployment / promotion | `delivery/pipeline/vars/deployPipeline.groovy` |
| state helpers | `delivery/pipeline/vars/delivery.groovy` |
| build / scan / publish / deploy scripts | `delivery/pipeline/resources/lab/delivery/` |
| environment model | `environments.yaml` |
| desired releases | `state/*.yaml` |
| Jenkins jobs / agents | `platform/jenkins/jcasc/jenkins.yaml` |
| promotion ownership | `.github/CODEOWNERS` |

Implementation details: [`delivery/`](delivery/README.md)  
Jenkins execution model: [`platform/jenkins/`](platform/jenkins/README.md)  
Shared runtime chart: [`charts/service/`](charts/service/README.md)
