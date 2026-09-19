# Delivery

`delivery/` owns application validation, image construction, security reporting, artifact publication, and Kubernetes deployment.

Canonical delivery design: [05 — Delivery](../docs/05-delivery/README.md).

The release identity is one full Git commit SHA plus one immutable registry digest.

## Flow

```text
GitHub main
    │ SCM poll
    ▼
lab-build · lab-ci-runner
    │
    ▼
change router ─── platform/infra only ──► static checks ──► done
    │          └── docs/markdown only ───► no flow ─────────► done
    │ app/ or delivery/ changed
    ▼
parallel validation
    ├─ Dockerfile lint
    └─ Helm lint + chart server dry-run
    │
    ▼
BuildKit · single build · unit tests run here (JDK 11, mvnw)
    │
    ▼
app-image/ (OCI layout) ──► Trivy + CycloneDX SBOM
    │
    ▼
skopeo push of app-image/, unchanged
    │ pushed digest must equal the scanned manifest digest
    ▼
repository@sha256:<digest>
    │
    │ async enqueue · exact commit + digest
    ▼
lab-deploy · lab-cd-runner
    │
    ├─ validate immutable inputs
    ├─ checkout exact commit
    └─ helm upgrade --install --wait --rollback-on-failure
         failure ──► every chart object back to the last good release
```

The image is built once. The OCI layout that Trivy scans is the one `skopeo` pushes, and publication fails if the registry digest differs from the scanned manifest digest, so the deployed image is provably the scanned image.

CI queues CD asynchronously after publication. Deployment duration does not keep the CI executor occupied.

## Change router

> **Scope.** This router is intentionally small and written for this repository's four top-level areas. It is **not** a production blueprint for monorepo CI: it has no dependency graph between areas, no per-area pipelines or owners, and it validates rather than applies infrastructure. If the repository grows beyond these areas, replace it with per-area jobs rather than extending the table.

`lab-build` polls `main` for every commit, then `delivery/ci/route.sh` decides which flows run. It diffs the new commit against the **last successful** build, so a change whose build failed is routed again on the next commit until it passes. The first build, or a base missing from history, runs every flow.

| Changed paths | Flow | What runs |
|---|---|---|
| `app/`, `delivery/` | app | tests, lint, chart dry-run, build, scan, publish, **deploy** |
| `platform/`, `policies/` | platform | webhook chart `helm lint`, webhook Dockerfile `hadolint`, shell syntax |
| `infra/`, `validation/`, `Vagrantfile`, `Makefile` | infra | shell syntax |
| `*.md`, `docs/`, anything else | none | GitHub status only |

A commit touching several areas runs each matching flow.

Platform and infra are **never applied** from Jenkins: Jenkins runs inside the cluster those layers create, including Jenkins itself. The operator applies them with the `make` targets and validates them live (`make cluster-validate`, `edge-validate`, `e2e-validate`). Their CI flows are static checks only, limited to tools in the CI agent image; Ansible syntax and the webhook's Go tests are not run in CI.

A change under `delivery/` (pipeline, deploy script, agent image) runs the app flow and therefore redeploys the application; that exercises the changed delivery path end to end.

## CI

`Jenkinsfile.build` runs on `lab-ci-runner`.

Unit tests run inside the image build (`app/Dockerfile`, build stage), with the same JDK 11 and Maven wrapper that compile the shipped jar. A failing test fails the BuildKit solve, so no image is produced or published. There is no separate test step on the CI agent's own JDK.

Kubernetes manifests use `--dry-run=server`, so checks pass through the live API server and active admission chain without persisting test workloads. CI runs as the `jenkins-ci` ServiceAccount, which an admission policy restricts to dry-run requests: CI can validate production objects but cannot change them.

Persistent node-local caches on `node-3`:

- Trivy: `/var/lib/lab-ci/trivy`
- BuildKit (rootless, uid 1000): `/var/lib/lab-ci/buildkit-rootless`

Trivy is report-only by default because `TRIVY_EXIT_CODE` defaults to `0`. The CycloneDX SBOM is still archived before publication.

## CD

`Jenkinsfile.deploy` runs on `lab-cd-runner`.

CD rejects mutable image references and abbreviated source revisions. It requires:

```text
IMAGE_REF  = docker.io/atakangul/sample-java-app@sha256:<64 hex>
COMMIT_SHA = <40 hex Git SHA>
```

CD checks out that commit detached and releases the application chart (`app/chart`) with `delivery/ci/deploy.sh`. Helm waits until every object is ready and, if it is not, rolls all of them back to the last successful release. The chart rejects any image that is not `docker.io/atakangul/sample-java-app@sha256:<64 hex>`.

## Jenkins integration

Jobs and agent templates are declared in [`platform/jenkins/jcasc/jenkins.yaml`](../platform/jenkins/jcasc/jenkins.yaml). Do not recreate them manually in the Jenkins UI.

The CI/CD tool image lives under `jenkins/` and is referenced from JCasC by immutable digest.

## Files

| Path | Purpose |
|---|---|
| `Jenkinsfile.build` | CI orchestration |
| `Jenkinsfile.deploy` | CD orchestration |
| `ci/` | tests, build, scan, publish, deploy, commit status helpers |
| `jenkins/` | reproducible Jenkins agent image |

## Operating rule

Keep the commit SHA and image digest together during diagnosis and rollback. A manual cluster image change bypasses that release identity and is not the normal deployment path.
