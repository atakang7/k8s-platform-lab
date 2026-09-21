# Delivery

The delivery contract is simple:

> **Build once. Scan once. Publish once. Deploy and promote by immutable digest.**

```text
                                 ┌────────────── PR ──────────────┐
                                 │                                │
Git change ──► Jenkins discovery ├─► Validate ─► Build ─► Scan ──┤
                                 │                                │
                                 └───────────── main ─────────────┘
                                                     │
                                                     ▼
                                              Publish image
                                                     │
                                              digest == scanned
                                                     │
                                                     ▼
                                                   Sign
                                                     │
                                                     ▼
                                              Publish chart
                                                     │
                                                     ▼
                                            state/dev.yaml
                                                     │
                                  ┌──────────────────┴──────────────────┐
                                  ▼                                     ▼
                           Verify release                         Git desired state
                       signature · promotion                           │
                       server-side dry-run                             ▼
                                  │                               Deploy exact
                                  └──────────────► CD ───────────► digest
                                                                       │
                                                                       ▼
                                                                 Helm test
                                                                       │
                                                                       ▼
                                                                 release tag
                                                                       │
                                                                       ▼
                                                            promotion PR
                                                               dev → stage → prod
```

CI produces the artifact. Git state selects it. CD never rebuilds it.

---

## 1. Delivery Model

### PR vs main

| | PR | `main` |
|---|:---:|:---:|
| Validate | ✓ | ✓ |
| Build + tests | ✓ | ✓ |
| Trivy + SBOM | ✓ | ✓ |
| Publish image/chart | — | ✓ |
| Cosign | — | ✓ |
| Update environment state | — | ✓ |
| Deploy | — | ✓ |

A service-changing PR must increase its chart version. Promotion PRs change only `state/` and therefore do not create a new application version.

Heavy service stages run only when:

```text
service path changed
        OR
previous build failed
        OR
main contains an unrecorded version
```

Unrelated repository changes do not rebuild the service.

### CI → state → CD

```text
CI
 │
 └─► state/dev.yaml
       version: 1.2.14
       image: sha256:2758e8...
               │
               ▼
              CD
               │
               └─► image.repository@sha256:2758e8...
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

## 2. CI Pipeline

```text
Checkout
   │
   ▼
Validate
   ├─ hadolint
   ├─ PR version gate
   └─ Helm render + server-side dry-run
   │
   ▼
Build
   └─ rootless BuildKit
          │
          ▼
      OCI layout
          │
          ▼
Scan
   ├─ Trivy CRITICAL gate
   └─ CycloneDX SBOM
          │
          ▼
Publish                    main only
   ├─ Skopeo pushes scanned OCI layout
   ├─ registry digest == scanned digest
   ├─ Cosign signs repository@digest
   ├─ Helm chart → OCI registry
   └─ {version,digest} → state/dev.yaml
```

| Stage | What matters |
|---|---|
| **Validate** | Rejects invalid Dockerfile, invalid version progression, invalid Helm/admission output. |
| **Build** | One BuildKit build creates `app-image/`; application tests run inside the build. |
| **Scan** | Any CRITICAL vulnerability fails CI; the same report produces the archived CycloneDX SBOM. |
| **Publish** | Pushes the already-scanned OCI layout. Registry digest must match the scanned manifest digest. |
| **Sign** | Cosign signs the immutable repository digest. |
| **Record** | CI commits the version and digest to the first environment state file. |

### Failure behavior

```text
invalid Dockerfile/version/chart ──► stop
CRITICAL vulnerability           ──► stop before publish
version reused by other source   ──► reject
registry digest changed          ──► reject
state push race                  ──► refetch main + retry
```

A later `main` run retries an unrecorded release; a transient publish/state failure does not require another source change.

---

## 3. Execution Model and Optimization

### Runner topology

```text
                         Jenkins controller
                           0 executors
                                │
                ┌───────────────┼────────────────┐
                ▼               ▼                ▼
        lab-ci-runner   lab-ci-light   lab-cd-runner-dev
        heavy CI          verification     deployment
        node-3            lightweight      jenkins-deploy-dev
            │                                  │
            ├─ BuildKit cache                  └─ environment-scoped RBAC
            └─ Trivy cache
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
1.2.14

