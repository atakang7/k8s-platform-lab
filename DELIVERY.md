# Delivery

The delivery system has one job: turn reviewed source into a verifiable, immutable release without rebuilding between CI and deployment.

```text
PR / main
   │
   ▼
Validate → Build → Scan
                    │
                    │ exact scanned OCI layout
                    ▼
             Publish + Sign
                    │
                    ▼
              sha256 digest
                    │
                    ▼
          state/<environment>.yaml
                    │
                    ▼
              Verify → Deploy
                    │
                    ▼
             running workload
                    │
                    ▼
               release tag
```

The important boundary is the digest. CI produces it once. CD verifies and deploys that same artifact.

---

## 1. Delivery Model

### PR and main

Jenkins uses GitHub multibranch jobs for service CI, platform validation, and deployment. Only `main` and pull requests are built. Because Jenkins is not reachable from GitHub, branch discovery is periodic at one-minute intervals rather than webhook-driven.

Service CI behaves differently by ref:

| Ref | Validate | Build/test | Scan + SBOM | Publish/sign | Record state |
|---|---:|---:|---:|---:|---:|
| Pull request | yes | yes | yes | no | no |
| `main` | yes | yes | yes | yes | yes |

A pull request that changes a service must raise that service's chart version above the target branch. Promotion pull requests only change environment state, so they do not owe an application version bump.

Service work is also skipped when it is unnecessary. The service stages run when the service path changed, after a failed previous build, or on `main` when the current version has not yet been recorded in the first environment. This keeps unrelated repository changes off the heavy CI path while still retrying incomplete releases.

### State is the deployment interface

CI does not call the deploy script directly. After publication it commits:

```yaml
environment: dev
services:
  sample-java-app:
    version: 1.2.14
    image: sha256:2758e8fba94b92423860dbb36245617c9163ad74fea23417308f17304dcd1824
```

to `state/dev.yaml`.

That commit is the handoff between CI and CD.

```text
source change
    │
    ▼
CI publishes immutable artifact
    │
    ▼
Git state changes
    │
    ▼
CD reconciles cluster to Git state
```

The deploy job verifies state changes on pull requests and branches. Only `main` may perform the deployment.

### Delivery invariants

1. **The scanned artifact is the published artifact.** BuildKit writes one OCI layout; Trivy scans it; Skopeo publishes that same layout.
2. **CD never rebuilds the application.** Deployment consumes the version and digest recorded by CI.
3. **Runtime images are digest-addressed.** Helm renders `repository@sha256:...`, never a mutable tag.
4. **A version cannot silently move.** Reusing a published version is accepted only when its OCI revision label matches the same service source revision.
5. **Promotion moves state, not binaries.** Stage and prod receive the digest that already existed in the previous environment.
6. **CI can validate Kubernetes objects but cannot mutate the environment.** Real writes are rejected by admission policy.
7. **CD authority is environment-scoped.** A deploy pod runs as `jenkins-deploy-<environment>` and is authorized only in that environment's namespace.

---

## 2. CI Pipeline

```text
Checkout
   │
   ├─ read chart + environment state
   ├─ resolve service source revision
   └─ materialize delivery scripts
   │
   ▼
Validate
   │
   ├─ hadolint
   ├─ PR version bump
   └─ Helm render + server-side dry-run
   │
   ▼
Build
   │
   └─ rootless BuildKit → OCI layout
   │
   ▼
Scan
   │
   ├─ Trivy CRITICAL gate
   └─ CycloneDX SBOM
   │
   ▼
Publish [main only]
   ├─ image
   ├─ digest equality check
   ├─ Cosign signature
   ├─ OCI Helm chart
   └─ state/dev.yaml
```

### Validate

For released services, CI renders the chart with the environment values and submits it using `kubectl apply --dry-run=server`. This exercises API validation and the admission chain without granting CI write authority.

Before the image exists, a syntactically valid placeholder digest is used only for this dry-run. Recorded releases are validated with their real digest and signature.

### Build once

`build-image.sh` runs BuildKit once and writes `app-image/` as an OCI layout. Application tests run as part of the Docker build. No later stage rebuilds the image.

The source repository and the last commit that changed the service path are embedded as OCI source metadata. That service revision is later used to reject version reuse from different source.

### Scan and SBOM

Trivy scans the OCI layout before publication.

- all CRITICAL findings are printed into the build log;
- any CRITICAL finding fails CI;
- the same scan output is converted into a CycloneDX SBOM;
- the SBOM is archived by Jenkins even when the scan fails.

Nothing reaches the registry after a failing CRITICAL gate.

### Publish and sign

Publication is `main`-only.

`publish-image.sh` reads the manifest digest from the scanned OCI layout, pushes that layout with Skopeo, then requires the registry-reported digest to equal the scanned digest. The resulting `repository@digest` is signed with Cosign.

