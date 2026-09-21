# Delivery
This document explains the delivery implementation: the tools, Jenkins job model, pipeline flows, release rules, and the optimizations used. Operating commands live in [delivery/README.md](delivery/README.md).

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

| Technology | Used for |
|---|---|
| Jenkins | CI/CD orchestration |
| Kubernetes | Jenkins agents and application runtime |
| Maven + JUnit | Java build and tests |
| rootless BuildKit | container image build |
| Trivy | CRITICAL vulnerability gate + CycloneDX SBOM |
| Skopeo | publishing the exact scanned OCI image |
| Cosign | image signing and pre-deploy verification |
| Helm + OCI charts | application packaging and deployment |
| Git | environment state, promotion and rollback history |
| Vault + VSO | delivery credentials |
| Prometheus + ingress-nginx | prod canary error-rate check |

Jenkins itself runs on Kubernetes and is reconciled through Helm + JCasC. See [platform/jenkins/README.md](platform/jenkins/README.md).

Services are deployed with Helm from immutable image digests recorded in `state/<environment>.yaml`. The reusable service runtime contract lives in [charts/service/README.md](charts/service/README.md).

Platform/infra reconciliation and operator-installed components are not applied by Jenkins. See [delivery/README.md](delivery/README.md) for the operational split.

## 2. Jenkins Job Model

JCasC creates four GitHub multibranch jobs:

```text
sample-java-app ─────────────┐
                            ├→ servicePipeline(chart, context, path)
resource-requests-webhook ──┘

platform ─────────────────────→ Jenkinsfile.platform

deploy ───────────────────────→ deployPipeline()
```

The two service jobs are **instances of the same shared-library template**. A service supplies only:

- its Helm chart;
- its BuildKit context;
- its source path.

The shared `lab-delivery` library owns the pipeline logic. Services cannot select another library version.

The difference between the two services is release ownership:

- **sample-java-app** → Jenkins builds and deploys it.
- **resource-requests-webhook** → Jenkins builds, scans and records it; the operator installs it through `make policies-up`.

The platform and deploy jobs use dedicated flows because they do different work.

## 3. Service CI

Both service jobs use this flow:

```text
Checkout → Validate → Build + Test → Scan → [main] Publish → Record
```

### Checkout
Reads the chart, environment configuration and current state. It also finds the last Git commit that changed the service path; that revision becomes the image source identity.

### Validate
Runs Dockerfile linting. Pull requests must increase the service chart version. The chart is rendered and sent through Kubernetes server-side dry-run.

### Build + Test
BuildKit performs one image build. During the build, Maven runs the Java tests and packages `application.jar`.

For the app this includes:
- JUnit 5 `@WebMvcTest(HelloController)`;
- `@SpringBootTest` context loading;
- executable JAR packaging.

### Scan
Trivy scans the OCI image before publication. Any CRITICAL finding fails the job. The same scan produces the CycloneDX SBOM.

### Publish
Runs only on `main`.

Skopeo pushes the same OCI layout that Trivy scanned. The registry digest must equal the scanned digest. Cosign then signs `repository@digest`. The service chart is published to the OCI registry.

### Record
CI writes `{version, digest}` to the first environment state file.

For Jenkins-released services this state becomes CD input. Operator-installed services stop here.

Failures do not silently advance. Test, scan, version, source-revision or digest failures stop publication. A state push race refetches `main` and retries.

## 4. Platform CI

The platform job validates reusable repository code and publishes reusable charts.

```text
Shellcheck → [chart PR] ct lint → [main] publish base charts
```

### Shellcheck
Checks shell code across delivery, platform, infra, policies and validation scripts.

### Chart lint
On chart pull requests, `ct lint` validates the chart and requires a version increment.

### Chart publish
On `main`, missing chart versions are published to the OCI registry. Already-published versions are skipped.

The important artifact here is `charts/service`: services inherit this chart instead of copying deployment boilerplate. It defines digest-only images, security defaults, probes, topology spreading, optional PDB, ingress/metrics and the standard HTTP Helm smoke test.

