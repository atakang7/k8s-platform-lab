# Delivery
CI/CD reference for this repository.  
Operations: [delivery/README.md](delivery/README.md) · Jenkins deployment: [platform/jenkins/README.md](platform/jenkins/README.md) · Service chart: [charts/service/README.md](charts/service/README.md)

## 1. Delivery stack
| Component | Use |
|---|---|
| Jenkins | pipeline execution |
| Kubernetes | Jenkins agents and application runtime |
| Maven + JUnit | Java build and tests |
| rootless BuildKit | container image build |
| Trivy | vulnerability scan + CycloneDX SBOM |
| Skopeo | image publication |
| Cosign | image signing and verification |
| Helm + OCI | chart publication and deployment |
| Git | environment state, promotion, rollback |
| Vault + VSO | Jenkins credentials |
| Prometheus + ingress-nginx | prod canary metric |

Jenkins runs in Kubernetes through Helm + JCasC. Applications are deployed with Helm from digests in `state/<environment>.yaml`. Platform/infra reconciliation is operator-owned.

## 2. Jenkins jobs
JCasC defines four multibranch jobs and three pipeline implementations:

```text
sample-java-app ─────────────┐
                            ├→ servicePipeline(chart, context, path)
resource-requests-webhook ──┘

platform ─────────────────────→ Jenkinsfile.platform
deploy ───────────────────────→ deployPipeline()
```

The service jobs use the shared `lab-delivery` library and provide only:
```text
chart path + build context + source path
```

| Job | Pipeline | Deployment owner |
|---|---|---|
| `sample-java-app` | `servicePipeline` | Jenkins |
| `resource-requests-webhook` | `servicePipeline` | operator |
| `platform` | `Jenkinsfile.platform` | n/a |
| `deploy` | `deployPipeline` | Jenkins |

The shared library is configured in JCasC and loaded from `main`.

## 3. Service CI
```text
Checkout → Validate → Build + Test → Scan → Publish → Record
                                         PR stops here ─┘
```

| Stage | Action |
|---|---|
| **Checkout** | Read chart/environment/state; set `SERVICE_REVISION` to the last commit touching the service path. |
| **Validate** | Run Hadolint, require service version bump on PRs, render Helm, run server-side dry-run for Jenkins-released services. |
| **Build + Test** | Build one OCI layout with BuildKit; `mvnw package` runs `@WebMvcTest`, `@SpringBootTest`, and packages `application.jar`. |
| **Scan** | Scan the local OCI layout with Trivy; CRITICAL findings fail; convert the same report to CycloneDX SBOM. |
| **Publish** | `main` only. Push the scanned OCI layout with Skopeo, require matching digest, sign `repository@digest`, publish service chart. |
| **Record** | Commit `{version, digest}` to dev state. This Git commit becomes deploy input. |

The service job does not call the deploy job. `resource-requests-webhook` is recorded by CI but installed by the operator.

Publication also fails when an existing version belongs to another service source revision.

## 4. Platform CI
```text
Shellcheck → [chart PR] ct lint → [main] publish charts
```

| Stage | Action |
|---|---|
| **Shellcheck** | Check shell code under delivery, infra, platform, policies, and validation. |
| **Chart lint** | Run `ct lint --check-version-increment` on chart PRs. |
| **Chart publish** | Publish chart versions missing from the OCI registry. |

`charts/service` is the base chart used by applications. It contains the common Deployment, Service, security defaults, probes, topology spreading, optional PDB, ingress, metrics, and HTTP Helm test.

## 5. Deployment
```text
state/<env>.yaml → Verify → Deploy → Helm Test → Tag → Promote
```

| Stage | Action |
|---|---|
| **Verify** | Check state schema, previous-environment digest history, Cosign signature, Helm render, and server-side dry-run. |
| **Deploy** | Use `jenkins-deploy-<environment>`; run Helm with the digest stored in state. |
| **Helm Test** | Run the base HTTP smoke test and service tests. Readiness failure rolls back; failed tests restore the previous revision or uninstall a failed first install. |
| **Tag** | Tag successful state as `<environment>-<YYYY.MM.DD>.<n>`. |
| **Promote** | Open/update a PR copying the same `{version, digest}` to the next environment. |

Runtime images use `repository@sha256:...`.

Prod can run a 10% canary for five minutes; ingress 5xx above 1% fails the canary. Each cluster runs one `clusterEnvironment`.

## 6. Versioning and releases
### Application
`Chart.yaml.version` is the application release version:
```text
Chart.yaml.version → image tag
                   → service chart version
                   → state version
```
Service-changing PRs must increment it.

### Base chart
`charts/service` has its own version. Application charts pin the version they use.

### Image
Images are published with a version tag and deployed by digest:
```text
service source revision → version → image tag → digest → state → workload
```
If a version already exists, its OCI source revision must match the current service source revision.

### Environment state
`state/<environment>.yaml` selects the release for each service:
```text
dev {version,digest} → stage {same} → prod {same}
```
Stage/prod changes use pull requests. `CODEOWNERS` covers stage/prod state; enforcement depends on branch protection requiring code-owner review. Rollback restores earlier environment state through Git.

## 7. Pipeline optimizations
| Mechanism | Behavior |
|---|---|
| warm heavy/light/CD runners | keep agents available between builds |
| persistent BuildKit state | reuse image layers and Maven dependency layer |
| persistent Trivy cache | reuse vulnerability data |
| heavy/light runner split | run lightweight validation separately |
| heavy CI node affinity | keep BuildKit/Trivy host caches local |
| service path filtering | skip service CI for unrelated changes |
| existing image/chart checks | skip republishing existing artifacts |
| state-driven CD | deploy without rebuild/rescan |
| current-release check | skip Helm when version + digest already match |

Measured for release `1.2.14`:

| Pipeline | Duration |
|---|---:|
| service CI #27 | **1m26s** |
| deploy #24 | **1m16s** |
| combined execution | **2m42s** |

Warm heavy-runner acquisition measured ~5s; an earlier cold/occupied run measured ~51s. Jenkins polling can add one interval before service CI and another before deployment.

## 8. Evidence and known limits
```text
1.2.14
  → sha256:2758e8...dcd1824
  → state commit 75769b4
  → deploy/main #24
  → dev-2026.09.21.5
```

Implementation: [service pipeline](delivery/pipeline/vars/servicePipeline.groovy) · [platform pipeline](delivery/Jenkinsfile.platform) · [deploy pipeline](delivery/pipeline/vars/deployPipeline.groovy) · [build](delivery/pipeline/resources/lab/delivery/build-image.sh) · [scan](delivery/pipeline/resources/lab/delivery/scan-image.sh) · [publish](delivery/pipeline/resources/lab/delivery/publish-image.sh) · [validate](delivery/pipeline/resources/lab/delivery/validate-release.sh) · [deploy](delivery/pipeline/resources/lab/delivery/deploy.sh)

Known limits:
- vulnerability gate checks CRITICAL findings only;
- SBOM is archived but not signed or attested;
- Cosign transparency-log upload is disabled;
- a canary with no traffic warns and passes;
- the application trace above covers dev; application stage/prod deployment and prod canary have not been exercised in this lab.