CI #27
├─ Checkout       3.6s
├─ Validate       3.8s
├─ Build           38s
├─ Scan           3.7s
└─ Publish          30s
                  ─────
                  1m26s

CD #24
├─ Verify           10s
└─ Deploy         1m05s
   └─ deploy.sh      53s
                  ─────
                  1m16s

CI + CD execution  2m42s
```

The warm heavy runner reduced executor acquisition from roughly **51s** in an earlier run to about **5s** in CI #27.

`2m42s` is pipeline execution time. Git discovery latency is separate because Jenkins polls rather than receiving webhooks.

---

## 4. Artifact Identity and Traceability

The chart version is the human release version. The digest is the runtime identity.

```text
Git source
253d14cd907482...
      │
      ▼
Chart.yaml
1.2.14
      │
      ├─────────────► image tag :1.2.14
      ├─────────────► chart version 1.2.14
      └─────────────► state version 1.2.14
                              │
                              ▼
                  sha256:2758e8fba94b...
                              │
                              ▼
                  state commit 75769b4
                              │
                              ▼
                       dev workload
                              │
                              ▼
                    dev-2026.09.21.5
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
dev-2026.09.21.5
stage-YYYY.MM.DD.N
prod-YYYY.MM.DD.N
```

The tag identifies a successfully applied **environment state**, not another image build.

### Promotion

```text
state/dev.yaml
     │
     │ exact digest
     ▼
successful dev
     │
     └─► promotion PR
              │
              ▼
       state/stage.yaml
              │
         exact digest
              ▼
            stage
              │
              └─► promotion PR
                       │
                       ▼
                state/prod.yaml
                       │
                  exact digest
                       ▼
                     prod
```

CD rejects a stage/prod release unless Git history proves that the exact digest previously existed in the preceding environment.

**Promotion changes state only. No rebuild.**

### Prod canary

Configured prod policy:

```text
candidate digest
      │
      ▼
1 canary replica
10% ingress traffic
      │
      ▼
Helm test
      │
      ▼
5 min ingress 5xx observation
      │
 ┌────┴─────┐
 ▼          ▼
≤1%        >1%
 │           │
 ▼           └─► remove canary
promote          stable untouched
stable
```

The current lab cluster runs `dev`; the canary path is implemented but is not part of the 1.2.14 timing measurement.

### Rollback

```text
helm upgrade --wait
       │
       ├─ readiness failure ─► automatic Helm rollback
       │
       ▼
    helm test
       │
   ┌───┴────┐
   ▼        ▼
 PASS      FAIL
   │        │
 accept     ├─ previous revision → helm rollback
            └─ first install     → uninstall
```

If chart version and digest already match the desired state, deployment is a no-op.

---

## 6. Deployment Safety and Trust Boundaries

```text
                      Kubernetes
                          │
          ┌───────────────┴────────────────┐
          │                                │
          ▼                                ▼
     jenkins-ci                   jenkins-deploy-dev
     CI identity                   CD identity
          │                                │
 server-side dry-run                  apps-dev only
          │                                │
 real write                           Secrets read
   DENIED                               DENIED
          │                                │
          └──── state/dev.yaml ───────────►│
                                           ▼
                                     Helm deployment
```

### Before any deployment

```text
state schema
    │
promotion ancestry
    │
Cosign signature
    │
Helm render
    │
server-side dry-run
    │
    ▼
deployment allowed
```

CI has RBAC needed for server-side dry-run, but the `jenkins-ci-dry-run-only` admission policy rejects its real CREATE/UPDATE/DELETE requests.

CD uses `jenkins-deploy-<environment>`. Its RoleBinding exists only in that environment namespace and grants no Kubernetes Secret reads. Helm therefore stores release history in ConfigMaps.

Application rollout safety is enforced by the chart:

```text
startup/readiness/liveness probes
maxUnavailable: 0
surge capacity
topology spreading
PDB where replica count permits it
Helm --wait
Helm HTTP smoke test
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
