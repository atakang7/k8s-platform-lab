# Delivery

CI/CD reference. [Operations](delivery/README.md) · [Jenkins](platform/jenkins/README.md) · [Base chart](charts/service/README.md)

## Contents
1. [Start here](#1-start-here)
2. [Jobs and templates](#2-jobs-and-templates)
3. [Service CI](#3-service-ci)
4. [Platform CI](#4-platform-ci)
5. [Deployment](#5-deployment)
6. [Release identity](#6-release-identity)
7. [Performance](#7-performance)
8. [Evidence and limits](#8-evidence-and-limits)

## 1. Start here

```text
application change
PR → validate/test/build/scan → merge
   → publish → state/dev.yaml → deploy/test

promotion
dev → PR → stage → PR → prod

failure
before deploy → stop
during deploy → rollback
promotion fail → target unchanged
```

```text
state/<env>.yaml → {version,digest} → Helm → Kubernetes
```

Deployment identity is the OCI digest.

**Stack:** Jenkins/JCasC · Kubernetes · Maven/JUnit · BuildKit · Trivy · Skopeo · Cosign · Helm/OCI · Git · Vault/VSO · Prometheus

## 2. Jobs and templates

```text
sample-java-app ─────────────┐
                            ├→ servicePipeline(...)
resource-requests-webhook ──┘

platform ─────────────────────→ Jenkinsfile.platform
deploy ───────────────────────→ deployPipeline()
```

Four jobs, three pipeline implementations.

**servicePipeline(chart, context, path)** — reusable service CI.

```text
source/chart → servicePipeline → image + chart → state/dev.yaml
```

`sample-java-app` is Jenkins-deployed. `resource-requests-webhook` is built/recorded by CI and operator-deployed.

**deployPipeline()** — reusable environment CD.

```text
state/<env>.yaml → verify → deploy → test → tag → promote
```

It acts only on the cluster's configured `clusterEnvironment`.

**charts/service** — reusable Helm runtime contract.

```text
app values → charts/service
           → Deployment/Service/probes/security
           → ingress/metrics/PDB/Helm test
```

## 3. Service CI

```text
Checkout → Validate → Build/Test → Scan
                                  ↓ main
                           Publish → Record
```

**Checkout** → read chart/state; derive `SERVICE_REVISION` from service path.  
**Validate** → Hadolint · version check · Helm render · server dry-run.  
**Build/Test** → one BuildKit build; `mvnw package` runs JUnit/Spring tests and creates `application.jar`.  
**Scan** → Trivy CRITICAL gate + CycloneDX SBOM.  
**Publish** → push scanned OCI layout · require matching digest · Cosign sign · publish chart.  
**Record** → commit `{version,digest}` to `state/dev.yaml`.

PRs stop after scan. Publish/record run on `main`.

```text
service CI → state/dev.yaml → Git discovery → deploy job
```

CI never calls CD directly. Existing versions are reusable only when their OCI source revision matches the current service source revision.

## 4. Platform CI

```text
Shellcheck
    ↓
chart PR → ct lint --check-version-increment
    ↓
main → publish missing chart versions
```

`charts/service` is published independently from application releases.

## 5. Deployment

```text
state/<env>.yaml → Verify → Deploy → Test → Tag → Promote
```

**Verify** → state schema · previous-env history · Cosign · Helm render · server dry-run.  
**Deploy** → `jenkins-deploy-<env>` runs Helm with `repository@sha256:...`.  
**Test** → HTTP smoke test + service tests.  
**Tag** → `<environment>-<YYYY.MM.DD>.<n>`.  
**Promote** → PR copies the same `{version,digest}` forward.

```text
verification fail → cluster unchanged
readiness fail    → rollback

test fail
  ├→ previous release → rollback
  └→ first install     → uninstall

promotion fail    → target unchanged
```

```text
prod: new digest → 10% traffic → observe 5m
                               ├→ 5xx >1% → fail
                               └→ 5xx ≤1% → stable deploy
```

## 6. Release identity

```text
source revision
      ↓
Chart.yaml.version
      ├→ image tag
      ├→ service chart version
      └→ state version
      ↓
OCI digest
      ↓
environment state
      ↓
repository@sha256:...
```

Version names the release. Digest identifies the deployed artifact. `charts/service` is versioned independently and pinned by application charts.

```text
dev   {version,digest}
          ↓ PR
stage {same}
          ↓ PR
prod  {same}
```

`CODEOWNERS` covers stage/prod state; enforcement depends on branch protection. Rollback restores earlier Git state.

## 7. Performance

```text
warm runners          → acquisition ~51s → ~5s
BuildKit host cache   → image + Maven layer reuse
Trivy host cache      → vulnerability DB reuse
heavy/light split     → validation avoids build queue
cache-node affinity   → host caches stay warm
path filtering        → unrelated changes skip service CI
artifact checks       → skip duplicate publish
state-driven CD       → no rebuild/rescan
current-release check → matching release skips Helm
```

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

**Known limits:** CRITICAL-only gate · SBOM not attested · Cosign transparency-log upload disabled · no-traffic canary warns and passes · app stage/prod/canary paths not exercised in this lab.
