# Delivery
How software is built, released, and promoted in this repository.  
Operations: [delivery/README.md](delivery/README.md) · Jenkins: [platform/jenkins/README.md](platform/jenkins/README.md) · Runtime chart: [charts/service/README.md](charts/service/README.md)

## Contents
1. [Stack](#1-stack)
2. [Jenkins job model](#2-jenkins-job-model)
3. [Service CI](#3-service-ci)
4. [Platform CI](#4-platform-ci)
5. [Deployment](#5-deployment)
6. [Versioning and releases](#6-versioning-and-releases)
7. [Optimizations](#7-optimizations)
8. [Evidence and limits](#8-evidence-and-limits)

## 1. Stack
| Tool | Role |
|---|---|
| Jenkins | pipeline orchestration |
| Kubernetes | Jenkins agents and service runtime |
| Maven + JUnit | Java build and tests |
| rootless BuildKit | image build |
| Trivy | CRITICAL vulnerability gate + CycloneDX SBOM |
| Skopeo | publish the scanned OCI image |
| Cosign | image signing and verification |
| Helm + OCI | chart packaging, deployment, tests |
| Git | environment state, promotion, rollback |
| Vault + VSO | Jenkins credentials |
| Prometheus + ingress-nginx | prod canary signal |

Jenkins runs in Kubernetes through Helm + JCasC. Services run from Helm charts using image digests recorded in `state/<environment>.yaml`. Platform and infrastructure reconciliation remain operator-owned.

## 2. Jenkins job model
There are **four Jenkins jobs, but only three pipeline designs**:
```text
sample-java-app ─────────────┐
                            ├→ servicePipeline(chart, context, path)
resource-requests-webhook ──┘

platform ─────────────────────→ platform CI
deploy ───────────────────────→ state-driven CD
```

The two service jobs instantiate the same `servicePipeline` template from the pinned `lab-delivery` shared library. A service supplies only:
```text
chart path + build context + source path
```

| Job | Ownership |
|---|---|
| `sample-java-app` | Jenkins builds and releases it |
| `resource-requests-webhook` | Jenkins builds/scans/records it; operator installs it |
| `platform` | reusable repository and chart validation |
| `deploy` | reconcile Git environment state to a cluster |

Pipeline behavior stays centralized instead of being copied into each service.

## 3. Service CI
```text
Checkout → Validate → Build + Test → Scan → [main] Publish → Record
```

| Stage | Purpose | Output |
|---|---|---|
| **Checkout** | establish service identity and release context | chart/state + last commit touching the service path |
| **Validate** | reject an invalid release before publication | linted Dockerfile, valid version, rendered/dry-run chart |
| **Build + Test** | test and package once | tested `application.jar` inside one OCI image layout |
| **Scan** | gate known critical vulnerabilities | Trivy result + CycloneDX SBOM |
| **Publish** | publish the bytes that were scanned | signed image digest + OCI service chart |
| **Record** | make the release deployable | `{version, digest}` committed to dev state |

BuildKit runs `mvnw package`; tests include `@WebMvcTest(HelloController)` and `@SpringBootTest`.

Pull requests validate, build, and scan. Publication and state recording are `main`-only. Publication fails if the registry digest differs from the scanned digest or an existing version belongs to another service source revision.

The state commit is the hand-off to CD; Service CI never calls the deploy job directly.

## 4. Platform CI
```text
Shellcheck → [chart PR] ct lint → [main] publish base charts
```

| Stage | Purpose |
|---|---|
| **Shellcheck** | validate shared shell code |
| **Chart lint** | validate chart changes and require a version increment |
| **Chart publish** | publish missing base-chart versions to OCI |

`charts/service` is the shared runtime contract: digest images, security defaults, probes, topology spreading, optional PDB, ingress/metrics, and the HTTP Helm smoke test. Application charts pin the base-chart version they consume.

## 5. Deployment
```text
state/<env>.yaml → Verify → Deploy → Helm Test → Tag → Promote
```

| Stage | Purpose | Result |
|---|---|---|
| **Verify** | prove state and artifact are acceptable | promotion history, signature, render, server dry-run |
| **Deploy** | reconcile cluster to Git state | Helm release using the recorded digest |
| **Helm Test** | prove the rollout serves traffic | HTTP smoke test + service tests |
| **Tag** | mark a healthy environment state | `<environment>-<YYYY.MM.DD>.<n>` |
| **Promote** | move the proven artifact forward | PR copying the same digest to the next environment |

Runtime uses `repository@sha256:...`; mutable tags are never resolved by the workload.

Readiness failure triggers Helm rollback. Failed Helm tests restore the previous revision; a failed first install is removed. Each cluster runs one configured environment. Prod can additionally run a 10% canary for five minutes and reject it when ingress 5xx exceeds 1%.

## 6. Versioning and releases
### Application version
The service `Chart.yaml.version` is the application release version:
```text
application version = image tag = service chart version = state version
```
A service-changing PR must increase it.

### Base-chart version
`charts/service` has its own version. Applications pin the version they consume.

### Artifact identity
```text
source revision → app version → image tag → sha256 digest → state → workload
```
The version is the human release name. The digest is the runtime identity. An existing application version may be reused only when its OCI source revision matches the same service source.

### Environment release
`state/<environment>.yaml` defines what should run:
```text
dev digest X → stage digest X → prod digest X
```
Promotion copies state; it does not rebuild. Stage/prod changes use pull requests. CODEOWNERS is the human gate when branch protection requires code-owner review. Rollback restores an earlier environment state through Git.

## 7. Optimizations
The pipeline removes repeated work without removing validation.

| Area | Optimization | Effect |
|---|---|---|
| startup | warm heavy / light / CD runners | avoids normal Kubernetes agent startup |
| build | persistent BuildKit cache | reuses image layers and Maven dependency layer |
| scan | persistent Trivy cache | reuses vulnerability data |
| scheduling | heavy/light split | validation does not queue behind builds |
| locality | heavy runner pinned to cache node | preserves local cache reuse |
| scope | path-based service execution | unrelated changes skip heavy CI |
| publish | existing image/chart detection | avoids republishing |
| deploy | state-driven CD | no rebuild or rescan |
| deploy | current-release check | skips Helm when version + digest already run |

Measured on application release 1.2.14:

| Path | Time |
|---|---:|
| CI #27 | **1m26s** |
| CD #24 | **1m16s** |
| total pipeline execution | **2m42s** |

Warm heavy-runner acquisition was ~5s versus ~51s earlier. Jenkins polls GitHub every minute, so commit-to-live can also include one polling interval before CI and another before CD.

## 8. Evidence and limits
```text
1.2.14
  → sha256:2758e8...dcd1824
  → state commit 75769b4
  → deploy/main #24
  → dev-2026.09.21.5
```

Implementation: [service pipeline](delivery/pipeline/vars/servicePipeline.groovy) · [platform pipeline](delivery/Jenkinsfile.platform) · [deploy pipeline](delivery/pipeline/vars/deployPipeline.groovy) · [scan](delivery/pipeline/resources/lab/delivery/scan-image.sh) · [publish/sign](delivery/pipeline/resources/lab/delivery/publish-image.sh) · [deploy](delivery/pipeline/resources/lab/delivery/deploy.sh)

Known limits:
- vulnerability gate is CRITICAL-only;
- SBOM is archived but not signed/attested;
- Cosign does not upload to a transparency log;
- a canary with no traffic warns but still passes;
- application stage/prod deployment and prod canary are implemented but not exercised in this lab.