The chart is published to the OCI registry at the application version. Existing chart versions are reused rather than pushed again.

Finally, CI records `{version, digest}` in the first environment's state file. The state push is retried because independent service pipelines may update `main` concurrently.

### Failure semantics

The pipeline fails closed:

```text
bad Dockerfile
     └─ stop before build

missing / invalid version bump
     └─ stop before publication

CRITICAL vulnerability
     └─ stop before publication

published version points at different source
     └─ reject version reuse

registry digest != scanned digest
     └─ reject publication

state push race
     └─ refetch main and retry
```

A later successful `main` build retries a release that is still unrecorded, so a transient publication failure does not require a new source change.

---

## 3. Execution Model and Optimization

The measured pipeline is fast because it avoids repeated startup and repeated work; the security gates were not removed.

### Three execution classes

```text
lab-ci-runner
  heavy CI
  node-3
  BuildKit + Trivy
        │
        ├─ persistent BuildKit state
        └─ persistent Trivy cache

lab-ci-light
  validation / deploy verification
  no image build

lab-cd-runner-dev
  deployment
  jenkins-deploy-dev identity
```

Jenkins keeps one pod of each class warm. Warm-up jobs create demand after controller reconciliation and then run every minute; Kubernetes plugin `idleMinutes` keeps the resulting pod reusable. Global agent concurrency is capped at three and each template is capped at one instance.

This removes most Kubernetes agent provisioning latency while keeping resource use bounded on the small lab cluster.

### Cache locality

The heavy runner is pinned to node-3. Its BuildKit state and Trivy cache are host-backed there:

```text
node-3
├─ /var/lib/lab-ci/buildkit-rootless
└─ /var/lib/lab-ci/trivy
```

Keeping the runner on the cache-owning node preserves layer and vulnerability-database reuse across pod recreation. The build itself remains rootless.

### Work avoided

The hot path deliberately avoids:

- a second application build in CD;
- rescanning after publication;
- publishing an image version already produced from the same service revision;
- republishing an existing chart version;
- heavy service CI for unrelated repository changes;
- provisioning a fresh runner for every normal build or deploy;
- queueing lightweight validation behind BuildKit work.

The result is optimization by reuse, not by weakening validation.

### Measured execution

Measured on the local three-node cluster for application release 1.2.14:

| Pipeline | Measured | Main work |
|---|---:|---|
| CI #27 | **1m26s** | checkout 3.6s · validate 3.8s · build 38s · scan 3.7s · publish 30s |
| CD #24 | **1m16s** | verify 10s · deploy stage 1m05s · deploy script 53s |
| CI + CD execution | **2m42s** | build → signed digest → state → verified deployment |

The CI runner acquisition overhead in #27 was about five seconds; an earlier run with the heavy runner unavailable spent about 51 seconds waiting for an executor. Warm execution removed roughly one minute from that path.

These are **pipeline execution timings**, not literal commit-to-live wall-clock timings. Jenkins discovers GitHub changes by periodic multibranch indexing. A release may therefore incur up to one indexing interval at each discovery boundary before the corresponding pipeline starts.

---

## 4. Artifact Identity and Traceability

The chart version is the application version. CI uses it as:

```text
Chart.yaml version
      │
      ├──────────────► image tag
      │
      ├──────────────► chart version
      │
      └──────────────► state version
```

The tag is human-readable identity; the digest is deployment identity.

A real 1.2.14 release resolves as:

```text
source release commit
253d14cd90748286865590e926a55783286bf3e7
        │
        ▼
application / chart version
1.2.14
        │
        ▼
published image
docker.io/atakangul/sample-java-app:1.2.14
        │
        ▼
immutable digest
sha256:2758e8fba94b92423860dbb36245617c9163ad74fea23417308f17304dcd1824
        │
        ▼
state commit
75769b4736f47ed7801c545eb7cd937b42ff494b
        │
        ▼
state/dev.yaml
        │
        ▼
dev deployment
        │
        ▼
dev-2026.09.21.5
```

The image is signed by CI after publication. Before deployment, CD renders the release, extracts every image using the recorded digest, and verifies each Cosign signature against the public key shipped by the delivery library.

The public verification key comes from the library on `main`; a pull-request branch cannot replace the key used to verify its proposed release.

---

## 5. Release, Promotion and Rollback

### Release semantics

An environment release is the complete `state/<environment>.yaml` at a healthy deploy point. After all releases in the cluster environment deploy and pass tests, Jenkins tags the Git commit:

```text
<environment>-<yyyy.MM.dd>.<n>
```

Example: `dev-2026.09.21.5`.

The tag identifies the environment state that was successfully applied, not a newly-built artifact.

### Promotion

Environment order is declared once in `environments.yaml`:

```text
dev → stage → prod
```

After a successful environment release, Jenkins opens or refreshes promotion pull requests for releases not yet present in the next environment. The promotion branch changes only the next environment's state.