## 5. Deployment Flow

The deploy job is driven by Git state, not by a service job calling it.

```text
state/<env>.yaml → Verify → Deploy → Helm Test → Tag → Promote
```

### Verify
Checks the state shape, promotion history, Cosign signature and rendered chart. It also performs a Kubernetes server-side dry-run.

### Deploy
Uses the environment-specific ServiceAccount and runs `helm upgrade --install --wait` with the recorded image digest.

The workload therefore runs:

```text
repository@sha256:...
```

not a mutable image tag.

### Helm Test
Runs the chart tests after deployment. The base chart sends a real HTTP request through the Service. Additional service tests run with it.

If readiness fails, Helm rolls back automatically. If Helm tests fail, the previous revision is restored; a failed first install is removed.

### Tag
A healthy environment state is tagged:

```text
<environment>-<YYYY.MM.DD>.<n>
```

### Promote
After a healthy dev or stage release, Jenkins opens or refreshes a PR that copies the exact digest into the next environment state.

Prod can additionally run a 10% canary for 5 minutes and reject it when ingress 5xx rate exceeds 1%.

## 6. Versioning and Releases

### Application version
The service chart's `Chart.yaml.version` is the application release version.

The same version is used for:
- the image tag;
- the service chart version;
- the state entry.

A pull request that changes the service must increase this version.

### Base-chart version
`charts/service` has its own independent chart version. Application charts pin the base-chart version they consume.

### Image identity
Tags are readable release names. The digest is what is deployed.

```text
source revision → app version → image tag → sha256 digest → state → workload
```

If an application version already exists, CI checks its OCI source revision. The version may be reused only for the same service source; otherwise the release must be versioned again.

### Environment release
`state/<environment>.yaml` defines what should run in that environment.

Promotion changes state only:

```text
dev digest X → stage digest X → prod digest X
```

No rebuild occurs between environments.

Stage/prod promotion happens through pull requests. `CODEOWNERS` provides the human approval gate when branch protection requires code-owner review.

Rollback means returning Git state to an earlier proven release.

## 7. Optimizations

The pipeline was optimized by removing repeated work, not validation.

| Optimization | Effect |
|---|---|
| warm heavy/light/CD runners | avoids normal Kubernetes agent startup |
| persistent BuildKit cache | reuses image layers |
| persistent Trivy cache | avoids repeated vulnerability DB work |
| heavy/light runner split | verification does not queue behind image builds |
| heavy runner pinned to cache node | preserves local cache reuse |
| path-based service execution | unrelated changes skip heavy service CI |
| existing image/chart detection | avoids republishing the same release |
| state-driven CD | no rebuild, rescan or repackaging during deployment |

Measured for application release 1.2.14:

| Path | Time |
|---|---:|
| CI #27 | **1m26s** |
| CD #24 | **1m16s** |
| CI + CD execution | **2m42s** |

Warm heavy-runner acquisition was about **5s**, compared with roughly **51s** in an earlier run.

Jenkins polls GitHub every minute, so commit-to-live wall time can also include one discovery interval before service CI and another before CD.

## 8. Evidence and Limits

Release 1.2.14:

```text
1.2.14 → sha256:2758e8...dcd1824 → state commit 75769b4
       → deploy/main #24 → dev-2026.09.21.5
```

Implementation: [service template](delivery/pipeline/vars/servicePipeline.groovy) · [platform flow](delivery/Jenkinsfile.platform) · [deploy template](delivery/pipeline/vars/deployPipeline.groovy) · [scan](delivery/pipeline/resources/lab/delivery/scan-image.sh) · [publish/sign](delivery/pipeline/resources/lab/delivery/publish-image.sh) · [deploy](delivery/pipeline/resources/lab/delivery/deploy.sh).

Known limits:
- vulnerability policy blocks CRITICAL findings only;
- SBOM is archived but not signed/attested;
- Cosign uses no transparency-log upload;
- an untrafficked canary warns but still passes;
- the measured release proves dev; app stage/prod and prod canary remain implemented but unexercised.
