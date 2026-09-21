# Delivery
This document explains the delivery implementation: tools, Jenkins jobs, pipeline flows, release rules, and optimizations. Operating commands live in [delivery/README.md](delivery/README.md).

## Contents
1. [Technology and Deployment](#1-technology-and-deployment)
2. [Jenkins Job Model](#2-jenkins-job-model)
3. [Service CI](#3-service-ci)
4. [Platform CI](#4-platform-ci)
5. [Deployment Flow](#5-deployment-flow)
6. [Versioning and Releases](#6-versioning-and-releases)
7. [Optimizations](#7-optimizations)
8. [Evidence and Limits](#8-evidence-and-limits)

## 1. Technology and Deployment

| Technology | Purpose |
|---|---|
| Jenkins | CI/CD orchestration |
| Kubernetes | Jenkins agents and workloads |
| Maven + JUnit | Java build and tests |
| rootless BuildKit | image build |
| Trivy | CRITICAL gate + CycloneDX SBOM |
| Skopeo | push the scanned OCI image |
| Cosign | image signing / verification |
| Helm + OCI | packaging and deployment |
| Git | environment state, promotion, rollback |
| Vault + VSO | credentials |
| Prometheus + ingress-nginx | prod canary check |

Jenkins runs on Kubernetes through Helm + JCasC: [platform/jenkins/README.md](platform/jenkins/README.md).

Services are deployed with Helm from digests stored in `state/<environment>.yaml`. Runtime defaults and smoke tests come from [charts/service/README.md](charts/service/README.md).

Operator-owned deployment remains outside Jenkins; see [delivery/README.md](delivery/README.md).

## 2. Jenkins Job Model

```text
sample-java-app ─────────────┐
                            ├→ servicePipeline(chart, context, path)
resource-requests-webhook ──┘

platform ─────────────────────→ Jenkinsfile.platform
deploy ───────────────────────→ deployPipeline()
```

JCasC creates four multibranch jobs. The two service jobs use the same shared-library template and provide only chart, build context, and source path.

- **sample-java-app**: Jenkins builds and releases it.
- **resource-requests-webhook**: Jenkins builds, scans and records it; the operator installs it.
- **platform**: validates repository/platform code and publishes base charts.
- **deploy**: reconciles Git environment state to the cluster.

The shared `lab-delivery` library owns service/deploy behavior; services cannot select another library version.

## 3. Service CI

```text
Checkout → Validate → Build + Test → Scan → [main] Publish → Record
```

### Checkout
Reads chart/state configuration and records the last commit that changed the service path as its source revision.

### Validate
Lints the Dockerfile, requires a version bump on service PRs, renders Helm, and performs Kubernetes server-side dry-run.

### Build + Test
BuildKit builds once. Maven runs JUnit/Spring tests and packages `application.jar`. The app tests include `@WebMvcTest(HelloController)` and `@SpringBootTest`.

### Scan
Trivy scans the OCI image. CRITICAL findings fail CI; the same scan creates the CycloneDX SBOM.

### Publish
`main` only. Skopeo pushes the same OCI layout that was scanned; registry and scanned digests must match. Cosign signs the digest and the service chart is published.

### Record
CI writes `{version, digest}` into dev state. Jenkins-released services continue into CD; operator-owned services stop here.

Test, scan, version/source or digest failures stop publication. State push races refetch `main` and retry.

## 4. Platform CI

```text
Shellcheck → [chart PR] ct lint → [main] publish base charts
```

- **Shellcheck:** validates shell code across delivery/platform/infra/policies/validation.
- **Chart lint:** validates chart PRs and requires a chart version increment.
- **Chart publish:** publishes missing base-chart versions; existing versions are skipped.

`charts/service` is the reusable runtime contract: digest images, security defaults, probes, spreading, optional PDB, ingress/metrics and HTTP Helm smoke test.

## 5. Deployment Flow

```text
state/<env>.yaml → Verify → Deploy → Helm Test → Tag → Promote
```

### Verify
Checks state shape, promotion history, Cosign signature, rendered chart and Kubernetes server-side dry-run.

### Deploy
Uses `jenkins-deploy-<environment>` and runs Helm with the recorded digest. Workloads use `repository@sha256:...`, never mutable tags.

### Helm Test
Runs the chart HTTP smoke test and any service tests. Readiness failure triggers Helm rollback; failed tests restore the previous revision or uninstall a failed first install.

### Tag
Healthy state gets `<environment>-<YYYY.MM.DD>.<n>`.

### Promote
Jenkins opens/refreshes a PR copying the same digest into the next environment. Prod can run a 10% canary for 5 minutes with a 1% ingress 5xx threshold.

## 6. Versioning and Releases

### Application
The service `Chart.yaml.version` is the application version. It is also the image tag, service-chart version, and state version. Service PRs must increase it.

### Base chart
`charts/service` is independently versioned. Application charts pin the base-chart version they use.

### Image identity
```text
source revision → app version → image tag → sha256 digest → state → workload
```

Tags are readable names; the digest is deployment identity. Existing application versions are reusable only when OCI source revision matches the same service source.

### Environment release
`state/<environment>.yaml` defines what should run.

```text
dev digest X → stage digest X → prod digest X
```

Promotion never rebuilds. Stage/prod changes use PRs; CODEOWNERS is the human gate when branch protection requires owner review. Rollback restores earlier Git state.

## 7. Optimizations

| Optimization | Effect |
|---|---|
| warm heavy/light/CD runners | avoids normal agent startup |
| persistent BuildKit cache | reuses image layers |
| persistent Trivy cache | reuses vulnerability data |
| heavy/light split | verification does not wait behind builds |
| cache-node affinity | preserves local caches |
| path filtering | unrelated changes skip heavy service CI |
| existing artifact detection | avoids republishing |
| state-driven CD | no rebuild/rescan/repackage |

Measured release 1.2.14:

| Path | Time |
|---|---:|
| CI #27 | **1m26s** |
| CD #24 | **1m16s** |
| combined execution | **2m42s** |

Warm heavy-runner acquisition was ~5s versus ~51s earlier. Git polling can add one discovery interval before CI and another before CD.

## 8. Evidence and Limits

```text
1.2.14 → sha256:2758e8...dcd1824 → state commit 75769b4
       → deploy/main #24 → dev-2026.09.21.5
```

Implementation: [service template](delivery/pipeline/vars/servicePipeline.groovy) · [platform](delivery/Jenkinsfile.platform) · [deploy template](delivery/pipeline/vars/deployPipeline.groovy) · [scan](delivery/pipeline/resources/lab/delivery/scan-image.sh) · [publish/sign](delivery/pipeline/resources/lab/delivery/publish-image.sh) · [deploy](delivery/pipeline/resources/lab/delivery/deploy.sh).

Known limits: CRITICAL-only vulnerability gate; SBOM not signed/attested; no Cosign transparency-log upload; untrafficked canary passes with a warning; measured proof covers dev while app stage/prod and prod canary remain unexercised.
