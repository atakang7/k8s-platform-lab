# Delivery

## Contents

- [1. Delivery Model](#1-delivery-model)
- [2. Java CI](#2-java-ci)
- [3. Execution Model and Optimization](#3-execution-model-and-optimization)
- [4. Artifact Identity and Traceability](#4-artifact-identity-and-traceability)
- [5. Release, Promotion and Rollback](#5-release-promotion-and-rollback)
- [6. Deployment Safety and Trust Boundaries](#6-deployment-safety-and-trust-boundaries)
- [7. Evidence](#7-evidence)

The delivery contract is simple:

> **Build once. Scan once. Publish once. Deploy and promote by immutable digest.**

```text
┌──────────────────────────────────────────┐
│               JAVA CHANGE                │▒
│source · chart · Dockerfile               │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│                 VALIDATE                 │▒
│Dockerfile · version · Helm dry-run       │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│          JUNIT TESTS + PACKAGE           │▒
│@WebMvcTest · @SpringBootTest             │▒
│mvnw package → application.jar            │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│               IMAGE BUILD                │▒
│rootless BuildKit · Java 21 runtime       │▒
│tested JAR → OCI layout                   │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│               SCAN + SBOM                │▒
│Trivy CRITICAL gate · CycloneDX           │▒
│PR: PASS ends here · main: continue       │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│        MAIN ONLY · PUBLISH + SIGN        │▒
│Skopeo · digest equality · Cosign         │▒
│image + chart → OCI registry              │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│          GIT ENVIRONMENT STATE           │▒
│state/dev.yaml · version + sha256         │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│                CD VERIFY                 │▒
│signature · promotion ancestry · dry-run  │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│           DEPLOY EXACT DIGEST            │▒
│Helm upgrade --wait                       │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│                HELM TEST                 │▒
│real HTTP smoke test                      │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│               RELEASE TAG                │▒
│dev-YYYY.MM.DD.N                          │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│               PROMOTION PR               │▒
│same digest → stage → prod                │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
```

CI produces the artifact. Git state selects it. CD never rebuilds it.

---

## 1. Delivery Model

### PR vs main

| | PR | `main` |
|---|:---:|:---:|
| Validate | ✓ | ✓ |
| Java tests + package | ✓ | ✓ |
| Container image build | ✓ | ✓ |
| Trivy + SBOM | ✓ | ✓ |
| Publish image/chart | — | ✓ |
| Cosign | — | ✓ |
| Update environment state | — | ✓ |
| Deploy | — | ✓ |

A service-changing PR must increase its chart version. Promotion PRs change only `state/` and therefore do not create a new application version.

Heavy service stages run only when:

```text
┌──────────────────────────────────────────┐
│           RUN HEAVY SERVICE CI           │▒
│service path changed                      │▒
│OR previous build failed                  │▒
│OR main version is not recorded           │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
```

Unrelated repository changes do not rebuild the service.

### CI → state → CD

```text
┌──────────────────────────────────────────┐
│            CI RELEASE OUTPUT             │▒
│version 1.2.14                            │▒
│sha256:2758e8...                          │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│            GIT DESIRED STATE             │▒
│state/dev.yaml                            │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│                 CD INPUT                 │▒
│deploy repository@sha256:2758e8...        │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
```

The state commit is the CI/CD boundary.

### Core invariants

- **Scanned artifact = published artifact.**
- **Published digest = state digest = deployed digest.**
- **CD does not rebuild.**
- **Mutable image tags are never used by the workload.**
- **Promotion copies an existing digest; it does not create another artifact.**
- **CI may dry-run Kubernetes changes but may not write them.**
- **CD credentials are environment-scoped.**

Jenkins discovers GitHub changes by one-minute multibranch polling because this local Jenkins is not webhook-reachable.

---

## 2. Java CI

```text
┌──────────────────────────────────────────┐
│                 CHECKOUT                 │▒
│chart · state · source revision           │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│                 VALIDATE                 │▒
│Dockerfile lint · PR version gate         │▒
│Helm render · server-side dry-run         │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│             JUNIT TEST SUITE             │▒
│@WebMvcTest(HelloController)              │▒
│GET /api/foos → 200                       │▒
│missing val → 400                         │▒
│GET /api/release → release marker         │▒
│@SpringBootTest · contextLoads()          │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│              MAVEN PACKAGE               │▒
│mvnw package → application.jar            │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│              JAVA 21 IMAGE               │▒
│tested JAR copied into runtime image      │▒
│rootless BuildKit → OCI layout            │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│               SCAN + SBOM                │▒
│Trivy CRITICAL gate                       │▒
│CycloneDX SBOM archived                   │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│           MAIN ONLY · PUBLISH            │▒
│push scanned OCI layout                   │▒
│registry digest == scanned digest         │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│              SIGN + RECORD               │▒
│Cosign repository@digest                  │▒
│chart → OCI · state/dev.yaml              │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
```

| Stage | What matters |
|---|---|
| **Validate** | Rejects invalid Dockerfile, invalid version progression, invalid Helm/admission output. |
| **Unit / slice tests** | JUnit 5 + `@WebMvcTest` exercise controller behavior; a separate `@SpringBootTest` verifies the application context. |
| **Package** | `mvnw package` runs the tests and produces the executable JAR. This happens inside BuildKit, so Jenkins reports test/package time inside **Build** rather than as a separate Jenkins stage. |
| **Image build** | The tested JAR is copied into the Java 21 runtime image and emitted once as `app-image/`. |
| **Scan** | Any CRITICAL vulnerability fails CI; the same report produces the archived CycloneDX SBOM. |
| **Publish** | Pushes the already-scanned OCI layout. Registry digest must match the scanned manifest digest. |
| **Sign** | Cosign signs the immutable repository digest. |
| **Record** | CI commits the version and digest to the first environment state file. |

### Failure behavior

```text
┌──────────────────────────┐    ┌──────────────────────────┐    ┌──────────────────────────┐
│     VALIDATION FAIL      │▒    │   TEST / PACKAGE FAIL    │▒    │       CRITICAL CVE       │▒
│stop before build         │▒    │Build stage fails         │▒    │stop before publish       │▒
│no publish                │▒    │no image release          │▒    │SBOM retained             │▒
└──────────────────────────┘▒    └──────────────────────────┘▒    └──────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒     ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒     ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒

┌──────────────────────────┐    ┌──────────────────────────┐    ┌──────────────────────────┐
│     VERSION CONFLICT     │▒    │     DIGEST MISMATCH      │▒    │     STATE PUSH RACE      │▒
│reject source reuse       │▒    │reject publication        │▒    │refetch main              │▒
│raise version             │▒    │fail closed               │▒    │retry                     │▒
└──────────────────────────┘▒    └──────────────────────────┘▒    └──────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒     ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒     ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
```

A later `main` run retries an unrecorded release; a transient publish/state failure does not require another source change.

---

## 3. Execution Model and Optimization

### Runner topology

```text
┌──────────────────────────┐    ┌──────────────────────────┐    ┌──────────────────────────┐
│         HEAVY CI         │▒    │         LIGHT CI         │▒    │            CD            │▒
│lab-ci-runner           │▒    │lab-ci-light            │▒    │lab-cd-runner-dev       │▒
│node-3                    │▒    │verification              │▒    │jenkins-deploy-dev        │▒
│BuildKit + Trivy caches   │▒    │no image build            │▒    │apps-dev only             │▒
└──────────────────────────┘▒    └──────────────────────────┘▒    └──────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒     ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒     ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
```

One pod of each class is kept warm. Global Kubernetes-agent capacity is capped at three.

### What is reused or avoided

| Mechanism | Work removed from hot path |
|---|---|
| Warm runners | Kubernetes pod provisioning on normal CI/CD runs |
| Persistent BuildKit state | Rebuilding unchanged image layers |
| Persistent Trivy cache | Re-fetching vulnerability data on every pod |
| Heavy/light runner split | Verification waiting behind BuildKit work |
| Node-3 cache locality | Losing host-backed build/scan caches across nodes |
| Existing image/chart detection | Republishing an already-produced version |
| State-driven CD | Rebuilding, rescanning, or repackaging during deployment |

Heavy CI is pinned to the node that owns its caches. BuildKit remains rootless.

### Measured result

```text
┌────────────────────────┐    ┌────────────────────────┐    ┌────────────────────────┐
│     CI #27 · 1m26s     │▒    │     CD #24 · 1m16s     │▒    │     TOTAL · 2m42s      │▒
│Checkout  3.6s          │▒    │Verify     10s          │▒    │CI + CD execution       │▒
│Validate  3.8s          │▒    │Deploy   1m05s          │▒    │                        │▒
│Build     38s           │▒    │deploy.sh  53s          │▒    │warm CI wait ≈ 5s       │▒
│Scan      3.7s          │▒    │                        │▒    │                        │▒
│Publish    30s          │▒    │                        │▒    │                        │▒
└────────────────────────┘▒    └────────────────────────┘▒    └────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒     ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒     ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
```

The warm heavy runner reduced executor acquisition from roughly **51s** in an earlier run to about **5s** in CI #27.

`2m42s` is pipeline execution time. Git discovery latency is separate because Jenkins polls rather than receiving webhooks.

---

## 4. Artifact Identity and Traceability

The chart version is the human release version. The digest is the runtime identity.

```text
┌──────────────────────────────────────────┐
│              SOURCE COMMIT               │▒
│253d14cd907482...                         │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│           APPLICATION VERSION            │▒
│1.2.14                                    │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│             PUBLISHED IMAGE              │▒
│sample-java-app:1.2.14                    │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│             IMMUTABLE DIGEST             │▒
│sha256:2758e8fba94b...                    │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│               STATE COMMIT               │▒
│75769b4 · state/dev.yaml                  │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│           RUNNING DEV WORKLOAD           │▒
│repository@sha256:2758e8...               │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│               RELEASE TAG                │▒
│dev-2026.09.21.5                          │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
```

The 1.2.14 state is:

```yaml
sample-java-app:
  version: 1.2.14
  image: sha256:2758e8fba94b92423860dbb36245617c9163ad74fea23417308f17304dcd1824
```

Before deploy, CD verifies the recorded digest with the Cosign public key shipped by the delivery library on `main`. A PR cannot replace the verification key used for its own release.

A published version may be reused only when its OCI revision label matches the same service source revision. The same version cannot silently move to different source.

---

## 5. Release, Promotion and Rollback

### Release

A successful environment deployment is tagged:

```text
┌──────────────────────────────────────────┐
│         ENVIRONMENT RELEASE TAG          │▒
│dev-2026.09.21.5                          │▒
│stage-YYYY.MM.DD.N                        │▒
│prod-YYYY.MM.DD.N                         │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
```

The tag identifies a successfully applied **environment state**, not another image build.

### Promotion

```text
┌──────────────────────────────────────────┐
│                DEV STATE                 │▒
│state/dev.yaml · digest X                 │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│          DEV DEPLOYED + TESTED           │▒
│release tag created                       │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│               PROMOTION PR               │▒
│copy digest X only                        │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│               STAGE STATE                │▒
│state/stage.yaml · digest X               │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│         STAGE DEPLOYED + TESTED          │▒
│same artifact · no rebuild                │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│               PROMOTION PR               │▒
│copy digest X only                        │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│                PROD STATE                │▒
│state/prod.yaml · digest X                │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│                   PROD                   │▒
│deploy exact digest X                     │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
```

CD rejects a stage/prod release unless Git history proves that the exact digest previously existed in the preceding environment.

**Promotion changes state only. No rebuild.**

### Prod canary

Configured prod policy:

```text
┌──────────────────────────────────────────┐
│             CANDIDATE DIGEST             │▒
│prod desired state                        │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│              CANARY RELEASE              │▒
│1 replica · 10% ingress traffic           │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│                HELM TEST                 │▒
│candidate must pass smoke test            │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│            OBSERVE 5 MINUTES             │▒
│Prometheus · ingress 5xx rate             │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│                 DECISION                 │▒
│≤ 1% → promote stable                     │▒
│> 1% → remove canary                      │▒
│stable release remains untouched          │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
```

The current lab cluster runs `dev`; the canary path is implemented but is not part of the 1.2.14 timing measurement.

### Rollback

```text
┌──────────────────────────────────────────┐
│           HELM UPGRADE --WAIT            │▒
│readiness failure → automatic rollback    │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│                HELM TEST                 │▒
│PASS → accept release                     │▒
│FAIL → rollback previous revision         │▒
│first install failure → uninstall         │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
```

If chart version and digest already match the desired state, deployment is a no-op.

---

## 6. Deployment Safety and Trust Boundaries

```text
┌──────────────────────────────────────────┐
│         CI IDENTITY · jenkins-ci         │▒
│server-side dry-run allowed               │▒
│real CREATE/UPDATE/DELETE denied          │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│            GIT STATE HANDOFF             │▒
│state/dev.yaml · version + digest         │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│     CD IDENTITY · jenkins-deploy-dev     │▒
│apps-dev only · no Secret reads           │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│             HELM DEPLOYMENT              │▒
│environment-scoped ServiceAccount         │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
```

### Before any deployment

```text
┌──────────────────────────────────────────┐
│               STATE SCHEMA               │▒
│version + sha256 contract                 │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│            PROMOTION ANCESTRY            │▒
│digest existed in previous environment    │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│             COSIGN SIGNATURE             │▒
│verify repository@digest                  │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│               HELM RENDER                │▒
│recorded version + digest                 │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│           SERVER-SIDE DRY-RUN            │▒
│API + admission chain                     │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                      │
                      ▼
┌──────────────────────────────────────────┐
│            DEPLOYMENT ALLOWED            │▒
│only after every gate passes              │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
```

CI has RBAC needed for server-side dry-run, but the `jenkins-ci-dry-run-only` admission policy rejects its real CREATE/UPDATE/DELETE requests.

CD uses `jenkins-deploy-<environment>`. Its RoleBinding exists only in that environment namespace and grants no Kubernetes Secret reads. Helm therefore stores release history in ConfigMaps.

Application rollout safety is enforced by the chart:

```text
┌──────────────────────────────────────────┐
│              ROLLOUT SAFETY              │▒
│startup · readiness · liveness probes     │▒
│maxUnavailable: 0 · surge capacity        │▒
│topology spreading · PDB where valid      │▒
│Helm --wait · HTTP smoke test             │▒
└──────────────────────────────────────────┘▒
 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
```

---

## 7. Evidence

### 1.2.14 dev release

| Proof | Result |
|---|---|
| CI | `sample-java-app/main #27` · **PASS · 1m26s** |
| CD | `deploy/main #24` · **PASS · 1m16s** |
| CI + CD | **2m42s** |
| Version | `1.2.14` |
| Digest | `sha256:2758e8fba94b...dcd1824` |
| State commit | `75769b4` — `Deploy sample-java-app 1.2.14 to dev` |
| Release tag | `dev-2026.09.21.5` |

Local pipeline evidence:

- CI: `https://jenkins.lab.test/job/sample-java-app/job/main/27/flowGraphTable/`
- CD: `https://jenkins.lab.test/job/deploy/job/main/24/flowGraphTable/`

Implementation evidence:

- [CI pipeline](delivery/pipeline/vars/servicePipeline.groovy)
- [CD pipeline](delivery/pipeline/vars/deployPipeline.groovy)
- [release/state logic](delivery/pipeline/vars/delivery.groovy)
- [build](delivery/pipeline/resources/lab/delivery/build-image.sh)
- [scan / SBOM](delivery/pipeline/resources/lab/delivery/scan-image.sh)
- [publish / sign](delivery/pipeline/resources/lab/delivery/publish-image.sh)
- [verification](delivery/pipeline/resources/lab/delivery/validate-release.sh)
- [deploy / canary / rollback](delivery/pipeline/resources/lab/delivery/deploy.sh)
- [desired state](state/dev.yaml)

The measured evidence covers the complete **dev CI → state → CD → deployment** path. Stage/prod promotion and prod canary are implemented but are not claimed as part of this measured run.
