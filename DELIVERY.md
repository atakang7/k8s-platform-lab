# Delivery
CI/CD reference. Operations: [delivery/README.md](delivery/README.md) · Jenkins: [platform/jenkins/README.md](platform/jenkins/README.md) · Base chart: [charts/service/README.md](charts/service/README.md)

## Stack
Jenkins on Kubernetes · JCasC · Maven/JUnit · rootless BuildKit · Trivy · Skopeo · Cosign · Helm/OCI · Vault/VSO · Prometheus

Applications deploy from image digests stored in `state/<environment>.yaml`. Platform and infrastructure reconciliation is operator-owned.

## Jenkins jobs

Four multibranch jobs, three pipeline implementations:

```text
sample-java-app ─────────────┐
                            ├→ servicePipeline(chart, context, path)
resource-requests-webhook ──┘

platform ─────────────────────→ Jenkinsfile.platform
deploy ───────────────────────→ deployPipeline()
```

`servicePipeline` lives in the pinned `lab-delivery` shared library. A service provides only its chart path, build context, and source path.

### Reusable templates

```text
service Jenkinsfile
      ↓
servicePipeline(chart, context, path)
      ↓
validate → build/test → scan → publish → record state
```

`servicePipeline` is the standard **service release template**. Use it for a component that produces a container image and Helm chart. It owns CI behavior; the service only identifies where its source and chart live.

```text
state/<env>.yaml
      ↓
deployPipeline()
      ↓
verify → deploy → test → tag → promote
```

`deployPipeline` is the standard **environment deployment template**. It reads configured releases from Git state and reconciles only the cluster's `clusterEnvironment`.

```text
application chart
      ↓
charts/service
      ↓
Deployment · Service · probes · security · ingress · metrics · smoke test
```

`charts/service` is the **runtime Helm template** shared by stateless HTTP services. Application charts pin a version and provide service-specific values.

| Job | Role |
|---|---|
| `sample-java-app` | Jenkins-managed service |
| `resource-requests-webhook` | CI-managed artifact; operator-managed deployment |
| `platform` | repository/chart validation + base-chart publication |
| `deploy` | state-driven CD |

## Service CI

```text
Checkout → Validate → Build/Test → Scan → [main] Publish → Record
```

| Stage | Work |
|---|---|
| Checkout | read chart/state; derive `SERVICE_REVISION` from the service path |
| Validate | Hadolint · version bump · Helm render · server-side dry-run |
| Build/Test | one BuildKit build; `mvnw package` runs JUnit/Spring tests and produces `application.jar` |
| Scan | Trivy CRITICAL gate + CycloneDX SBOM from the same report |
| Publish | push the scanned OCI layout; verify digest equality; Cosign sign; publish chart |
| Record | commit `{version,digest}` to dev state |

PRs stop after scan. Publish/record run on `main`.

The service job never calls CD. Its state commit is the deploy trigger.

Existing versions are accepted only when their OCI source revision matches the current service source revision.

## Platform CI

```text
Shellcheck → [chart PR] ct lint --check-version-increment → [main] publish charts
```

`charts/service` carries the shared runtime defaults: digest images, restricted security context, probes, topology spreading, optional PDB, ingress/metrics, and the HTTP Helm test.

## Deployment

```text
state/<env>.yaml → Verify → Helm deploy → Helm test → Tag → Promote
```

| Stage | Work |
|---|---|
| Verify | state schema · previous-env digest history · Cosign · Helm render · server dry-run |
| Deploy | `jenkins-deploy-<env>` runs Helm with `repository@sha256:...` |
| Test | base HTTP smoke test + service tests |
| Tag | `<environment>-<YYYY.MM.DD>.<n>` |
| Promote | PR copies the same `{version,digest}` to the next environment |

Readiness failure uses Helm rollback. Failed Helm tests restore the previous revision; failed first installs are removed.

Prod supports a 10% / 5-minute canary with a 1% ingress 5xx threshold. One cluster runs one `clusterEnvironment`.

## Versioning and releases

```text
Chart.yaml.version
    ├→ image tag
    ├→ service chart version
    └→ state version

source revision → version → image tag → digest → state → workload

dev {version,digest} → stage {same} → prod {same}
```

- Service-changing PRs increment `Chart.yaml.version`.
- Images are tagged by version but deployed by digest.
- `charts/service` is versioned independently and pinned by application charts.
- Stage/prod state changes use PRs; CODEOWNERS is enforced when branch protection requires owner review.
- Rollback restores an earlier Git state.

## Optimizations

| Mechanism | Result |
|---|---|
| warm heavy/light/CD runners | agent acquisition ~51s → ~5s |
| persistent BuildKit state | image + Maven layer reuse |
| persistent Trivy cache | vulnerability DB reuse |
| heavy/light split | verification does not queue behind builds |
| cache-node affinity | host caches stay warm |
| path filtering | unrelated changes skip service CI |
| artifact existence checks | no duplicate publish |
| state-driven CD | no rebuild/rescan on deploy |
| current-release check | no-op releases skip Helm |

Release `1.2.14`: **CI 1m26s · CD 1m16s · combined 2m42s**.

Jenkins polls GitHub every minute; wall-clock delivery can include one polling interval before CI and one before CD.

## Evidence

```text
1.2.14 → sha256:2758e8...dcd1824 → state commit 75769b4
       → deploy/main #24 → dev-2026.09.21.5
```

Implementation: [service](delivery/pipeline/vars/servicePipeline.groovy) · [platform](delivery/Jenkinsfile.platform) · [deploy](delivery/pipeline/vars/deployPipeline.groovy) · [build](delivery/pipeline/resources/lab/delivery/build-image.sh) · [scan](delivery/pipeline/resources/lab/delivery/scan-image.sh) · [publish](delivery/pipeline/resources/lab/delivery/publish-image.sh) · [verify](delivery/pipeline/resources/lab/delivery/validate-release.sh)

## Known limits

CRITICAL-only vulnerability gate · SBOM not attested · Cosign transparency-log upload disabled · no-traffic canary warns and passes · app stage/prod/canary paths are implemented but not exercised in this lab.
