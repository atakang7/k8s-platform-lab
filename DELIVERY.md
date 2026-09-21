# Delivery

CI/CD reference.  
[Operations](delivery/README.md) · [Jenkins](platform/jenkins/README.md) · [Base chart](charts/service/README.md)

## Contents

1. [Overview](#1-overview)
2. [Jobs and templates](#2-jobs-and-templates)
3. [Service CI](#3-service-ci)
4. [Platform CI](#4-platform-ci)
5. [Deployment](#5-deployment)
6. [Release model](#6-release-model)
7. [Performance](#7-performance)
8. [Evidence and limits](#8-evidence-and-limits)

## 1. Overview

```text
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│ Service CI   │ → │ Git state    │ → │ Deployment   │
│ build/release│   │ version+digest│   │ verify/deploy│
└──────────────┘   └──────────────┘   └──────────────┘
```

**Stack:** Jenkins/JCasC · Kubernetes · Maven/JUnit · BuildKit · Trivy · Skopeo · Cosign · Helm/OCI · Git · Vault/VSO · Prometheus

Applications deploy from digests in `state/<environment>.yaml`. Platform/infra reconciliation is operator-owned.

## 2. Jobs and templates

Four multibranch jobs, three pipeline implementations:

| Job | Pipeline | Deployment |
|---|---|---|
| `sample-java-app` | `servicePipeline` | Jenkins |
| `resource-requests-webhook` | `servicePipeline` | operator |
| `platform` | `Jenkinsfile.platform` | n/a |
| `deploy` | `deployPipeline` | Jenkins |

### Service pipeline

```text
┌──────────────┐ → ┌─────────────────┐ → ┌──────────────┐
│ Jenkinsfile  │   │ servicePipeline │   │ image/chart  │
│ chart/context│   │ shared library  │   │ + dev state  │
└──────────────┘   └─────────────────┘   └──────────────┘
```

Standard CI template for a containerized service. The service provides only **chart path, build context, source path**.

### Deployment pipeline

```text
┌──────────────┐ → ┌────────────────┐ → ┌──────────────┐
│ state/<env>  │   │ deployPipeline │   │ Helm release │
│ version+digest│  │                │   │ + promotion  │
└──────────────┘   └────────────────┘   └──────────────┘
```

Reads Git state and deploys only the cluster's `clusterEnvironment`.

### Service chart

```text
┌──────────────┐ → ┌──────────────┐ → ┌──────────────┐
│ app chart    │   │charts/service│   │ K8s objects  │
│ values       │   │ library chart│   │ + Helm test  │
└──────────────┘   └──────────────┘   └──────────────┘
```

Shared runtime template for stateless HTTP services.

## 3. Service CI

```text
Checkout → Validate → Build/Test → Scan
                                  ↓ main
                           Publish → Record
```

| Stage | Work |
|---|---|
| **Checkout** | read chart/state; derive `SERVICE_REVISION` from service path |
| **Validate** | Hadolint · version check · Helm render · server-side dry-run |
| **Build/Test** | one BuildKit build; `mvnw package` runs JUnit/Spring tests and creates `application.jar` |
| **Scan** | Trivy CRITICAL gate + CycloneDX SBOM |
| **Publish** | push scanned OCI layout · verify digest · Cosign sign · publish chart |
| **Record** | commit `{version,digest}` to dev state |

PRs stop after scan. Publish/record run on `main`.

The state commit triggers CD; Service CI never calls the deploy job directly.

Existing versions are reusable only when their OCI source revision matches the current service source revision.

## 4. Platform CI

```text
Shellcheck → [chart PR] ct lint → [main] publish charts
```

- **Shellcheck:** shared delivery/platform/infra/policy scripts.
- **Chart PR:** `ct lint --check-version-increment`.
- **Main:** publish chart versions missing from OCI.

`charts/service` contains the shared Deployment, Service, security defaults, probes, topology spread, optional PDB, ingress/metrics, and HTTP Helm test.

## 5. Deployment

```text
Verify → Deploy → Test → Tag → Promote
```

| Stage | Work |
|---|---|
| **Verify** | state schema · previous-env history · Cosign · Helm render · server dry-run |
| **Deploy** | `jenkins-deploy-<env>` runs Helm with `repository@sha256:...` |
| **Test** | HTTP smoke test + service tests |
| **Tag** | `<environment>-<YYYY.MM.DD>.<n>` |
| **Promote** | PR copies the same `{version,digest}` to the next environment |

Readiness failure rolls back. Failed Helm tests restore the previous revision; failed first installs are removed.

Prod supports a **10% / 5-minute canary** with a **1% ingress 5xx threshold**.

## 6. Release model

```text
Chart.yaml.version
    ├→ image tag
    ├→ service chart version
    └→ state version

source revision → version → digest → state → workload

dev {version,digest}
        ↓
stage {same}
        ↓
prod {same}
```

- Service-changing PRs increment `Chart.yaml.version`.
- Images are tagged by version and deployed by digest.
- `charts/service` is independently versioned and pinned by application charts.
- Stage/prod state changes use PRs; `CODEOWNERS` applies when branch protection requires owner review.
- Rollback restores an earlier Git state.

## 7. Performance

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

**Release 1.2.14:** CI **1m26s** · CD **1m16s** · combined **2m42s**.

Jenkins polls GitHub every minute; delivery can include one polling interval before CI and one before CD.

## 8. Evidence and limits

```text
1.2.14 → sha256:2758e8...dcd1824
       → state commit 75769b4
       → deploy/main #24
       → dev-2026.09.21.5
```

Implementation: [service](delivery/pipeline/vars/servicePipeline.groovy) · [platform](delivery/Jenkinsfile.platform) · [deploy](delivery/pipeline/vars/deployPipeline.groovy) · [build](delivery/pipeline/resources/lab/delivery/build-image.sh) · [scan](delivery/pipeline/resources/lab/delivery/scan-image.sh) · [publish](delivery/pipeline/resources/lab/delivery/publish-image.sh) · [verify](delivery/pipeline/resources/lab/delivery/validate-release.sh)

**Known limits:** CRITICAL-only gate · SBOM not attested · Cosign transparency-log upload disabled · no-traffic canary warns and passes · app stage/prod/canary paths implemented but not exercised in this lab.
