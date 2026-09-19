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
    ├── parallel validation
    │    ├─ Maven tests
    │    ├─ Dockerfile lint
    │    ├─ Kubernetes server dry-run
    │    └─ Ansible syntax
    │
    ▼
BuildKit solve #1
    │
    ▼
app-image.tar ──► Trivy + CycloneDX SBOM
    │ scan stage complete
    ▼
BuildKit solve #2 · same source/context · warm cache
    │
    ▼
registry push ──► repository@sha256:<digest>
    │
    │ async enqueue · exact commit + digest
    ▼
lab-deploy · lab-cd-runner
    │
    ├─ validate immutable inputs
    ├─ checkout exact commit
    ├─ Ansible apply
    ├─ rollout status
    └─ assert live image == requested digest
```

The local tar is scan input only. Publication is a second BuildKit solve against the same source revision and build context, reusing warm BuildKit state.

CI queues CD asynchronously after publication. Deployment duration does not keep the CI executor occupied.

## CI

`Jenkinsfile.build` runs on `lab-ci-runner`.

Kubernetes manifests use `--dry-run=server`, so checks pass through the live API server and active admission chain without persisting test workloads.

Persistent node-local caches on `node-3`:

- Maven: `/var/lib/lab-ci/m2`
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

CD checks out that commit detached, applies the runtime resources through Ansible, waits for the rollout, then reads the live Deployment and verifies the exact digest.

## Jenkins integration

Jobs and agent templates are declared in [`platform/jenkins/jcasc/jenkins.yaml`](../platform/jenkins/jcasc/jenkins.yaml). Do not recreate them manually in the Jenkins UI.

The CI/CD tool image lives under `jenkins/` and is referenced from JCasC by immutable digest.

## Files

| Path | Purpose |
|---|---|
| `Jenkinsfile.build` | CI orchestration |
| `Jenkinsfile.deploy` | CD orchestration |
| `ci/` | tests, build, scan, publish, commit status helpers |
| `ansible/` | Kubernetes release reconciliation |
| `jenkins/` | reproducible Jenkins agent image |

## Operating rule

Keep the commit SHA and image digest together during diagnosis and rollback. A manual cluster image change bypasses that release identity and is not the normal deployment path.
