# Delivery
How software is built, released and promoted in this repository.  
Operations: [delivery/README.md](delivery/README.md) · Jenkins: [platform/jenkins/README.md](platform/jenkins/README.md) · Runtime chart: [charts/service/README.md](charts/service/README.md)

## Contents
1. [Stack](#1-stack)
2. [Jenkins jobs](#2-jenkins-jobs)
3. [Service CI](#3-service-ci)
4. [Platform CI](#4-platform-ci)
5. [Deployment](#5-deployment)
6. [Versioning and releases](#6-versioning-and-releases)
7. [Optimizations](#7-optimizations)
8. [Evidence and limits](#8-evidence-and-limits)

## 1. Stack
| Tool | Purpose |
|---|---|
| Jenkins | CI/CD orchestration |
| Kubernetes | Jenkins agents + service runtime |
| Maven + JUnit | Java build and tests |
| rootless BuildKit | image build |
| Trivy | CRITICAL gate + CycloneDX SBOM |
| Skopeo | publish the scanned OCI image |
| Cosign | sign / verify image digests |
| Helm + OCI | charts, deployment, tests |
| Git | desired state, promotion, rollback |
| Vault + VSO | Jenkins credentials |
| Prometheus + ingress-nginx | prod canary check |

Jenkins runs in Kubernetes through Helm + JCasC. Services are deployed with Helm from image digests stored in `state/<environment>.yaml`. Platform/infra reconciliation stays operator-owned; Jenkins validates it but does not apply it.

## 2. Jenkins jobs
```text
sample-java-app ─────────────┐
                            ├→ servicePipeline(chart, context, path)
resource-requests-webhook ──┘

platform ─────────────────────→ repository / base-chart CI
deploy ───────────────────────→ state-driven CD
```

JCasC creates four multibranch jobs. The two service jobs are instances of the same `servicePipeline` template. A service supplies only its chart path, build context and source path; the shared `lab-delivery` library owns the behavior.

| Job | Responsibility |
|---|---|
| `sample-java-app` | build, test, scan, publish and release through Jenkins |
| `resource-requests-webhook` | build, scan and record; operator installs it |
| `platform` | validate scripts/charts and publish base charts |
| `deploy` | reconcile environment state to the cluster |

The library is pinned to `main`; service branches cannot replace their own pipeline logic.

## 3. Service CI
```text
Checkout → Validate → Build + Test → Scan → [main] Publish → Record
```

| Stage | What happens |
|---|---|
| **Checkout** | Reads chart/state and records the last commit that changed the service path as its source revision. |
| **Validate** | Lints the Dockerfile, checks version progression, renders Helm and performs Kubernetes server-side dry-run. |
| **Build + Test** | BuildKit builds once; Maven runs JUnit/Spring tests and packages `application.jar`. |
| **Scan** | Trivy scans the local OCI image; CRITICAL findings fail CI; the same report produces the CycloneDX SBOM. |
| **Publish** | `main` only. Skopeo pushes the same OCI layout that was scanned; registry digest must match; Cosign signs it; chart is published. |
| **Record** | CI writes `{version, digest}` to dev state. That Git commit becomes CD input. |

The app tests include `@WebMvcTest(HelloController)` and `@SpringBootTest`. A service-changing PR must bump its chart version. Test, scan, source/version or digest failures stop publication.

For Jenkins-released services, recording state starts the release path. Operator-owned services stop after build/record.

## 4. Platform CI
```text
Shellcheck → [chart PR] ct lint → [main] publish base charts
```

| Stage | What happens |
|---|---|
| **Shellcheck** | Validates shell code across delivery, platform, infra, policies and validation. |
| **Chart lint** | Chart PRs run `ct lint` and must increase the chart version. |
| **Chart publish** | `main` publishes missing base-chart versions; existing versions are skipped. |

`charts/service` is the reusable runtime contract inherited by services: digest images, security defaults, probes, spreading, optional PDB, ingress/metrics and the standard HTTP Helm smoke test.

## 5. Deployment
```text
state/<env>.yaml → Verify → Deploy → Helm Test → Tag → Promote
```

| Stage | What happens |
|---|---|
| **Verify** | Checks state shape, promotion history, Cosign signature, Helm render and server-side dry-run. |
| **Deploy** | Uses `jenkins-deploy-<environment>` and runs Helm with the recorded image digest. |
| **Helm Test** | Runs the base HTTP smoke test plus service tests. Failed readiness/test rolls back the release. |
| **Tag** | Healthy state receives `<environment>-<YYYY.MM.DD>.<n>`. |
| **Promote** | Jenkins opens/refreshes a PR that copies the same digest to the next environment. |

Runtime uses `repository@sha256:...`, not mutable tags. Prod can run a 10% canary for five minutes and reject it when ingress 5xx rate exceeds 1%.

## 6. Versioning and releases
### Application version
The service `Chart.yaml.version` is the application release version:
```text
application version = image tag = service chart version = state version
```
A service-changing PR must increase it.

### Base-chart version
`charts/service` is versioned independently. Application charts pin the base-chart version they consume.

### Image identity
```text
source revision → app version → image tag → sha256 digest → state → workload
```
Tags are readable names. The digest is the runtime identity. If an application version already exists, its OCI source revision must match the same service source; otherwise publication fails.

### Environment release
`state/<environment>.yaml` defines what should run.
```text
dev digest X → stage digest X → prod digest X
```
Promotion copies the digest; it does not rebuild. Stage/prod promotion uses pull requests. CODEOWNERS is the approval gate when branch protection requires code-owner review. Rollback restores an earlier environment state through Git.

## 7. Optimizations
| Optimization | Effect |
|---|---|
| warm heavy / light / CD runners | avoids normal agent startup |
| persistent BuildKit cache | reuses image layers |
| persistent Trivy cache | reuses vulnerability data |
| heavy/light split | verification does not wait behind builds |
| heavy runner cache affinity | preserves local cache reuse |
| path-based service execution | unrelated changes skip heavy CI |
| existing image/chart detection | avoids republishing |
| state-driven CD | no rebuild/rescan during deployment |
| current-release check | skips Helm when version + digest already run |

Measured on release 1.2.14:

| Path | Time |
|---|---:|
| CI #27 | **1m26s** |
| CD #24 | **1m16s** |
| total pipeline execution | **2m42s** |

Warm heavy-runner acquisition was ~5s versus ~51s earlier. Jenkins polls GitHub every minute, so commit-to-live can additionally include one polling interval before CI and another before CD.

## 8. Evidence and limits
```text
1.2.14 → sha256:2758e8...dcd1824 → state commit 75769b4
       → deploy/main #24 → dev-2026.09.21.5
```

Implementation: [service pipeline](delivery/pipeline/vars/servicePipeline.groovy) · [platform pipeline](delivery/Jenkinsfile.platform) · [deploy pipeline](delivery/pipeline/vars/deployPipeline.groovy) · [scan](delivery/pipeline/resources/lab/delivery/scan-image.sh) · [publish/sign](delivery/pipeline/resources/lab/delivery/publish-image.sh) · [deploy](delivery/pipeline/resources/lab/delivery/deploy.sh)

Known limits:
- vulnerability gate is CRITICAL-only;
- SBOM is archived but not signed/attested;
- Cosign does not upload to a transparency log;
- a canary with no traffic warns but still passes;
- application stage/prod deployment and prod canary are implemented but not exercised in this lab.