Before accepting a recorded release, CD checks Git history to prove that its exact digest previously appeared in the preceding environment's state file.

```text
dev digest
    │
    ├─ successful deploy
    ├─ release tag
    └─ promotion PR
            │
            ▼
      state/stage.yaml
            │
      exact same digest
            ▼
           stage
```

No rebuild occurs during promotion.

### Canary

Prod is configured for a one-replica canary at 10% ingress traffic for five minutes, with a maximum 5xx rate of 1%.

The canary:

1. deploys the candidate digest as a separate Helm release;
2. runs the same Helm test;
3. receives weighted ingress traffic;
4. queries ingress-nginx request metrics from Prometheus each minute;
5. aborts when the measured 5xx rate exceeds the threshold.

On canary failure, cleanup removes the canary release and the stable release is never changed.

This mechanism is implemented for prod, but the current local cluster is configured as `clusterEnvironment: dev`; the 1.2.14 timing evidence below therefore exercises the dev path, not the prod canary path.

### Rollback

Deployment has two rollback layers.

```text
Helm upgrade
   │
   ├─ readiness failure
   │     └─ --rollback-on-failure
   │
   └─ upgrade succeeds
          │
          ▼
       helm test
          │
          ├─ pass → release accepted
          └─ fail → previous Helm revision restored
                    first install → uninstall
```

A release already running the recorded chart version and image digest is a no-op.

---

## 6. Deployment Safety and Trust Boundaries

Delivery authority is deliberately split.

```text
CI pod · jenkins-ci
│
├─ registry publish credentials
├─ signing key
├─ Kubernetes server-side dry-run
└─ real Kubernetes writes: DENIED
          │
          │ state commit
          ▼
Git desired state
          │
          ▼
CD pod · jenkins-deploy-dev
│
├─ apps-dev only
├─ no Kubernetes Secrets read
└─ Helm release + tests
```

CI receives RBAC sufficient for server-side validation, but the `jenkins-ci-dry-run-only` admission policy rejects CREATE, UPDATE, and DELETE requests unless `request.dryRun == true`.

CD does not reuse that identity. The deployment pod runs as the environment-specific ServiceAccount created by the environment bootstrap. Its RoleBinding exists only in that environment namespace. Bootstrap validation explicitly checks that the identity can deploy there, cannot deploy cluster-wide, and cannot read Secrets.

Helm release history uses ConfigMaps so the deploy identity does not need Secret access.

Before Helm mutates the environment, the Verify stage:

- validates environment-state structure;
- enforces promotion ancestry;
- verifies image signatures;
- renders the recorded chart/version/digest;
- performs a server-side dry-run through the cluster admission chain.

The application chart then provides availability-oriented rollout behavior: readiness/startup/liveness probes, `maxUnavailable: 0`, surge capacity, topology spreading, and a PDB where replica count makes it meaningful. Helm waits for readiness before the release proceeds, then executes a real HTTP smoke test through the Service.

This is an availability-preserving rollout policy, not a claim that the local lab demonstrates every production failure mode.

---

## 7. Measured Evidence

The following evidence is from the 1.2.14 dev release.

| Evidence | Result |
|---|---|
| Service CI | Jenkins `sample-java-app/main #27` · PASS · **1m26s** |
| Deployment | Jenkins `deploy/main #24` · PASS · **1m16s** |
| Combined execution | **2m42s** |
| Recorded state | `state/dev.yaml` → 1.2.14 / `sha256:2758e8…dcd1824` |
| State commit | `75769b4` · `Deploy sample-java-app 1.2.14 to dev` |
| Successful environment tag | `dev-2026.09.21.5` |
| Artifact flow | scanned OCI layout → registry digest equality check → signature → state digest → CD signature verification |

Local Jenkins evidence:

- CI: `https://jenkins.lab.test/job/sample-java-app/job/main/27/flowGraphTable/`
- CD: `https://jenkins.lab.test/job/deploy/job/main/24/flowGraphTable/`

Repository evidence:

- [service pipeline](delivery/pipeline/vars/servicePipeline.groovy)
- [deploy pipeline](delivery/pipeline/vars/deployPipeline.groovy)
- [delivery helpers](delivery/pipeline/vars/delivery.groovy)
- [build](delivery/pipeline/resources/lab/delivery/build-image.sh)
- [scan / SBOM](delivery/pipeline/resources/lab/delivery/scan-image.sh)
- [publish / sign](delivery/pipeline/resources/lab/delivery/publish-image.sh)
- [pre-deploy verification](delivery/pipeline/resources/lab/delivery/validate-release.sh)
- [deploy / canary / rollback](delivery/pipeline/resources/lab/delivery/deploy.sh)
- [environment state](state/dev.yaml)

The measured run proves the dev CI → state → CD path. Promotion and prod canary behavior are implemented in the same delivery code, but are not presented here as measured by the 1.2.14 dev timing run.
