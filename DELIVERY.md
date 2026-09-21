# Delivery

CI/CD reference for this repository.

**Related:** [operations](delivery/README.md) · [Jenkins](platform/jenkins/README.md) · [service chart](charts/service/README.md)

## Contents

1. [Overview](#1-overview)
2. [Components](#2-components)
3. [Reusable templates](#3-reusable-templates)
4. [Service CI](#4-service-ci)
5. [Platform CI](#5-platform-ci)
6. [Deployment](#6-deployment)
7. [Release model](#7-release-model)
8. [Performance](#8-performance)
9. [Evidence and limits](#9-evidence-and-limits)

## 1. Overview

```text
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│ Service CI   │ → │ Git state    │ → │ Deployment   │
│ build/release│   │ version+digest│   │ verify/deploy│
└──────────────┘   └──────────────┘   └──────────────┘
```

Applications are built once, published to OCI, recorded in `state/<environment>.yaml`, and deployed by digest.

Platform and infrastructure reconciliation is operator-owned.

## 2. Components

```text
Control     Jenkins · JCasC · Kubernetes agents

Build       Maven/JUnit · rootless BuildKit
            Trivy · Skopeo · Cosign

Release     Helm/OCI · Git state

Secrets     Vault · Vault Secrets Operator

Canary      ingress-nginx · Prometheus
```

JCasC defines four multibranch jobs:

| Job | Function |
|---|---|
| `sample-java-app` | application CI + Jenkins-managed release |
| `resource-requests-webhook` | artifact CI; operator-managed deployment |
| `platform` | repository/chart validation + base-chart publication |
| `deploy` | state-driven environment deployment |

## 3. Reusable templates

### Service pipeline

```text
┌───────────────────────────┐
│ service Jenkinsfile       │
│ chart · context · path    │
└─────────────┬─────────────┘
              ↓
┌───────────────────────────┐
│ servicePipeline(...)      │
└─────────────┬─────────────┘
              ↓
 validate → build → scan
        → publish → record
```

Used by containerized services that publish an image and Helm chart.

The service identifies its source and chart; the shared `lab-delivery` library provides the pipeline.

### Deployment pipeline

```text
┌───────────────────────────┐
│ state/<environment>.yaml  │
└─────────────┬─────────────┘
              ↓
┌───────────────────────────┐
│ deployPipeline()          │
└─────────────┬─────────────┘
              ↓
 verify → deploy → test
        → tag → promote
```

Reads Git state and reconciles the cluster configured as `clusterEnvironment`.

### Service chart

```text
┌───────────────────────────┐
│ application chart         │
└─────────────┬─────────────┘
              ↓
┌───────────────────────────┐
│ charts/service            │
└─────────────┬─────────────┘
              ↓
 Deployment · Service
 probes · security · ingress
 metrics · PDB · smoke test
```

Shared Helm library for stateless HTTP services. Applications pin a version and provide service-specific values.

## 4. Service CI

```text
Checkout → Validate → Build/Test → Scan
                                  ↓ main
                           Publish → Record
```

| Stage | Work |
|---|---|
| **Checkout** | read chart/state; derive `SERVICE_REVISION` from the service path |
| **Validate** | Hadolint · version check · Helm render · server-side dry-run |
| **Build/Test** | BuildKit builds once; `mvnw package` runs JUnit/Spring tests and produces `application.jar` |
| **Scan** | Trivy CRITICAL gate + CycloneDX SBOM |
| **Publish** | push scanned OCI layout · verify digest · Cosign sign · publish chart |
| **Record** | commit `{version,digest}` to dev state |

Pull requests stop after scan. Publish and record run on `main`.

The state commit starts the deployment path; Service CI does not call the deploy job.

Existing versions are accepted only when their OCI source revision matches the current service source revision.

## 5. Platform CI

```text
Shellcheck
    ↓
chart PR → ct lint --check-version-increment
    ↓
main → publish missing chart versions
```

`charts/service` is published independently from application releases.

## 6. Deployment

```text
┌────────┐
│ Verify │
└───┬────┘
    ↓
┌────────┐
│ Deploy │
└───┬────┘
    ↓
┌────────┐
│ Test   │
└───┬────┘
    ↓
┌────────┐
│ Tag    │
└───┬────┘
    ↓
┌────────┐
│ Promote│
└────────┘
```

| Stage | Work |
|---|---|
| **Verify** | state schema · previous-env digest history · Cosign · Helm render · server dry-run |
| **Deploy** | `jenkins-deploy-<env>` runs Helm with `repository@sha256:...` |
| **Test** | HTTP smoke test + service tests |
| **Tag** | `<environment>-<YYYY.MM.DD>.<n>` |
| **Promote** | PR copies the same `{version,digest}` to the next environment |

Readiness failure rolls back automatically. Failed Helm tests restore the previous revision; failed first installs are removed.

Prod supports a 10% canary for five minutes with a 1% ingress 5xx threshold.

## 7. Release model

### Version

```text
Chart.yaml.version
    ├→ image tag
    ├→ service chart version
    └→ state version
```

Service-changing PRs increment `Chart.yaml.version`.

`charts/service` has its own independent version.

### Artifact identity

```text
source revision
      ↓
   version
      ↓
  image tag
      ↓
    digest
      ↓
 Git state
      ↓
  workload
```

Images are tagged by version and deployed by digest.

### Promotion

```text
dev {version,digest}
        ↓
stage {same}
        ↓
prod {same}
```

Stage/prod state changes use pull requests. `CODEOWNERS` covers those files; enforcement depends on branch protection.

Rollback restores an earlier Git state.

## 8. Performance

| Mechanism | Result |
|---|---|
| warm heavy/light/CD runners | agent acquisition ~51s → ~5s |
| persistent BuildKit state | image + Maven layer reuse |
| persistent Trivy cache | vulnerability DB reuse |
| heavy/light split | validation does not queue behind builds |
| cache-node affinity | host caches stay warm |
| path filtering | unrelated changes skip service CI |
| artifact existence checks | skip duplicate publish |
| state-driven CD | no rebuild/rescan on deploy |
| current-release check | matching releases skip Helm |

```text
release 1.2.14

CI      1m26s
CD      1m16s
total   2m42s
```

Jenkins polls GitHub every minute; delivery can include one polling interval before CI and one before CD.

## 9. Evidence and limits

```text
1.2.14
  ↓
sha256:2758e8...dcd1824
  ↓
state commit 75769b4
  ↓
deploy/main #24
  ↓
dev-2026.09.21.5
```

Implementation: [service](delivery/pipeline/vars/servicePipeline.groovy) · [platform](delivery/Jenkinsfile.platform) · [deploy](delivery/pipeline/vars/deployPipeline.groovy) · [build](delivery/pipeline/resources/lab/delivery/build-image.sh) · [scan](delivery/pipeline/resources/lab/delivery/scan-image.sh) · [publish](delivery/pipeline/resources/lab/delivery/publish-image.sh) · [verify](delivery/pipeline/resources/lab/delivery/validate-release.sh)

**Known limits:** CRITICAL-only vulnerability gate · SBOM not attested · Cosign transparency-log upload disabled · no-traffic canary warns and passes · app stage/prod/canary paths are implemented but not exercised in this lab.
