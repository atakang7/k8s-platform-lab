# Delivery
This document explains the delivery model: how source becomes a trusted artifact, how that artifact becomes desired state, and how desired state becomes a release. Operating commands live in [delivery/README.md](delivery/README.md).

## Contents
1. [Delivery Model](#1-delivery-model)
2. [CI Contract](#2-ci-contract)
3. [Artifact Integrity](#3-artifact-integrity)
4. [State as Release Intent](#4-state-as-release-intent)
5. [Promotion and Rollback](#5-promotion-and-rollback)
6. [Trust and Authority](#6-trust-and-authority)
7. [Execution Efficiency](#7-execution-efficiency)
8. [Evidence](#8-evidence)
9. [Known Limits](#9-known-limits)

## 1. Delivery Model
> **Build once · scan once · publish once · move the same digest forward.**

```text
source
  → validate + test
  → build image
  → scan
  → publish + sign
  → record digest in Git
  → verify
  → deploy exact digest
  → test release
  → promote same digest
```

Three boundaries matter:

- **CI creates artifacts.**
- **Git declares what should run.**
- **CD reconciles a cluster to that declaration.**

CD never rebuilds the application. Promotion never creates a new artifact.

## 2. CI Contract
Service changes must prove both **application correctness** and **release correctness** before publication.

```text
Java source
  → JUnit / Spring tests
  → mvnw package
  → application.jar
  → Java 21 runtime image
  → Trivy CRITICAL gate
  → CycloneDX SBOM
  → [main] publish + sign
```

The Java path includes `@WebMvcTest(HelloController)`, `@SpringBootTest`, and executable JAR packaging.

Release validation also checks the Dockerfile, version progression, Helm rendering, and a server-side Kubernetes dry-run.

Pull requests stop after validation/build/scan. `main` may publish.

Platform changes use a different contract: shell validation, chart lint/version checks, and base-chart publication. The point is the same: **validate the reusable platform contract before services inherit it.**

## 3. Artifact Integrity
The central invariant is:

> **The artifact that was scanned is the artifact that is deployed.**

```text
OCI layout
  → Trivy scan
  → Skopeo push
  → registry digest check
  → Cosign signature
  → state/<env>.yaml
  → workload image@sha256:...
```

The registry digest must equal the scanned manifest digest. Runtime manifests use `repository@sha256:...`, never a mutable tag.

`Chart.yaml.version` is the human release version. The digest is runtime identity.

A published version may be reused only when its OCI source revision matches the same service source revision; otherwise publication fails.

## 4. State as Release Intent
`state/<environment>.yaml` is the deployment interface.

```text
CI artifact
  → { version, digest }
  → state/dev.yaml
  → CD
  → running workload
```

CI writes newly published releases to dev state. CD reads state; it does not infer a release from image tags or source branches.

This separation makes the release decision explicit and auditable: **artifact creation and deployment intent are different events.**

## 5. Promotion and Rollback
Promotion moves proven state forward:

```text
dev:   digest X → deploy/test/tag
                    ↓
stage: digest X → deploy/test/tag
                    ↓
prod:  digest X → deploy
```

Before accepting a later environment, CD proves that the same digest existed in the previous environment.

Stage/prod changes are promoted through pull requests; `CODEOWNERS` provides the human gate when branch protection requires code-owner review.

Deployment failure is handled at the release boundary:
- readiness failure → Helm automatic rollback;
- Helm test failure → restore previous revision;
- failed first install → uninstall;
- operator rollback → restore earlier Git state.

Prod additionally implements a 10% canary for 5 minutes with a 1% ingress 5xx threshold.

## 6. Trust and Authority
Delivery intentionally separates **artifact authority**, **state authority**, and **cluster authority**.

```text
CI
  → may publish artifacts
  → may push state/dev.yaml to main
  → may dry-run Kubernetes objects
  ✕ may not mutate the cluster

CD
  → may deploy only its environment
  ✕ may not read Kubernetes Secrets
  ✕ may not deploy other environments
```

The important edge is that CI **does have GitHub write authority** for dev state. That is deliberate automation authority, not cluster authority.

Credentials originate in Vault and are synchronized into Jenkins by Vault Secrets Operator. No cluster credential is stored in Jenkins.

Before deployment, CD checks: **state schema → promotion ancestry → signature → server-side dry-run → Helm deploy/test**.

## 7. Execution Efficiency
Performance work removes repeated work without removing gates.

| Mechanism | Avoided work |
|---|---|
| warm execution classes | normal agent startup |
| persistent BuildKit / Trivy caches | repeated build and scan work |
| heavy / light execution split | verification waiting behind builds |
| cache locality | losing warm build state |
| state-driven CD | rebuild / rescan / repackage |

Measured on release 1.2.14:

| Path | Time |
|---|---:|
| CI #27 | **1m26s** |
| CD #24 | **1m16s** |
| CI + CD execution | **2m42s** |

Warm heavy-runner acquisition fell from ~51s to ~5s. Wall-clock commit → live can also include Git polling delay before CI and again before CD.

## 8. Evidence
Release 1.2.14 provides the concrete trace:

```text
1.2.14
  → sha256:2758e8...dcd1824
  → state commit 75769b4
  → deploy/main #24
  → dev-2026.09.21.5
```

| Proof | Result |
|---|---|
| Java CI | `sample-java-app/main #27` · PASS |
| CD | `deploy/main #24` · PASS |
| desired state | `1.2.14 / sha256:2758e8...dcd1824` |
| release tag | `dev-2026.09.21.5` |

Implementation: [service CI](delivery/pipeline/vars/servicePipeline.groovy) · [platform validation](delivery/Jenkinsfile.platform) · [CD](delivery/pipeline/vars/deployPipeline.groovy) · [scan](delivery/pipeline/resources/lab/delivery/scan-image.sh) · [publish/sign](delivery/pipeline/resources/lab/delivery/publish-image.sh) · [deploy](delivery/pipeline/resources/lab/delivery/deploy.sh).

## 9. Known Limits
- Vulnerability policy blocks **CRITICAL** findings only.
- CycloneDX SBOM is archived but not signed or attested.
- Cosign uses `--tlog-upload=false`; there is no transparency-log evidence.
- A canary receiving no traffic warns but still passes.
- The measured 1.2.14 proof covers **dev**; stage/prod application promotion and the prod canary are implemented, not demonstrated.
