# Delivery
Evidence for what the delivery system **builds, proves, and knowingly trades away**. Operator commands stay in [delivery/README.md](delivery/README.md).

## Contents
1. [Delivery Contract](#1-delivery-contract)
2. [Topology](#2-topology)
3. [Service CI](#3-service-ci)
4. [Platform CI](#4-platform-ci)
5. [Artifact Identity](#5-artifact-identity)
6. [State, Promotion, Rollback](#6-state-promotion-rollback)
7. [Trust Boundaries](#7-trust-boundaries)
8. [Performance](#8-performance)
9. [Evidence](#9-evidence)
10. [Known Limits](#10-known-limits)
## 1. Delivery Contract
> **Build once · scan once · publish once · deploy by immutable digest.**
```text
Java change → Validate → JUnit/Maven → Build image → Scan/SBOM
                                              ↓ main
                                     Publish → Sign → state/dev.yaml
                                                         ↓
state/<env>.yaml → Verify → Deploy exact digest → Helm test → Tag → Promote
```
**Invariants:** scanned artifact = published artifact; published digest = state digest = deployed digest; CD never rebuilds; promotion moves the same digest; mutable tags never select runtime images.
## 2. Topology
One repository produces four Jenkins multibranch jobs:
```text
GitHub repo
├→ sample-java-app CI
├→ resource-requests-webhook CI
├→ platform CI
└→ deploy → state/<env>.yaml → one environment cluster
```
- `sample-java-app`: released by Jenkins.
- `resource-requests-webhook`: built/scanned/recorded by CI, installed by the operator via `make policies-up`.
- `platform`: repository and base-chart validation/publication.
- `deploy`: reconciles the cluster to `state/<environment>.yaml`.
- One cluster runs one `clusterEnvironment`; this lab cluster runs **dev**.
- Jenkins polls GitHub every minute; jobs do not call each other.
## 3. Service CI
```text
Validate → JUnit 5 / Spring tests → mvnw package → application.jar
   ↓
rootless BuildKit → Java 21 image → Trivy CRITICAL gate → CycloneDX SBOM
   ↓ main only
publish same OCI layout → digest equality → Cosign → state/dev.yaml
```
The Java build runs inside BuildKit. `mvnw package` executes:
- JUnit 5 `@WebMvcTest(HelloController)`: success, missing-parameter, and release-marker behavior.
- `@SpringBootTest`: application context load.
- executable JAR packaging.

PRs stop after validation/build/scan. `main` publishes the already-scanned OCI layout, checks registry digest equality, signs the digest, publishes the chart, then records `{version, digest}` in dev state.

**Failure/retry:** invalid version/chart/test/CVE/digest stops the release. CRITICAL findings block publication. A reused version is accepted only for the same service source revision. State push races refetch `main` and retry; an unrecorded release is retried by a later `main` build.
## 4. Platform CI
`delivery/Jenkinsfile.platform` keeps repository-wide checks separate from service builds:

| Ref | Check |
|---|---|
| all builds | `shellcheck` delivery/infra/platform/policies/validation scripts |
| chart PRs | `ct lint` + chart version increment |
| `main` | publish missing base-chart versions to OCI |

`charts/service` is the runtime safety contract: digest-addressed images, restricted pod defaults, probes, spreading, optional PDB, ingress, metrics, and a real HTTP Helm smoke test.
## 5. Artifact Identity
```text
source revision → version → image/chart tag → sha256 digest
                                               ↓
                             state/<env>.yaml → workload → release tag

1.2.14: 253d14cd... → 1.2.14 → sha256:2758e8... → 75769b4 → dev-2026.09.21.5
```
`Chart.yaml.version` is the human release version and image/chart tag. The **digest** is deployment identity.

For 1.2.14:
```yaml
sample-java-app:
  version: 1.2.14
  image: sha256:2758e8fba94b92423860dbb36245617c9163ad74fea23417308f17304dcd1824
```
CI embeds the service source revision in OCI metadata. If `:1.2.14` already exists from another revision, publication fails instead of moving the version.
## 6. State, Promotion, Rollback
`state/<env>.yaml` is the deploy interface.
```text
dev:   digest X → deploy/test/tag → promotion PR
                                  ↓
stage: digest X → deploy/test/tag → promotion PR
                                  ↓
prod:  digest X → deploy same artifact
```
- CI writes new releases directly to `state/dev.yaml` on `main`.
- Healthy dev/stage deployments open or refresh the next promotion PR.
- CD proves the exact digest existed in the previous environment before promotion.
- `.github/CODEOWNERS` owns stage/prod state; the gate exists **only while branch protection requires code-owner review**.
- Helm readiness failure uses `--rollback-on-failure`; failed Helm tests restore the previous revision (or uninstall a failed first install).
- Operator rollback is a PR restoring an earlier environment state/release tag; commands live in [delivery/README.md](delivery/README.md).

Prod implements a 10% / 5-minute canary with a 1% ingress 5xx threshold before stable rollout.
## 7. Trust Boundaries
```text
Vault → VSO → Jenkins credentials

jenkins-ci                GitHub main                jenkins-deploy-<env>
dry-run only ───────────→ state/dev.yaml ─────────→ own namespace only
✕ Kubernetes writes                                ✕ Secrets / other envs
```
- CI has RBAC needed for server-side dry-run; admission denies real CREATE/UPDATE/DELETE.
- CI **does** hold GitHub write authority to push `state/dev.yaml` to `main`. This is deliberate and depends on branch-protection policy.
- CD runs as `jenkins-deploy-<environment>`, scoped to that environment namespace only.
- CD cannot read Kubernetes Secrets; Helm history uses ConfigMaps.
- GitHub, registry, signing, and Jenkins credentials originate in Vault and are synchronized by Vault Secrets Operator; no cluster credential is stored in Jenkins.

Before deploy: state schema → promotion ancestry → Cosign signature → Helm render → server-side dry-run → environment-scoped Helm upgrade/test.
## 8. Performance
The optimization target was **reuse without removing gates**.

| Mechanism | Avoided work |
|---|---|
| 3 warm runner classes | normal pod provisioning |
| persistent BuildKit state | unchanged image layers |
| persistent Trivy cache | repeated vulnerability DB work |
| heavy/light CI split | verification queued behind image builds |
| node-3 cache locality | cache loss across workers |
| state-driven CD | rebuild/rescan/repackage in deployment |

Measured release 1.2.14:

| Pipeline | Time |
|---|---:|
| CI #27 | **1m26s** |
| CD #24 | **1m16s** |
| CI + CD execution | **2m42s** |

Warm heavy-runner acquisition was ~5s versus ~51s in an earlier cold/occupied run. Wall-clock commit → live also includes Git discovery: up to one 1-minute polling interval before service CI and another before CD.
## 9. Evidence
| Proof | Result |
|---|---|
| Java CI | `sample-java-app/main #27` · PASS |
| CD | `deploy/main #24` · PASS |
| state | `1.2.14 / sha256:2758e8...dcd1824` |
| state commit | `75769b4` · `Deploy sample-java-app 1.2.14 to dev` |
| healthy release tag | `dev-2026.09.21.5` |

Local Jenkins:
- `https://jenkins.lab.test/job/sample-java-app/job/main/27/flowGraphTable/`
- `https://jenkins.lab.test/job/deploy/job/main/24/flowGraphTable/`

Implementation: [service CI](delivery/pipeline/vars/servicePipeline.groovy) · [platform CI](delivery/Jenkinsfile.platform) · [CD](delivery/pipeline/vars/deployPipeline.groovy) · [build](delivery/pipeline/resources/lab/delivery/build-image.sh) · [scan](delivery/pipeline/resources/lab/delivery/scan-image.sh) · [publish/sign](delivery/pipeline/resources/lab/delivery/publish-image.sh) · [verify](delivery/pipeline/resources/lab/delivery/validate-release.sh) · [deploy](delivery/pipeline/resources/lab/delivery/deploy.sh).
## 10. Known Limits
- Vulnerability policy blocks **CRITICAL** findings only.
- CycloneDX SBOM is archived in Jenkins but is not signed/attested with the image.
- Cosign uses key verification with `--tlog-upload=false`; there is no transparency-log evidence.
- A prod canary that receives no traffic logs a warning but still passes; the metric gate therefore requires representative traffic.
- The current cluster is dev. The 1.2.14 evidence proves the dev path; sample-java-app stage/prod state is still `null`, so those deployments and the prod canary are **implemented, not demonstrated**.
