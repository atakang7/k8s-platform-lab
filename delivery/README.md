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
    │    └─ Helm lint + chart server dry-run
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
    └─ helm upgrade --install --wait --rollback-on-failure
         failure ──► every chart object back to the last good release
```

The local tar is scan input only. Publication is a second BuildKit solve against the same source revision and build context, reusing warm BuildKit state.

CI queues CD asynchronously after publication. Deployment duration does not keep the CI executor occupied.

## CI

`Jenkinsfile.build` runs on `lab-ci-runner`.

Kubernetes manifests use `--dry-run=server`, so checks pass through the live API server and active admission chain without persisting test workloads. CI runs as the `jenkins-ci` ServiceAccount, which an admission policy restricts to dry-run requests: CI can validate production objects but cannot change them.

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
