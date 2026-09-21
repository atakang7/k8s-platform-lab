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
┌──────────────┐
│ Service CI   │
│ build/release│
└──────┬───────┘
       ↓
┌──────────────┐
│ Git state    │
│ version+digest
└──────┬───────┘
       ↓
┌──────────────┐
│ Deployment   │
│ verify/deploy│
└──────────────┘
```

**Stack:** Jenkins/JCasC · Kubernetes · Maven/JUnit · BuildKit · Trivy · Skopeo · Cosign · Helm/OCI · Git · Vault/VSO · Prometheus

Applications deploy from digests in `state/<environment>.yaml`. Platform and infrastructure reconciliation is operator-owned.

## 2. Jobs and templates

Four multibranch jobs, three pipeline implementations:

```text
sample-java-app ───────────────┐
                              ├→ servicePipeline(...)
resource-requests-webhook ────┘

platform ───────────────────────→ Jenkinsfile.platform
deploy ─────────────────────────→ deployPipeline()
```

### Service pipeline

```text
service Jenkinsfile
       ↓
chart · context · path
       ↓
servicePipeline(...)
       ↓
image + chart + dev state
```

Standard CI template for containerized services. The service declares where its source and chart live; the shared library supplies the pipeline.

- `sample-java-app` → Jenkins-managed deployment.
- `resource-requests-webhook` → CI-managed artifact, operator-managed deployment.

### Deployment pipeline

```text
state/<environment>.yaml
          ↓
    deployPipeline()
          ↓
verify → deploy → test
          ↓
    tag → promote
```

Reads Git state and reconciles only the cluster configured as `clusterEnvironment`.

### Service chart

```text
application chart
       ↓
values + pinned dependency
       ↓
charts/service
       ↓
Deployment · Service
probes · security · ingress
metrics · PDB · Helm test
```

Shared Helm runtime template for stateless HTTP services.

## 3. Service CI

```text
┌──────────────┐
│ Checkout     │
└──────┬───────┘
       ↓
┌──────────────┐
│ Validate     │
└──────┬───────┘
       ↓
┌──────────────┐
│ Build / Test │
└──────┬───────┘
       ↓
┌──────────────┐
│ Scan         │
└──────┬───────┘
       ↓ main only
┌──────────────┐
│ Publish      │
└──────┬───────┘
       ↓
┌──────────────┐
│ Record state │
└──────────────┘
```

**Checkout**  
Reads chart, environment, and state. `SERVICE_REVISION` is the last commit that changed the service path.

**Validate**  
Runs Hadolint, checks the service version, renders Helm, and performs Kubernetes server-side dry-run.

**Build / Test**  
BuildKit builds one OCI image layout. `mvnw package` runs the JUnit/Spring tests and produces `application.jar`.

**Scan**  
Trivy scans that local OCI layout. CRITICAL findings fail CI. The same report produces the CycloneDX SBOM.

**Publish**  
Runs on `main`. Skopeo pushes the scanned OCI layout, the registry digest must match, Cosign signs the digest, and the service chart is published.

**Record state**  
CI commits `{version,digest}` to `state/dev.yaml`.

```text
service CI
   ↓
state/dev.yaml commit
   ↓
Git discovery
   ↓
deploy job
```

The service job never calls CD directly. Existing versions are reusable only when their OCI source revision matches the current service source revision.

## 4. Platform CI

```text
Shellcheck
    ↓
chart PR?
    ├─ yes → ct lint + version check
    └─ no
    ↓
main?
    ├─ yes → publish missing charts
    └─ no  → done
```

`charts/service` is published independently from application releases and carries the common Deployment, Service, security defaults, probes, topology spread, optional PDB, ingress/metrics, and HTTP Helm test.

## 5. Deployment

```text
state/<env>.yaml
       ↓
┌──────────────┐
│ Verify       │
└──────┬───────┘
       ↓
┌──────────────┐
│ Deploy       │
└──────┬───────┘
       ↓
┌──────────────┐
│ Helm test    │
└──────┬───────┘
       ↓
┌──────────────┐
│ Tag          │
└──────┬───────┘
       ↓
┌──────────────┐
│ Promote      │
└──────────────┘
```

**Verify**  
Checks state schema, previous-environment digest history, Cosign signature, Helm rendering, and server-side dry-run.

**Deploy**  
`jenkins-deploy-<env>` runs Helm with the recorded `repository@sha256:...`.

**Helm test**  
Runs the base HTTP smoke test plus service tests.

```text
readiness failure → Helm rollback

test failure
    ├→ previous release exists → rollback
    └→ first install           → uninstall
```

**Tag**  
Healthy state gets `<environment>-<YYYY.MM.DD>.<n>`.

**Promote**  
Jenkins opens or refreshes a PR containing the same `{version,digest}` for the next environment.

Prod adds:

```text
new digest
   ↓
10% canary
   ↓ 5 minutes
ingress 5xx
   ├→ > 1%  → fail; stable stays
   └→ ≤ 1%  → deploy stable
```

## 6. Release model

### Application version

```text
Chart.yaml.version
       ├→ image tag
       ├→ service chart version
       └→ state version
```

Service-changing PRs increment this version.

### Base chart

```text
charts/service version
       ↓
application Chart.yaml
       ↓
pinned dependency
```

The base chart is versioned independently from applications.

### Artifact identity

```text
service source revision
          ↓
       version
          ↓
      image tag
          ↓
       digest
          ↓
    environment state
          ↓
       workload
```

Images are published with version tags and deployed by digest.

### Promotion

```text
dev   {version,digest}
          ↓ PR
stage {same}
          ↓ PR
prod  {same}
```

`CODEOWNERS` covers stage/prod state. Enforcement depends on branch protection requiring code-owner review.

Rollback restores an earlier environment state in Git.

## 7. Performance

```text
warm runners
    ↓
~51s → ~5s acquisition

BuildKit host cache
    ↓
reuse image + Maven layers

Trivy host cache
    ↓
reuse vulnerability DB

heavy / light runners
    ↓
builds do not block validation

path filtering
    ↓
unrelated changes skip service CI

artifact checks
    ↓
existing image/chart → no republish

state-driven CD
    ↓
no rebuild / no rescan

current release check
    ↓
same version + digest → no Helm work
```

**Release 1.2.14**

```text
Service CI   1m26s
     ↓
Deploy       1m16s
     ↓
Combined     2m42s
```

Jenkins polls GitHub every minute, so delivery can include one polling interval before CI and one before CD.

## 8. Evidence and limits

```text
app 1.2.14
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

**Known limits**

```text
CRITICAL-only vulnerability gate
SBOM archived, not attested
Cosign transparency-log upload disabled
no-traffic canary warns and passes
app stage/prod/canary paths not exercised in this lab
```
