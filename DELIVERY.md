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
┌─────────────┐ → ┌─────────────┐ → ┌─────────────┐
│ Service CI  │   │ Git state   │   │ Deployment  │
│ build/release│  │ ver+digest  │   │ verify/apply│
└─────────────┘   └─────────────┘   └─────────────┘
```

**Stack:** Jenkins/JCasC · Kubernetes · Maven/JUnit · BuildKit · Trivy · Skopeo · Cosign · Helm/OCI · Git · Vault/VSO · Prometheus

Applications deploy from digests in `state/<environment>.yaml`. Platform/infra reconciliation is operator-owned.

## 2. Jobs and templates

```text
sample-java-app ─────────────┐
                            ├→ servicePipeline(...)
resource-requests-webhook ──┘

platform ─────────────────────→ Jenkinsfile.platform
deploy ───────────────────────→ deployPipeline()
```

Four jobs, three pipeline implementations.

**`servicePipeline(chart, context, path)`**  
Reusable service CI. Input: source + chart location. Output: image, chart, dev state.

```text
Jenkinsfile → servicePipeline(...) → image/chart → state/dev.yaml
```

**`deployPipeline()`**  
Reusable CD. Input: environment state. Output: deployed/tested/tagged release and next promotion PR.

```text
state/<env>.yaml → deployPipeline() → Helm release → promotion
```

**`charts/service`**  
Reusable Helm runtime template.

```text
app values → charts/service → Deployment/Service/probes/security
                          → ingress/metrics/PDB/Helm test
```

`sample-java-app` is Jenkins-deployed. `resource-requests-webhook` is built/recorded by CI and installed by the operator.

## 3. Service CI

```text
Checkout → Validate → Build/Test → Scan
                                  ↓ main
                           Publish → Record
```

**Checkout** → read chart/state; derive `SERVICE_REVISION` from the service path.  
**Validate** → Hadolint · version bump · Helm render · server-side dry-run.  
**Build/Test** → one BuildKit build; `mvnw package` runs JUnit/Spring tests and creates `application.jar`.  
**Scan** → Trivy CRITICAL gate + CycloneDX SBOM.  
**Publish** → push the scanned OCI layout · require matching digest · Cosign sign · publish chart.  
**Record** → commit `{version,digest}` to `state/dev.yaml`.

PRs stop after scan. Publish/record run on `main`.

```text
service CI → state/dev.yaml commit → Git discovery → deploy job
```

Service CI never calls CD directly. Existing versions are reusable only when their OCI source revision matches the current service source revision.

## 4. Platform CI

```text
Shellcheck → chart PR: ct lint/version check
           → main: publish missing chart versions
```

**Shellcheck** checks shared delivery/platform/infra/policy scripts.  
**Chart PR** runs `ct lint --check-version-increment`.  
**Main** publishes chart versions missing from OCI.

`charts/service` is published independently from application releases.

## 5. Deployment

```text
state/<env>.yaml → Verify → Deploy → Test → Tag → Promote
```

**Verify** → state schema · previous-env history · Cosign · Helm render · server dry-run.  
**Deploy** → `jenkins-deploy-<env>` runs Helm with `repository@sha256:...`.  
**Test** → HTTP smoke test + service tests.  
**Tag** → `<environment>-<YYYY.MM.DD>.<n>`.  
**Promote** → PR copies the same `{version,digest}` to the next environment.

```text
readiness failure → Helm rollback

test failure
  ├→ previous release → rollback
  └→ first install     → uninstall
```

Prod canary:

```text
new digest → 10% traffic → watch 5m
                         → 5xx >1%  : fail
                         → 5xx ≤1%  : stable deploy
```

## 6. Release model

```text
Chart.yaml.version
    ├→ image tag
    ├→ service chart version
    └→ state version

source revision → version → digest → state → workload

dev   {version,digest}
          ↓ PR
stage {same}
          ↓ PR
prod  {same}
```

- Service-changing PRs increment `Chart.yaml.version`.
- Images are tagged by version and deployed by digest.
- `charts/service` is independently versioned and pinned by application charts.
- `CODEOWNERS` covers stage/prod state; enforcement depends on branch protection.
- Rollback restores an earlier Git state.

## 7. Performance

```text
warm runners          → agent acquisition ~51s → ~5s
BuildKit host cache   → image + Maven layer reuse
Trivy host cache      → vulnerability DB reuse
heavy/light split     → validation avoids build queue
cache-node affinity   → host caches stay warm
path filtering        → unrelated changes skip service CI
artifact checks       → no duplicate publish
state-driven CD       → no rebuild / rescan
current-release check → matching release skips Helm
```

```text
release 1.2.14
Service CI  1m26s
Deploy      1m16s
Combined    2m42s
```

Jenkins polls GitHub every minute; delivery can include one polling interval before CI and one before CD.

## 8. Evidence and limits

```text
app 1.2.14 → sha256:2758e8...dcd1824
           → state commit 75769b4
           → deploy/main #24
           → dev-2026.09.21.5
```

Implementation: [service](delivery/pipeline/vars/servicePipeline.groovy) · [platform](delivery/Jenkinsfile.platform) · [deploy](delivery/pipeline/vars/deployPipeline.groovy) · [build](delivery/pipeline/resources/lab/delivery/build-image.sh) · [scan](delivery/pipeline/resources/lab/delivery/scan-image.sh) · [publish](delivery/pipeline/resources/lab/delivery/publish-image.sh) · [verify](delivery/pipeline/resources/lab/delivery/validate-release.sh)

**Known limits:** CRITICAL-only gate · SBOM not attested · Cosign transparency-log upload disabled · no-traffic canary warns and passes · app stage/prod/canary paths not exercised in this lab.
