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
| Trivy | vulnerability scan and CycloneDX SBOM |
| Skopeo | image publication |
| Cosign | image signing and verification |
| Helm + OCI | chart publication and deployment |
| Git | environment state and promotion history |
| Vault + Vault Secrets Operator | Jenkins credentials |
| Prometheus + ingress-nginx | prod canary metric |

Jenkins is installed in Kubernetes with Helm and configured through JCasC. See [platform/jenkins/README.md](platform/jenkins/README.md).

Applications are deployed with Helm. Image digests are read from `state/<environment>.yaml`.

Platform and infrastructure changes are applied through the operator workflows documented in [delivery/README.md](delivery/README.md); Jenkins does not apply them.

## 2. Jenkins jobs

JCasC defines four multibranch jobs and three pipeline implementations:

```text
sample-java-app ─────────────┐
                            ├→ servicePipeline(chart, context, path)
resource-requests-webhook ──┘

platform ─────────────────────→ Jenkinsfile.platform
deploy ───────────────────────→ deployPipeline()
```

The service jobs use `servicePipeline` from the `lab-delivery` shared library. Each service provides:

```text
chart path + build context + source path
```

| Job | Pipeline | Deployment owner |
|---|---|---|
| `sample-java-app` | `servicePipeline` | Jenkins |
| `resource-requests-webhook` | `servicePipeline` | operator |
| `platform` | `Jenkinsfile.platform` | n/a |
| `deploy` | `deployPipeline` | Jenkins |

The shared library is configured centrally in JCasC and loaded from `main`.

## 3. Service CI

```text
Checkout → Validate → Build + Test → Scan → Publish → Record
                                         PR stops here ─┘
```

### Checkout
Reads the service chart, environment configuration, and current state.  
`SERVICE_REVISION` is the last commit that modified the service path.

### Validate
- runs Hadolint;
- requires a chart version bump on service-changing PRs;
- renders the Helm chart;
- runs Kubernetes server-side dry-run for Jenkins-released services.

### Build + Test
BuildKit creates one OCI image layout.

The Java build runs `mvnw package`, which executes:
- `@WebMvcTest(HelloController)`;
- `@SpringBootTest`;
- executable JAR packaging.

The runtime image receives the resulting `application.jar`.

### Scan
Trivy scans the local OCI image layout. CRITICAL findings fail the build.

The same Trivy report is used to produce the CycloneDX SBOM.

### Publish
Runs on `main` only.

Skopeo pushes the scanned OCI layout to the registry. The pushed digest must match the scanned digest.

Cosign signs `repository@digest`. The service chart is published to the OCI registry.

### Record
CI writes the release to dev state:

```yaml
version: 1.2.14
image: sha256:...
```

This Git commit is the input to the deploy job. The service job does not call the deploy job directly.

For `resource-requests-webhook`, CI records the release but deployment remains operator-owned.

## 4. Platform CI

```text
Shellcheck → [chart PR] ct lint → [main] publish charts
```

### Shellcheck
Runs against shell code under delivery, infra, platform, policies, and validation.

### Chart lint
Chart pull requests run `ct lint --check-version-increment`.

### Chart publish
On `main`, chart versions not already present in the OCI registry are published.

`charts/service` is the base chart used by application charts. It contains the common Deployment, Service, security defaults, probes, topology spreading, optional PDB, ingress, metrics, and HTTP Helm test. See [charts/service/README.md](charts/service/README.md).

## 5. Deployment

```text
state/<env>.yaml → Verify → Deploy → Helm Test → Tag → Promote
```

### Verify
The deploy pipeline checks:
- state schema;
- previous-environment history for the digest;
- Cosign signature;
- Helm rendering;
- Kubernetes server-side dry-run.

### Deploy
The target environment uses `jenkins-deploy-<environment>`.

Helm deploys the digest stored in state:

```text
repository@sha256:...
```

### Helm test
After rollout, Helm runs the base HTTP smoke test and any service-specific tests.

Readiness failure uses Helm rollback. A failed Helm test restores the previous revision; a failed first install is uninstalled.

### Tag
A successful environment state is tagged as:

```text
<environment>-<YYYY.MM.DD>.<n>
```

### Promote
A successful dev or stage deployment opens or updates a PR for the next environment. The PR copies the same `{version, digest}`.

Prod can run a 10% canary for five minutes. The canary fails when ingress 5xx rate exceeds 1%.

Each cluster runs one `clusterEnvironment`.

## 6. Versioning and releases

### Application
The application release version is `Chart.yaml.version`.

```text
Chart.yaml.version
    ├→ image tag
    ├→ service chart version
    └→ state version
```

Service-changing PRs must increment it.

### Base chart
`charts/service` has an independent chart version. Application charts pin the version they use.

### Image
Images are published with a version tag but deployed by digest.

```text
service source revision → version → image tag → digest → state → workload
```

If a version already exists, its OCI source revision must match the current service source revision. Otherwise publication fails.

### Environment state
`state/<environment>.yaml` contains the release selected for each service.

```text
dev {version,digest} → stage {same} → prod {same}
```

Stage and prod changes are made through pull requests. `CODEOWNERS` covers the stage/prod state files; enforcement depends on branch protection requiring code-owner review.

Rollback is a Git change restoring an earlier environment state.

## 7. Pipeline optimizations

| Mechanism | Behavior |
|---|---|
| warm heavy/light/CD runners | agents remain available between builds |
| persistent BuildKit state | image layers and Maven dependency layer are reused |
| persistent Trivy cache | vulnerability data is reused |
| heavy/light runner split | lightweight validation uses a separate runner |
| node affinity for heavy CI | BuildKit/Trivy host caches remain local |
| service path filtering | unrelated changes skip service CI |
| existing image/chart checks | existing artifacts are not republished |
| state-driven CD | deployment does not rebuild or rescan |
| current-release check | Helm is skipped when version and digest already match |

Measured for release `1.2.14`:

| Pipeline | Duration |
|---|---:|
| service CI #27 | **1m26s** |
| deploy #24 | **1m16s** |
| combined execution | **2m42s** |

Warm heavy-runner acquisition measured ~5s; an earlier cold/occupied run measured ~51s.

Jenkins polls GitHub every minute, so wall-clock delivery can include one polling interval before service CI and another before deployment.

## 8. Evidence and known limits

Release trace:

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
- a canary with no traffic logs a warning and passes;
- the application release trace above covers dev; application stage/prod deployment and the prod canary have not been exercised in this lab.
