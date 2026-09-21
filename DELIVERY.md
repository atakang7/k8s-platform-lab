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

`environments.yaml` defines environment order, namespaces, releases and prod canary settings.

```text
dev ──► stage ──► prod
```

Desired release state lives under `state/`:

```yaml
sample-java-app:
  version: 1.2.14
  image: sha256:2758e8...
```

`image` is the OCI digest. Promotion copies the same digest forward; a later environment is accepted only if that digest appeared in the previous environment's Git history.

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

Published versions are immutable: the same version may be reused only for the same service source revision.

The admission webhook uses the same build pipeline but is operator-installed, not released by Jenkins.

## Deploy

A state change drives the deploy job.

```text
state/<env>.yaml
       │
       ▼
signature + promotion + server dry-run
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

Jenkins tags healthy states as:

```text
dev-2026.09.21.5
stage-...
prod-...
```

Prod adds a canary before replacing the stable release:

```text
10% traffic → observe ingress 5xx → promote stable / remove canary
```

Current canary settings live in `environments.yaml`.

## Boundaries

```text
CI  jenkins-ci
    └── server-side dry-run only

CD  jenkins-deploy-<environment>
    └── own environment namespace only
```

No deployment kubeconfig is stored in Jenkins.

Validation, scan, signature or promotion failures stop before deployment. Helm readiness/test failures restore the previous runtime release; Git state remains unchanged until it is fixed or reverted.

Implementation: [`delivery/`](delivery/README.md)  
Jenkins execution model: [`platform/jenkins/`](platform/jenkins/README.md)  
Shared runtime chart: [`charts/service/`](charts/service/README.md)
