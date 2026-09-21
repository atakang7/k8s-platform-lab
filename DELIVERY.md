# Delivery
Evidence for what the delivery system builds, proves, and knowingly trades away. Operator commands live in [delivery/README.md](delivery/README.md).

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
Java change → Validate → JUnit/Maven → Build image → Scan
                                              ↓ main
                                   Publish → Sign → state/dev.yaml
                                                       ↓
state/<env>.yaml → Verify → Deploy digest → Helm test → Tag → Promote
```

**Invariants:** scanned artifact = published artifact; published digest = state digest = deployed digest; CD never rebuilds; promotion moves the same digest.

## 2. Topology
```text
GitHub repo
├→ sample-java-app CI
├→ resource-requests-webhook CI
├→ platform CI
└→ deploy → state/<env>.yaml → one environment cluster
```

The app is Jenkins-released. The webhook is built/scanned/recorded by CI but installed by the operator. The lab cluster runs **dev**. Jenkins discovers changes by 1-minute polling.

## 3. Service CI
```text
Validate → JUnit/Spring tests → mvnw package → Java 21 image
   → Trivy CRITICAL gate + CycloneDX SBOM
   → [main] publish same OCI layout → verify digest → Cosign → state/dev.yaml
```

Tests include `@WebMvcTest(HelloController)` and `@SpringBootTest`. The tested JAR is copied into the runtime image; nothing is rebuilt after scanning.

PRs validate/build/scan only. `main` publishes and records the release.

**Fail closed:** invalid version/chart/test, CRITICAL vulnerability, source/version conflict, or digest mismatch stops publication. State push races refetch `main` and retry.

## 4. Platform CI
| Ref | Check |
|---|---|
| all builds | `shellcheck` |
| chart PRs | `ct lint` + version increment |
| `main` | publish missing base-chart versions |

`charts/service` is the runtime contract: digest images, restricted pod defaults, probes, spreading, optional PDB, ingress/metrics, and the HTTP Helm smoke test.

## 5. Artifact Identity
```text
source revision → version → image/chart tag → sha256 digest
                                               ↓
                             state/<env>.yaml → workload → release tag

1.2.14 → sha256:2758e8... → state commit 75769b4 → dev-2026.09.21.5
```

`Chart.yaml.version` is the human release version. The digest is runtime identity. Reusing a version from a different service source revision is rejected.

## 6. State, Promotion, Rollback
```text
dev:   digest X → deploy/test/tag → promotion PR
                                  ↓
stage: digest X → deploy/test/tag → promotion PR
                                  ↓
prod:  digest X → deploy same artifact
```

- CI writes new releases directly to `state/dev.yaml` on `main`.
- CD requires proof that the exact digest existed in the previous environment.
- `CODEOWNERS` owns stage/prod state; this gate depends on branch protection requiring code-owner review.
- Helm readiness failure rolls back automatically; failed Helm tests restore the previous revision.
- Operator rollback restores an earlier state through Git.
- Prod implements a 10% / 5-minute canary with a 1% ingress 5xx threshold.

## 7. Trust Boundaries
```text
Vault → VSO → Jenkins credentials

jenkins-ci                GitHub main                jenkins-deploy-<env>
dry-run only ───────────→ state/dev.yaml ─────────→ own namespace only
✕ Kubernetes writes                                ✕ Secrets / other envs
```

CI can server-side dry-run Kubernetes objects but cannot mutate the cluster. It **can** push dev state to `main`. CD uses an environment-specific ServiceAccount and cannot read Kubernetes Secrets. No cluster credential is stored in Jenkins.

Before deploy: **state schema → promotion ancestry → signature → server dry-run → Helm deploy/test**.

## 8. Performance
| Mechanism | Avoided work |
|---|---|
| warm runner classes | normal pod startup |
| persistent BuildKit/Trivy caches | repeated build/scan work |
| heavy/light runner split | verification waiting on builds |
| node-3 cache locality | cache loss |
| state-driven CD | rebuild/rescan/repackage |

| Release 1.2.14 | Time |
|---|---:|
| CI #27 | **1m26s** |
| CD #24 | **1m16s** |
| CI + CD execution | **2m42s** |

Warm heavy-runner acquisition fell from ~51s to ~5s. Wall-clock commit → live can additionally include up to two 1-minute polling intervals.

## 9. Evidence
| Proof | Result |
|---|---|
| Java CI | `sample-java-app/main #27` · PASS |
| CD | `deploy/main #24` · PASS |
| desired state | `1.2.14 / sha256:2758e8...dcd1824` |
| state commit | `75769b4` |
| release tag | `dev-2026.09.21.5` |

Implementation: [service CI](delivery/pipeline/vars/servicePipeline.groovy) · [platform CI](delivery/Jenkinsfile.platform) · [CD](delivery/pipeline/vars/deployPipeline.groovy) · [scan](delivery/pipeline/resources/lab/delivery/scan-image.sh) · [publish/sign](delivery/pipeline/resources/lab/delivery/publish-image.sh) · [deploy](delivery/pipeline/resources/lab/delivery/deploy.sh).

## 10. Known Limits
- Vulnerability policy blocks **CRITICAL** findings only.
- CycloneDX SBOM is archived but not signed/attested.
- Cosign uses `--tlog-upload=false`; there is no transparency-log evidence.
- A canary receiving no traffic warns but still passes.
- The measured 1.2.14 proof covers **dev**; sample-java-app stage/prod and the prod canary are implemented, not demonstrated.
